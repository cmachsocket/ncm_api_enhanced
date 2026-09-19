// SPDX-License-Identifier: MIT
//
// bridge/rollup.browser.config.mjs
//
// Mobile bundle build via Rollup + rollup-plugin-node-polyfills (the ionic-team
// plugin that ships real polyfill implementations in its `polyfills/` dir:
// events-browserify, stream-browserify, buffer, process, http, etc.).
//
// Differences vs esbuild build (bridge/build_browser.mjs):
//   - Bundler: Rollup instead of esbuild. Rollup tree-shakes better for
//     CJS-heavy code but is slower; we accept the trade-off because
//     rollup-plugin-node-polyfills ships *real* events.js (callable
//     constructor with EventEmitter.EventEmitter = EventEmitter — what
//     xml2js needs), while esbuild-plugins-node-modules-polyfill routes
//     through @jspm/core which exports an ESM namespace object.
//   - Polyfills: rollup-plugin-node-polyfills handles ALL node builtins
//     via its built-in resolver. We just enable `crypto: true` (needed
//     for xeapi's createHash/createDecipheriv); everything else defaults
//     to either real polyfill (events/stream/util/...) or empty (fs/dns/...).
//   - Patches: re-uses assets/bridge/build_patches.mjs from the esbuild
//     build via rollup-plugin-replace (text-level rewrites).
//
// Output: assets/bridge/dist/bundle.rollup.js

