// SPDX-License-Identifier: MIT
//
// bridge/build_browser.mjs — produce bundle.browser.js for the
// flutter_js / QuickJS mobile runtime.
//
// Differences from the desktop node bundle:
//   1. platform: 'browser' — drives axios to use the xhr adapter
//   2. nodeModulesPolyfillPlugin — stubs every node builtin with empty/no-op
//      (per user direction: upstream fs usage will be removed in the next
//      release; we stub all fs.* and node:fs/promises with 'empty' now so
//      we don't have to re-bundle when the upstream change lands)
//   3. alias axios http/https adapters → xhr (defensive belt-and-suspenders
//      in case esbuild still resolves them under platform: 'browser')
//   4. injects globals: process, Buffer (defaults handled by the plugin)
//   5. banner — prepend runtime_shim.js so the bundle rewires its I/O off
//      process.stdin/stdout and onto flutter_js's sendMessage channels
//
// Input:  assets/bridge/bridge.js  (same source as the desktop build)
// Output: assets/bridge/dist/bundle.browser.js

import { build } from 'esbuild';
import { nodeModulesPolyfillPlugin } from 'esbuild-plugins-node-modules-polyfill';
import { readFileSync, statSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

// Mobile bundle targets the QuickJS / flutter_js runtime, which has no
// jsdom / Watchman SDK. The same bare-target patches that disable
// register_checktoken_v2 in the desktop bare build apply here.
//
// We must set BUILD_TARGET BEFORE the build_patches import, but ES module
// imports are hoisted to the top of the file. Use a dynamic import wrapped
// in an async IIFE that sets the env first, then loads the patches module.
// Note: Node's ESM loader respects `process.env` mutations made before a
// dynamic import resolves the target module.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');

// Every node builtin in this map gets its REAL polyfill from
// @jspm/core/nodelibs/<module> (browser-ready implementations of the
// node API). Modules we want STUBBED get 'empty'.
//
// Critical: when fallback:'empty' (set below), the plugin emits empty
// stubs for ANY node builtin not in this map. So we MUST list every
// builtin the bundle genuinely touches with `true` to get a real impl.
//
// Verified during Phase 0 + Task 1.5 (smoke test runs):
//   - path/events/util/stream: sax/parser.js, xml2js, axios internals
//   - buffer/process: globals, injected separately
//   - crypto: xeapi code path uses createHash/createDecipheriv
//   - querystring/url/string_decoder/timers/os/assert: ubiquitous in
//     axios + util/request.js + xml2js internals
//
// STUBBED with 'empty' (per user direction that the upstream fs paths
// are being removed in the next release, plus no portable semantics
// for the network APIs):
//   - fs / node:fs/promises: throw ENOENT everywhere; upstream handles
//   - http / https: replaced by axios xhr adapter (flutter_js XHR)
//   - child_process / dns / net / tls / tty / vm / async_hooks / http2:
//     no browser equivalent
// Plugin that intercepts `require('events')` and redirects to our CJS shim.
// Must register BEFORE the nodeModulesPolyfillPlugin so our onResolve runs
// first (plugins' onResolve handlers fire in registration order; the polyfill
// plugin's filter would otherwise intercept 'events' and route to @jspm/core).
//
// Why this is needed: @jspm/core/nodelibs/browser/events.js exports
// `{ EventEmitter, defaultMaxListeners, ... }` as its ESM default — an
// object, NOT the EventEmitter constructor. xml2js does
// `extend(Parser, require('events'))` which assumes require('events')
// === EventEmitter (the constructor). With the @jspm export shape, Parser
// silently fails to inherit and methods like `removeAllListeners` are
// missing on Parser instances, crashing at `new Parser(...)` in voice_upload.js.
//
// Our shim (dist/polyfills/events.js) exports the constructor directly:
//   module.exports = EventEmitter;
// so xml2js's extend() works as it does on real node.
const overrideEventsPlugin = {
  name: 'override-events',
  setup(build) {
    build.onResolve({ filter: /^events$/ }, () => ({
      path: path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'events.js'),
    }));
  },
};

