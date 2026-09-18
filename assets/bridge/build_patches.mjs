// SPDX-License-Identifier: MIT
//
// assets/bridge/build_patches.mjs
//
// Shared esbuild plugins used by BOTH the desktop bundle (build.mjs) and
// the mobile QuickJS bundle (../../bridge/build_browser.mjs). The patches
// address upstream code that does not bundle cleanly:
//   - util/index.js: rewrites a __dirname-relative path for china_ip_ranges.txt
//   - util/request.js: catches missing /tmp/anonymous_token, eager-loads
//     xeapi public key, and normalizes set-cookie header
//   - util/crypto.js: replaces null IV with empty Buffer (bare-crypto compat)
//   - register_checktoken_v2.js: stubs out for bare runtime (gated on BUILD_TARGET=bare)
//   - jsdom's xhr-sync-worker: marks external so require.resolve doesn't fail
//
// Re-imported by:
//   - assets/bridge/build.mjs (desktop, platform:'node')
//   - bridge/build_browser.mjs        (mobile, platform:'browser' + nodeModulesPolyfill)

import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// shimXhrWorker: copy the XHR sync worker shim into dist/ alongside bundle.js
// so runtime require.resolve('./xhr-sync-worker.js') finds it.
// ---------------------------------------------------------------------------
export const shimXhrWorker = {
  name: 'shim-xhr-worker',
  setup(build) {
    build.onResolve({ filter: /^\.\/xhr-sync-worker\.js$/ }, (args) => {
      if (args.kind === 'require-resolve' && args.importer.includes('jsdom')) {
        return { path: args.path, external: true };
      }
      return null;
    });
    build.onEnd(() => {
      const src = path.resolve(__dirname, 'shims/xhr-sync-worker.js');
      const dest = path.resolve(__dirname, 'dist/xhr-sync-worker.js');
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(src, dest);
      console.log('[patch] copied xhr-sync-worker.js -> dist/');
    });
  },
};

// ---------------------------------------------------------------------------
// fixChinaIpRangesPath: util/index.js does path.join(__dirname, '../data/...'),
// but post-bundle __dirname is dist/, so the relative path resolves wrong.
// Rewrite to a bundle-relative path that works in both desktop and mobile.
// ---------------------------------------------------------------------------
export const fixChinaIpRangesPath = {
  name: 'fix-china-ip-ranges-path',
  setup(build) {
    build.onLoad({ filter: /util[\\/]+index\.js$/ }, async (args) => {
      const src = await fs.promises.readFile(args.path, 'utf8');
      const patched = src.replace(
        "path.join(__dirname, '../data/china_ip_ranges.txt')",
        "path.join(__dirname, 'data/china_ip_ranges.txt')",
      );
      if (patched === src) return;
      console.log('[patch] rewrote china_ip_ranges.txt path in', path.relative(__dirname, args.path));
      return { contents: patched, loader: 'js' };
    });
  },
};

// ---------------------------------------------------------------------------
// fixRequestJs: three patches in a single onLoad (esbuild runs at most one
// plugin per file). See assets/bridge/build.mjs for full rationale.
// ---------------------------------------------------------------------------
export const fixRequestJs = {
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
      {
        const ensureFn = [
          "// PATCHED: lazy-load xeapi public key once, cache in module scope.",
          "const __ncmEnsureXeapi = async () => {",
          "  if (xeapi_public_key) return",
          "  const { getXeapiPublicKey } = require('./xeapiKey')",
          "  const deviceId = global.deviceId || require('./index').generateDeviceId()",
          "  const next = await getXeapiPublicKey(",
          "    xeapi_public_key || {},",
          "    deviceId,",
          "  )",
          "  xeapi_public_key = next",
          "  global.deviceId = deviceId",
          "}",
        ].join('\n        ');

        const originalEntry = "const createRequest = async (uri, data, options) => {\n  let token = ''";
        const replacementEntry = `const createRequest = async (uri, data, options) => {
  let token = ''
  ${ensureFn}
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

      // PATCH 3: axios set-cookie compat for bare runtime.
      {
        const original = "        answer.cookie = (res.headers['set-cookie'] || []).map((x) =>";
        const replacement = "        answer.cookie = (typeof res.headers['set-cookie'] === 'string' ? [res.headers['set-cookie']] : (res.headers['set-cookie'] || [])).map((x) =>";
        const next = src.replace(original, replacement);
        if (next !== src) {
          console.log('[patch] wrapped set-cookie string→array in util/request.js');
          src = next;
        } else {
          console.warn('[patch] WARNING: set-cookie pattern not found in util/request.js');
        }
      }

      return { contents: src, loader: 'js' };
    });
  },
};

// ---------------------------------------------------------------------------
// fixCryptoNullIv: bare-crypto rejects null IV even for ECB mode.
// ---------------------------------------------------------------------------
export const fixCryptoNullIv = {
  name: 'fix-crypto-null-iv',
  setup(build) {
    build.onLoad({ filter: /util[\\/]+crypto\.js$/ }, async (args) => {
      let src = await fs.promises.readFile(args.path, 'utf8');
      const original = `const cipher = crypto.createCipheriv(\`aes-\${key.length * 8}-ecb\`, key, null)`;
      const replacement = `const cipher = crypto.createCipheriv(\`aes-\${key.length * 8}-ecb\`, key, Buffer.alloc(0))`;
      let next = src.replace(original, replacement);
      const original2 = `const decipher = crypto.createDecipheriv(
    \`aes-\${key.length * 8}-ecb\`,
    key,
    null,
  )`;
      const replacement2 = `const decipher = crypto.createDecipheriv(
    \`aes-\${key.length * 8}-ecb\`,
    key,
    Buffer.alloc(0),
  )`;
      next = next.replace(original2, replacement2);
      if (next !== src) {
        console.log('[patch] crypto.createDecipheriv: null IV → Buffer.alloc(0) in', path.relative(__dirname, args.path));
        src = next;
      } else {
        console.warn('[patch] WARNING: crypto.js IV pattern not found in', path.relative(__dirname, args.path));
      }
      return { contents: src, loader: 'js' };
    });
  },
};

// ---------------------------------------------------------------------------
// stubRegisterChecktokenV2: only when BUILD_TARGET=bare.
// ---------------------------------------------------------------------------
export const stubRegisterChecktokenV2 = process.env.BUILD_TARGET === 'bare'
  ? {
      name: 'stub-register-checktoken-v2',
      setup(build) {
        build.onLoad({ filter: /register_checktoken_v2\.js$/ }, () => {
          console.log('[patch] stubbing register_checktoken_v2 (bare build)');
          return {
            contents: [
              "// PATCHED stub for bare — no jsdom, no Watchman SDK.",
              "// v2 anti-cheat tokens are unobtainable in bare runtime;",
              "// we return '' so callers degrade gracefully server-side.",
              "module.exports = async () => ({",
              "  status: 200,",
              "  body: { code: 200, token: '', registered: false },",
              "})",
              "module.exports.getToken = async () => ''",
            ].join('\n'),
            loader: 'js',
          };
        });
      },
    }
  : null;

// Default plugin set for both desktop and mobile. The checktoken v2 stub
// is only included when BUILD_TARGET=bare — set this env var in the mobile
// build context (QuickJS has no jsdom / Watchman SDK).
export const defaultPlugins = [
  shimXhrWorker,
  fixChinaIpRangesPath,
  fixRequestJs,
  fixCryptoNullIv,
  ...(stubRegisterChecktokenV2 ? [stubRegisterChecktokenV2] : []),
];
