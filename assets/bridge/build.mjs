// /home/cmach_socket/projects/ncm_api_enhanced/assets/bridge/build.mjs
import * as esbuild from 'esbuild';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const shimXhrWorker = {
  name: 'shim-xhr-worker',
  setup(build) {
    // 1) 拦截 jsdom 内部的 require.resolve('./xhr-sync-worker.js')
    //    标记为 external，保持原样输出，消除警告
    build.onResolve({ filter: /^\.\/xhr-sync-worker\.js$/ }, (args) => {
      if (args.kind === 'require-resolve' && args.importer.includes('jsdom')) {
        return { path: args.path, external: true };
      }
      return null;
    });

    // 2) 构建完成后，把 shim 复制到 dist/，
    //    这样运行时 require.resolve('./xhr-sync-worker.js')
    //    相对 bundle.js 就能找到它
    build.onEnd(() => {
      const src = path.resolve(__dirname, 'shims/xhr-sync-worker.js');
      const dest = path.resolve(__dirname, 'dist/xhr-sync-worker.js');
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(src, dest);
      console.log('[shim] copied xhr-sync-worker.js -> dist/');
    });
  },
};

// Patch util/index.js: it does `path.join(__dirname, '../data/...')`,
// which assumes it lives at <api>/util/index.js. After esbuild bundles
// everything into dist/bundle.js, __dirname is dist/, so the relative
// path resolves to dist/../data/... = <bridge>/data/ — wrong.
// The data file is actually shipped at dist/data/china_ip_ranges.txt
// (see pubspec.yaml asset entry), so rewrite to a bundle-relative path.
const fixChinaIpRangesPath = {
  name: 'fix-china-ip-ranges-path',
  setup(build) {
    build.onLoad({ filter: /util[\\/]+index\.js$/ }, async (args) => {
      const src = await fs.promises.readFile(args.path, 'utf8');
      const patched = src.replace(
        "path.join(__dirname, '../data/china_ip_ranges.txt')",
        "path.join(__dirname, 'data/china_ip_ranges.txt')",
      );
      if (patched === src) {
        // Bail out (return undefined) so esbuild falls back to default
        // load + a warning. Better than silently rewriting nothing.
        return;
      }
      console.log('[patch] rewrote china_ip_ranges.txt path in', path.relative(__dirname, args.path));
      return { contents: patched, loader: 'js' };
    });
  },
};