const POLYFILLED_MODULES = {
  // Real polyfills
  path:                true,
  events:              true,
  util:                true,
  stream:              true,
  crypto:              true,
  querystring:         true,
  url:                 true,
  string_decoder:      true,
  timers:              true,
  os:                  true,
  assert:              true,
  buffer:              true,
  // `process` is independent from `globals.process` (which is an esbuild
  // `inject` that defines a global variable). The module form covers
  // `require('process')` calls — these need a real polyfill because
  // upstream NCM's util/option.js reads `process.env.ENABLE_RANDOM_CN_IP`
  // and `process.env.NETEASE_COOKIE`. globals.process:true alone leaves
  // require('process') as an empty stub (process namespace falls back to
  // 'empty' because the module map doesn't list it).
  process:             true,
  // Stubs
  fs:                  'empty',
  'node:fs/promises':  'empty',
  // http / https are stubbed to empty (we don't want axios to actually
  // use node's http adapter — flutter_js's XHR goes through dart:http).
  // But agent-base (transitive via pac-proxy-agent → jsdom) does
  // `class extends http.Agent`, which requires http.Agent to be a
  // constructor. jspm's http polyfill provides a no-op Agent class, so
  // listing http:true satisfies `extends` without enabling real HTTP.
  http:                true,
  https:               true,
  child_process:       'empty',
  dns:                 'empty',
  net:                 'empty',
  tls:                 'empty',
  tty:                 'empty',
  vm:                  'empty',
  async_hooks:         'empty',
  http2:               'empty',
};

const SHIM_PATH = path.join(root, 'assets', 'bridge', 'dist', 'runtime_shim.js');
const ENTRY     = path.join(root, 'assets', 'bridge', 'dist', 'mobile_entry.js');
const OUTFILE   = path.join(root, 'assets', 'bridge', 'dist', 'bundle.browser.js');

process.env.BUILD_TARGET = 'bare';

const { defaultPlugins } = await import('../assets/bridge/build_patches.mjs');

const t0 = Date.now();
const result = await build({
  entryPoints: [ENTRY],
  bundle: true,
  outfile: OUTFILE,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: false,            // keep readable while we iterate
  sourcemap: false,
  write: false,             // required by nodeModulesPolyfillPlugin when fallback:'empty'
  logLevel: 'info',
  metafile: true,
  // music-metadata v11+ uses pure ESM with `exports` map that only
  // exposes `import` / `module-sync`. The desktop build (build.mjs)
  // already passes `conditions: ['module-sync']` for the same reason.
  // We carry the same condition here so music-metadata and its ESM dep
  // graph inline into the browser bundle.
  conditions: ['module-sync', 'browser'],
  // Plugins are processed in order; onResolve for 'events' must run BEFORE
  // nodeModulesPolyfillPlugin so we can substitute our CJS shim before the
  // polyfill plugin's own resolver (which would route through @jspm/core
  // and produce the wrong export shape for xml2js).
  plugins: [
    ...defaultPlugins,
    overrideEventsPlugin,
    nodeModulesPolyfillPlugin({
      modules: POLYFILLED_MODULES,
      globals: { process: true, Buffer: true },
      fallback: 'empty',
    }),
  ],
  alias: {
    // Stub out jsdom entirely on mobile. axios.browser.cjs references
    // jsdom's XMLHttpRequest class (not the browser native one), but
    // jsdom cannot run in QuickJS — it needs DOM, Canvas, workers. We
    // replace jsdom with an empty module so the require chain resolves
    // without dragging in thousands of broken DOM files.
    //
    // At runtime, axios's xhr adapter calls `new XMLHttpRequest()` — we
    // install a minimal XHR shim in runtime_shim.js that delegates to
    // the dart:http bridge (see flutter_js's sendMessage/onMessage setup
    // in lib/src/mobile/ncm_js_runtime.dart, which sets
    // `globalThis.XMLHttpRequest = makeNcmXhr()` before evaluating the bundle).
    jsdom: path.join(root, 'assets', 'bridge', 'dist', 'polyfills', 'jsdom-empty.js'),
    // Defensive axios adapter alias (esbuild alias doesn't reliably fire
    // before plugin onResolve in this build context, but it doesn't hurt
    // to keep this here as belt-and-suspenders).
    'axios/lib/adapters/http.js':  'axios/lib/adapters/xhr.js',
    'axios/lib/adapters/https.js': 'axios/lib/adapters/xhr.js',
  },
  banner: { js: readFileSync(SHIM_PATH, 'utf8') },
});

// write:false makes the polyfill plugin own the output; it returns the
// assembled JS in result.outputFiles[0].contents. Write it to disk ourselves.
writeFileSync(OUTFILE, result.outputFiles[0].text);

const size = statSync(OUTFILE).size;
const elapsed = Date.now() - t0;
console.log(`OK: bundle.browser.js written (${(size / 1024 / 1024).toFixed(2)} MB) in ${elapsed} ms`);