import { rollup } from 'rollup';
import resolve from '@rollup/plugin-node-resolve';
import commonjs from '@rollup/plugin-commonjs';
import esbuildPlugin from 'rollup-plugin-esbuild';
import replace from 'rollup-plugin-replace';
import json from '@rollup/plugin-json';
import nodePolyfills from '@stackline/rollup-plugin-polyfill-node';
import { readFileSync, statSync, writeFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = __dirname;

const ENTRY     = path.join(root, 'dist', 'mobile_entry.js');
const OUTFILE   = path.join(root, 'dist', 'bundle.rollup.js');
const SHIM_PATH = path.join(root, 'dist', 'runtime_shim.js');

// Mobile bundle = bare runtime (QuickJS has no jsdom / Watchman SDK).
// stubRegisterChecktokenV2 is exported from build_patches.mjs only when
// process.env.BUILD_TARGET === 'bare'. The patches here are rollup
// text-rewrites driven by the same source — see patches below.
process.env.BUILD_TARGET = 'bare';

const { defaultPlugins } = await import('./build_patches.mjs');

// Rollup's plugin model is different from esbuild — we can't use the same
// `setup(build) { onLoad() {} }` shape. Convert esbuild's default plugins
// (which contain onLoad callbacks) into rollup `transform` hooks that do
// the same text replacements. This lets us share build_patches.mjs
// between the two builds.
function esbuildOnLoadToRollupTransform(esbuildPlugin) {
  // Each esbuild plugin has one or more onLoad callbacks keyed by filter regex.
  // We collect all filters and apply the matching transform on each module.
  const captures = [];
  const fakeCtx = {
    onLoad({ filter }, fn) {
      captures.push({ filter, fn });
    },
    onResolve() {},
    onEnd() {},
    initialOptions: { absWorkingDir: process.cwd(), write: false },
  };
  esbuildPlugin.setup(fakeCtx);
  return {
    name: esbuildPlugin.name + '-as-rollup-transform',
    async transform(code, id) {
      // Stackline's polyfill plugin emits virtual ids like
      // '\x00node-polyfills:dirname:...' for its synthetic __dirname
      // shims. These don't exist on disk — skip the esbuild-shaped
      // readFile() that the onLoad hooks expect (which would try to
      // fs.promises.readFile() on the virtual path and crash).
      if (id.startsWith('\0')) return null;
      for (const { filter, fn } of captures) {
        if (filter.test(id)) {
          const result = await fn({ path: id });
          if (result && result.contents != null) {
            // last writer wins — matches esbuild's "first matching plugin
            // loads the file" semantics
            code = result.contents;
          }
        }
      }
      return code;
    },
  };
}

const patchTransforms = defaultPlugins.map(esbuildOnLoadToRollupTransform);

const banner = readFileSync(SHIM_PATH, 'utf8');

const t0 = Date.now();
const bundle = await rollup({
  input: ENTRY,
  // Upstream NCM uses dynamic require() patterns and Reflect-style
  // augmentation that tree-shakers can't prove are dead. Disable
  // tree-shaking to keep all reachable code (it inflates bundle size
  // a bit but matches what esbuild produced in 10.6 MB).
  treeshake: false,
  // Suppress "circular dependency" / "preferConst" warnings from
  // node_modules — the upstream code is what it is.
  onwarn(warning, defaultHandler) {
    if (warning.code === 'CIRCULAR_DEPENDENCY') return;
    if (warning.code === 'THIS_IS_UNDEFINED') return;
    if (warning.code === 'MISSING_GLOBAL_NAME') return;
    defaultHandler(warning);
  },
  plugins: [
    // 1) Replace stubs / path rewrites first so subsequent plugins see
    //    the patched source.
    ...patchTransforms,

    // 2) jsdom is unusable on QuickJS. Alias it to our empty stub so
    //    require('jsdom') returns {} instead of pulling the whole DOM
    //    polyfill tree into the bundle. Aliases must run BEFORE
    //    commonjs/node-resolve so they short-circuit resolution and
    //    avoid Rollup parse-failing on files like unblockmusic-utils
    //    (which has a `#!/usr/bin/env node` shebang that Rollup rejects
    //    but esbuild accepts as a comment).
    {
      name: 'alias-modules',
      resolveId(source, importer) {
        if (source === 'jsdom') {
          return path.join(root, 'dist', 'polyfills', 'jsdom-empty.js');
        }
        // Also force axios's http/https adapters to xhr (defensive; the
        // mobile runtime needs XHR, not node http).
        if (source === 'axios/lib/adapters/http.js') return 'axios/lib/adapters/xhr.js';
        if (source === 'axios/lib/adapters/https.js') return 'axios/lib/adapters/xhr.js';

        // mobile_entry.js uses `require('../generated_api')` to load the
        // auto-generated NCM API surface. node-resolve normally handles
        // this via its extensions array, but mobile_entry.js lives in
        // assets/bridge/dist/ while generated_api.js is at
        // assets/bridge/generated_api.js — the `../generated_api` path
        // may not resolve under certain resolve configs. Explicit mapping.
        if (source === '../generated_api' || source.endsWith('/generated_api')) {
          return path.join(root, 'generated_api.js');
        }

        // unblockmusic-utils is a CLI tool that requires `fs.readdirSync`
        // and `process.exit` at module top level. On desktop, fs is real
        // and this works; on mobile, fs is stubbed (per user direction
        // — upstream fs paths are being removed in the next release).
        // The NCM API only uses it inside try/catch blocks (song_url_v1,
        // song_url_match) so an empty stub preserves behaviour. Also,
        // its index.js starts with a `#!/usr/bin/env node` shebang that
        // Rollup refuses to parse (esbuild accepts it as a comment).
        if (source === '@neteasecloudmusicapienhanced/unblockmusic-utils') {
          return path.join(root, 'dist', 'polyfills', 'unblock-empty.js');
        }

        // Stub fs and node:fs/promises to an empty module. Upstream NCM
        // fs usage is being removed in the next release (per user direction).
        // Stackline's polyfill-node throws on `fs` by default, which would
        // kill the build; this short-circuits the throw by handing Rollup
        // a path to our empty stub before Stackline's resolveId fires.
        if (source === 'fs' || source === 'node:fs' || source === 'node:fs/promises') {
          return path.join(root, 'dist', 'polyfills', 'fs-empty.js');
        }

        // Alias crypto to a hand-rolled node-forge shim. Stackline's
        // polyfill-node throws on `crypto` by default (and even with
        // crypto: true it falls back to EMPTY_PATH). We need a real
        // crypto module because upstream NCM's xeapi path uses
        // createHash / createDecipheriv. This MUST be in the same
        // resolveId hook as the other aliases — Stackline throws
        // synchronously in its own resolveId, so this handler has to
        // run before it gets a chance to see `crypto`.
        if (source === 'crypto' || source === 'node:crypto') {
          return path.join(root, 'dist', 'polyfills', 'crypto-node-forge.js');
        }

        // Stackline's events.js is an ES module (`export default EventEmitter`).
        // When @rollup/plugin-commonjs converts `require('events')` into
        // `import events from 'events'`, the resulting namespace is the
        // module record `{ default: EventEmitter, EventEmitter: ... }`,
        // which is NOT callable. xml2js's CoffeeScript-emitted Parser
        // does `extend(Parser, require('events'))` and assumes
        // require('events') IS the constructor — silent inheritance
        // failure. Our CJS shim exports the constructor directly as
        // module.exports = EventEmitter, restoring correct inheritance.
        if (source === 'events') {
          return path.join(root, 'dist', 'polyfills', 'events.js');
        }

        // Stub basic-ftp — see dist/polyfills/basic-ftp-empty.js for
        // rationale. Upstream NCM pulls it via get-uri/dist/ftp.js, but
        // basic-ftp requires a real `net.Socket` which doesn't exist
        // in the QuickJS / flutter_js runtime. NCM API endpoints are
        // HTTPS only so the ftp code path is never hit in production.
        if (source === 'basic-ftp' || source.endsWith('/basic-ftp')) {
          return path.join(root, 'dist', 'polyfills', 'basic-ftp-empty.js');
        }

        // debug's package.json has no `exports` map. With conditions:
        // ['module-sync'], rollup walks into debug/src/index.js which
        // dynamically assigns `module.exports = require('./browser.js')`
        // — a real CJS file with no named exports. Downstream ESM
        // consumers like @tokenizer/inflate do `import debug from 'debug'`
        // and crash with "default is not exported". Force `debug` to
        // our no-op stub: the upstream packages only use debug in
        // dev-time error branches that never fire in production.
        if (source === 'debug') {
          return path.join(root, 'dist', 'polyfills', 'debug-empty.js');
        }

        // crypto-js's UMD wrapper does `module.exports = exports =
        // factory()` at the top of its IIFE, but @rollup/plugin-commonjs
        // in any strictRequires mode fails to recognize that as the
        // module's exports — the bundled `core.js` ends up as
        // `Object.freeze({__proto__: null})` (empty), and downstream
        // `CryptoJS.AES.encrypt` returns undefined methods.
        //
        // The NCM module surface that touches crypto-js is small
        // (login_qr_key, login, register_anonimous, decrypt, etc.).
        // user_account / song_url_v1 / etc. don't use it. The path of
        // least resistance: stub crypto-js with a noop object. login
        // and friends will throw at call time (so any caller that hits
        // them gets a clear error), but user_account — the most common
        // smoke test — keeps working.
        //
        // To fully replace crypto-js we'd need a WordArray-shaped AES
        // implementation; that's documented as TODO if we ever ship
        // weapi login from the mobile bundle.
        if (source === 'crypto-js') {
          return path.join(root, 'dist', 'polyfills', 'crypto-js-empty.js');
        }

        // sax's UMD wrapper does `})(typeof exports === 'undefined' ?
        // (this.sax = {}) : exports)`. @rollup/plugin-commonjs rewrites
        // `this.sax = {}` to `undefined.sax = {}` (a TypeError), then
        // the IIFE returns no value, so the plugin bakes the module's
        // exports as `Object.freeze({__proto__: null})`. xml2js then
        // does `sax.parser(...)` and crashes with "parser is not a
        // function".
        //
        // The real sax lib is 12 KB of EventEmitter-based streaming XML
        // parsing. NCM uses xml2js (which uses sax) to parse response
        // bodies for a small number of endpoints (login_qr_create,
        // lyric, etc.). For the smoke test (user_account) we don't need
        // any of those, and the cost of shipping a sax polyfill or
        // implementing it on top of QuickJS is non-trivial. Stub it for
        // now; the failing endpoints will throw a clear "sax disabled"
        // error at call time.
        if (source === 'sax') {
          return path.join(root, 'dist', 'polyfills', 'sax-empty.js');
        }

        return null;
      },
    },

    // 3) Polyfills for node builtins. Stackline fork is the modern,
    //    strictly ESM-compatible replacement for rollup-plugin-node-polyfills
    //    (the latter 6 years unmaintained and has internal ESM/CJS
    //    incompatibilities under @rollup/plugin-commonjs v29 with
    //    strictRequires).
    //
    //    Stackline defaults: fs/crypto are stubbed (`EMPTY_PATH`). We
    //    want crypto for real (xeapi needs createHash/createDecipheriv),
    //    so we alias crypto to our own esbuild-style crypto shim that
    //    pulls node-forge directly. fs stays stubbed per user direction
    //    (upstream fs paths being removed in next release).
    //
    //    `include: ['node_modules/**/*.js']` is the default but we set
    //    it explicitly to limit polyfill injection to upstream NCM code
    //    (not our own mobile_entry.js / runtime_shim.js which set up
    //    globals themselves).
    nodePolyfills({
      include: ['node_modules/**/*.js'],
    }),

    // 4) Standard node resolution + CJS interop (upstream NCM is
    //    CoffeeScript-style CJS; we need @rollup/plugin-commonjs to
    //    convert require() / module.exports into ESM form for Rollup).
    resolve({
      browser: true,
      preferBuiltins: false,
      mainFields: ['browser', 'module', 'main'],
      exportConditions: ['module-sync'],
      extensions: ['.js', '.mjs', '.json'],
    }),
    commonjs({
      transformMixedEsModules: true,
      requireReturnsDefault: 'auto',
      // strictRequires accepts "auto" | boolean | "debug" | string[].
      // Default value (true) wraps every CommonJS file in a function
      // which is only executed on first require — preserving node's
      // lazy-init semantics. This is critical for circular deps and
      // UMD packages like crypto-js whose UMD wrapper has side
      // effects on first import.
      //
      // "auto" (the README's recommended setting) only wraps files
      // that are part of a cycle or required conditionally. Other
      // files are hoisted as static imports. This is faster and
      // produces smaller output, but breaks some UMD patterns where
      // the wrapper IIFE expects `this` / `module` / `exports` to
      // be set up by a surrounding scope.
      //
      // We've been bitten by both ends: strictRequires=true broke
      // crypto-js's UMD wrapper (core module ended up empty-frozen),
      // while strictRequires=false left `require('./logger')` calls
      // unconverted. We use strict mode + dynamicRequireTargets to
      // catch the UMD-broken packages explicitly while keeping the
      // strict semantics for everything else.
      strictRequires: true,
      // Also force all `require()` calls (including relative-path ones
      // like `require('./logger')`) to be statically resolved. Without
      // this, @rollup/plugin-commonjs falls back to leaving the require
      // in the output as a runtime require, which fails in QuickJS.
      dynamicRequireTargets: false,
      // Some upstream packages (debug, ms, @tokenizer/inflate, etc.)
      // ship CJS that does `module.exports = require('./browser')` style
      // assignments without a separate ESM default export. With strict
      // mode + auto, default-imports of these packages return the same
      // thing as the named exports — i.e. consumers' `import debug from
      // 'debug'` resolves to the actual debug function instead of
      // undefined. Without `defaultIsModuleExports: 'auto'` the plugin
      // tries to detect named exports and misses the dynamic re-export
      // chain, leading to "default is not exported" errors.
      defaultIsModuleExports: 'auto',
      // crypto-js and sax both use the pre-2010 UMD wrapper idiom:
      //
      //   })(typeof exports === 'undefined' ? (this.sax = {}) : exports);
      //
      // @rollup/plugin-commonjs rewrites `typeof exports` to a literal
      // and `this.X = Y` to `undefined.X = Y` (which throws), then
      // falls back to `Object.freeze({__proto__: null})` for the
      // module's exports. The bundled sub-modules end up empty,
      // and downstream `CryptoJS.AES.encrypt` / `sax.parser` are
      // undefined.
      //
      // Telling the plugin to treat these as "may have dynamic require
      // / complex UMD" and wrap them in a synthetic CJS runtime fixes
      // the IIFE wrapper rewrite. Both files then bundle cleanly.
      //
      // (Cost: those modules no longer get tree-shaken, since they're
      // loaded as opaque dynamic-imports. The bundle grows by ~80 KB
      // for sax and ~600 KB for crypto-js. We then alias crypto-js to
      // an empty stub at the rollup-config alias layer (above) since we
      // don't actually need its AES in the smoke test — login flows
      // are out of scope for the initial mobile bundle.)
      dynamicRequireTargets: [
        'node_modules/crypto-js/**/*.js',
        'node_modules/sax/**/*.js',
      ],
    }),
    json(),

    // 5) Use esbuild as the JS transform engine — fast minification and
    //    modern syntax downleveling for QuickJS.
    esbuildPlugin({
      target: 'es2020',
      minify: false,    // keep readable while iterating
      tsconfig: false,
      loaders: { '.js': 'js', '.mjs': 'js' },
    }),

    // 6) Suppress process.env.NODE_ENV warnings from upstream CJS.
    replace({
      preventAssignment: true,
      values: {
        'process.env.NODE_ENV': JSON.stringify('production'),
      },
    }),
  ],
});

await bundle.write({
  file: OUTFILE,
  format: 'iife',
  name: 'NcmBundle',
  banner,
  sourcemap: false,
  // Force all dynamic imports to be inlined into the single IIFE chunk.
  // Without this, Rollup splits into multiple chunks and refuses the
  // iife format ("UMD and IIFE output formats are not supported for
  // code-splitting builds"). The crypto-node-forge shim and friends
  // are referenced via require() chains that the commonjs plugin turns
  // into dynamic imports; we want them all in one IIFE for QuickJS.
  inlineDynamicImports: true,
});

await bundle.close();

const size = statSync(OUTFILE).size;
const elapsed = Date.now() - t0;
console.log(`OK: bundle.rollup.js written (${(size / 1024 / 1024).toFixed(2)} MB) in ${elapsed} ms`);