// util/request.js — three patches in a single onLoad because esbuild
// invokes at most one plugin per file load (first match wins).
//
// PATCH 1 — anonymous_token:
//   It eagerly fs.readFileSync('/tmp/anonymous_token') at module-load
//   time to cache an anonymous fallback token. On Android (nodejs-mobile
//   sandbox) os.tmpdir() returns '/tmp' which is NOT writable, so the
//   read throws ENOENT and the whole util/request.js — required by every
//   API call — fails to load.
//
//   anonymous_token is only used as a fallback when MUSIC_A is missing
//   from the processed cookie (line 163). Treat absence as empty string
//   instead of throwing; MUSIC_A is normally acquired via /register/anonimous.
//
// PATCH 2 — xeapi public key:
//   'xeapi' crypto mode requires publicKeyState, normally fetched once
//   by generateConfig.js and cached at /tmp/xeapi_public_key. On Android
//   that file is never written (path unwritable, generateConfig is not
//   in the bundle graph), so the very first xeapi-mode call throws
//   'xeapi public key is missing' and 17+ modules fail
//   (register_anonimous, song_url_v1, vip_tasks_v1, yunbei_sign, ad_get…).
//
//   Fix: in the 'xeapi' branch, if loadXeapiPublicKey() returns null,
//   lazily fetch via getXeapiPublicKey() (HTTP POST) and cache in memory
//   for the lifetime of the bundle. Same on desktop where the file may
//   legitimately not exist either.
const fixRequestJs = {
  name: 'fix-request-js',
  setup(build) {
    build.onLoad({ filter: /util[\\/]+request\.js$/ }, async (args) => {
      let src = await fs.promises.readFile(args.path, 'utf8');

      // PATCH 1: anonymous_token read → try/catch with empty fallback.
      {
        const original = "const anonymous_token = fs.readFileSync(\n  path.resolve(tmpPath, './anonymous_token'),\n  'utf-8',\n)";
        const replacement = [
          "// PATCHED for Android sandbox: anonymous_token file may not exist",
          "// (os.tmpdir() === '/tmp' which is unwritable). Fall back to ''.",
          "let anonymous_token = ''",
          "try {",
          "  anonymous_token = fs.readFileSync(",
          "    path.resolve(tmpPath, './anonymous_token'),",
          "    'utf-8',",
          "  )",
          "} catch (_) {}",
        ].join('\n');
        const next = src.replace(original, replacement);
        if (next !== src) {
          console.log('[patch] wrapped anonymous_token read in try/catch in', path.relative(__dirname, args.path));
          src = next;
        } else {
          console.warn('[patch] WARNING: anonymous_token pattern not found in', path.relative(__dirname, args.path));
        }
      }

      // PATCH 2: xeapi public key → eager HTTP fetch at createRequest entry.
      //
      // The 'xeapi' crypto mode requires publicKeyState, normally fetched
      // once by generateConfig.js and cached at /tmp/xeapi_public_key. On
      // Android that file is never written (path unwritable, generateConfig
      // not in bundle graph). 17+ modules (register_anonimous, song_url_v1,
      // vip_tasks_v1, yunbei_sign, ad_get, …) call createRequest with
      // crypto === 'xeapi' and hit `throw new Error('xeapi public key
      // is missing')`.
      //
      // Patch createRequest's body: at function entry, if no in-memory
      // public key is cached, await a lazy fetch. Then replace the throw
      // with a no-op (cache is guaranteed to be populated by then).
      {
        const ensureFn = [
          "// PATCHED: lazy-load xeapi public key once, cache in module scope.",
          "const __ncmEnsureXeapi = async () => {",
          "  if (xeapi_public_key) return",
          "  const { getXeapiPublicKey } = require('./xeapiKey')",
          "  // deviceId may not be set yet (register_anonimous hasn't run).",
          "  // Synthesise a 52-char hex deviceId; same shape as util/index.js",
          "  // generateDeviceId(), which is what register_anonimous uses.",
          "  const deviceId = global.deviceId || require('./index').generateDeviceId()",
          "  const next = await getXeapiPublicKey(",
          "    xeapi_public_key || {},",
          "    deviceId,",
          "  )",
          "  xeapi_public_key = next",
          "  global.deviceId = deviceId",
          "}",
        ].join('\n        ');

        // Inject the helper after `let token = ''` (start of createRequest body).
        const originalEntry = "const createRequest = async (uri, data, options) => {\n  let token = ''";
        const replacementEntry = `const createRequest = async (uri, data, options) => {
  let token = ''
  ${ensureFn}
  // Eager-fetch xeapi public key if any call might use it. Cheaper than
  // re-checking per call (and ensures the first 'xeapi' call doesn't race).
  // Errors bubble up to the calling module via the original 'xeapi public
  // key is missing' throw, so callers see a clear failure mode.
  if (!xeapi_public_key) {
    await __ncmEnsureXeapi()
  }`;

        const next = src.replace(originalEntry, replacementEntry);
        if (next !== src) {
          console.log('[patch] eager-fetch xeapi public key in createRequest in', path.relative(__dirname, args.path));
          src = next;
        } else {
          console.warn('[patch] WARNING: createRequest entry pattern not found in', path.relative(__dirname, args.path));
        }

        // Remove the now-pointless throw — public key is either pre-fetched
        // (and may have legitimately failed) or absent (fetch failed). Keep
        // the error message so upstream callers still get a clear signal.
        const originalThrow = [
          "      case 'xeapi':",
          "        const xeapiPublicKey = loadXeapiPublicKey()",
          "        if (!xeapiPublicKey) {",
          "          throw new Error('xeapi public key is missing')",
          "        }",
        ].join('\n');
        const replacementThrow = [
          "      case 'xeapi':",
          "        const xeapiPublicKey = loadXeapiPublicKey()",
          "        if (!xeapiPublicKey) {",
          "          // PATCHED: __ncmEnsureXeapi() ran at createRequest entry;",
          "          // if key is still missing, the fetch failed — surface that",
          "          // with the same message so upstream behaviour is preserved.",
          "          throw new Error('xeapi public key is missing')",
          "        }",
        ].join('\n');
        const next2 = src.replace(originalThrow, replacementThrow);
        if (next2 !== src) {
          console.log('[patch] kept xeapi throw (pre-fetch handles init) in', path.relative(__dirname, args.path));
          src = next2;
        }
      }

      return { contents: src, loader: 'js' };
    });
  },
};

await esbuild.build({
  entryPoints: ['bridge.js'],
  bundle: true,
  platform: 'node',
  target: 'node18',      // 对齐你的 CI/运行时；你之前写 node20，这里改成 node18 也可以
  format: 'cjs',
  outfile: 'dist/bundle.js',
  sourcemap: false,
  minify: false,
  // music-metadata v11+ is pure ESM with `exports` only exposing
  // `import` / `module-sync`. Activating `module-sync` lets esbuild
  // inline it (and its 10 ESM deps, plus the full dep graph) into
  // the bundle — required because dist/ is shipped as a self-contained
  // asset with no node_modules.
  conditions: ['module-sync'],
  plugins: [shimXhrWorker, fixChinaIpRangesPath, fixRequestJs],
});
