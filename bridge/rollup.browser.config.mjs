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
const root = path.resolve(__dirname, '..');

const ENTRY     = path.join(root, 'assets', 'bridge', 'dist', 'mobile_entry.js');
const OUTFILE   = path.join(root, 'assets', 'bridge', 'dist', 'bundle.rollup.js');
const SHIM_PATH = path.join(root, 'assets', 'bridge', 'dist', 'runtime_shim.js');

// Mobile bundle = bare runtime (QuickJS has no jsdom / Watchman SDK).
// stubRegisterChecktokenV2 is exported from build_patches.mjs only when
// process.env.BUILD_TARGET === 'bare'. The patches here are rollup
// text-rewrites driven by the same source — see patches below.
process.env.BUILD_TARGET = 'bare';

const { defaultPlugins } = await import('../assets/bridge/build_patches.mjs');

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
          return path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'jsdom-empty.js');
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
          return path.join(root, 'assets', 'bridge', 'generated_api.js');
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
          return path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'unblock-empty.js');
        }

        // Stub fs and node:fs/promises to an empty module. Upstream NCM
        // fs usage is being removed in the next release (per user direction).
        // Stackline's polyfill-node throws on `fs` by default, which would
        // kill the build; this short-circuits the throw by handing Rollup
        // a path to our empty stub before Stackline's resolveId fires.
        if (source === 'fs' || source === 'node:fs' || source === 'node:fs/promises') {
          return path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'fs-empty.js');
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

    // 3a) crypto polyfill override — Stackline's `crypto` is EMPTY_PATH,
    //     we need a real implementation. Alias `crypto` and `node:crypto`
    //     to a hand-rolled shim that pulls node-forge directly. This
    //     sidesteps Stackline's "throw on crypto unless crypto:true"
    //     guard while still giving upstream NCM a working crypto module.
    {
      name: 'alias-crypto-polyfill',
      resolveId(source) {
        if (source === 'crypto' || source === 'node:crypto') {
          return path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'crypto-node-forge.js');
        }
        return null;
      },
    },

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
      // strictRequires forces every `require()` call site to be treated
      // as a discrete ES module import (with its own named export), rather
      // than letting the plugin try to share/bundle `require('foo')`
      // results across multiple call sites. This is what makes
      // `require('./logger')` in upstream NCM files resolve to a real
      // import statement instead of being left as a runtime require call
      // (which fails in QuickJS — no module system).
      strictRequires: true,
      // Also force all `require()` calls (including relative-path ones
      // like `require('./logger')`) to be statically resolved. Without
      // this, @rollup/plugin-commonjs falls back to leaving the require
      // in the output as a runtime require, which fails in QuickJS.
      dynamicRequireTargets: false,
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
});

await bundle.close();

const size = statSync(OUTFILE).size;
const elapsed = Date.now() - t0;
console.log(`OK: bundle.rollup.js written (${(size / 1024 / 1024).toFixed(2)} MB) in ${elapsed} ms`);
