// assets/bridge/patch.mjs

import path from "node:path";
import fs from "node:fs";

import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const bridgeDir = __dirname;

/**
 * Convert file URL to local path.
 */
function pathFromURL(url) {
  if (typeof url === "string") {
    url = new URL(url);
  }

  return url.protocol === "file:" ? fileURLToPath(url) : null;
}

/**
 * Apply all source patches.
 *
 * target:
 *
 *   "esbuild"
 *      Source is going through esbuild.
 *
 *   "bare"
 *      Source is going directly into bare-pack.
 *
 * IMPORTANT:
 *
 * These two pipelines do NOT have the same filesystem layout.
 *
 * build:
 *
 *   original source
 *       -> patch
 *       -> esbuild
 *       -> dist/bundle.js
 *
 * pack:
 *
 *   original source
 *       -> patch
 *       -> bare-pack
 *       -> dist/ncm.bundle
 *
 * Therefore patches which depend on esbuild's output layout MUST NOT
 * be applied to the bare-pack source graph.
 */
export function patchSource(filePath, source, { target = "esbuild" } = {}) {
  let src = source;

  // ------------------------------------------------------------
  // util/index.js
  // ------------------------------------------------------------
  //
  // IMPORTANT:
  //
  // This patch is ONLY for the esbuild pipeline.
  //
  // Original source:
  //
  //   util/index.js
  //       ../data/china_ip_ranges.txt
  //
  // points to:
  //
  //   api/data/china_ip_ranges.txt
  //
  // When bundled into dist/bundle.js, the generated code needs the
  // copied asset under:
  //
  //   dist/data/china_ip_ranges.txt
  //
  // Bare-pack does NOT flatten the module, so the original relative
  // path is correct and MUST remain unchanged.
  //
  if (target === "esbuild" && /util[\/\\]+index\.js$/.test(filePath)) {
    const original = "path.join(__dirname, '../data/china_ip_ranges.txt')";

    const replacement = "path.join(__dirname, 'data/china_ip_ranges.txt')";

    const next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] rewrote china_ip_ranges.txt path in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }
  }
  // ------------------------------------------------------------
  // util/request.js
  // ------------------------------------------------------------

  if (/util[\/\\]+request\.js$/.test(filePath)) {
    // ----------------------------------------------------------
    // PATCH 1: anonymous_token
    // ----------------------------------------------------------

    const original = `const anonymous_token = fs.readFileSync(
  path.resolve(tmpPath, './anonymous_token'),
  'utf-8',
)`;

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
    ].join("\n");

    let next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] wrapped anonymous_token read in try/catch in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }

    // ----------------------------------------------------------
    // PATCH 2: xeapi public key
    // ----------------------------------------------------------

    const ensureFn = [
      "// PATCHED: lazy-load xeapi public key once, cache in module scope.",
      "const __ncmEnsureXeapi = async () => {",
      "  if (xeapi_public_key) return",
      "  const { getXeapiPublicKey } = require('./xeapiKey')",
      "  const deviceId =",
      "    global.deviceId || require('./index').generateDeviceId()",
      "  const next = await getXeapiPublicKey(",
      "    xeapi_public_key || {},",
      "    deviceId,",
      "  )",
      "  xeapi_public_key = next",
      "  global.deviceId = deviceId",
      "}",
    ].join("\n");

    const originalEntry =
      "const createRequest = async (uri, data, options) => {\n  let token = ''";

    const replacementEntry = `const createRequest = async (uri, data, options) => {
  let token = ''

  ${ensureFn}

  if (!xeapi_public_key) {
    await __ncmEnsureXeapi()
  }`;

    next = src.replace(originalEntry, replacementEntry);

    if (next !== src) {
      console.log(
        "[patch] eager-fetch xeapi public key in createRequest in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }

    // ----------------------------------------------------------
    // PATCH 3: set-cookie
    // ----------------------------------------------------------

    const cookieOriginal =
      "        answer.cookie = (res.headers['set-cookie'] || []).map((x) =>";

    const cookieReplacement =
      "        answer.cookie = (typeof res.headers['set-cookie'] === 'string' ? [res.headers['set-cookie']] : (res.headers['set-cookie'] || [])).map((x) =>";

    next = src.replace(cookieOriginal, cookieReplacement);

    if (next !== src) {
      console.log(
        "[patch] wrapped set-cookie string→array in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }
  }

  // ------------------------------------------------------------
  // util/crypto.js
  // ------------------------------------------------------------

  if (/util[\/\\]+crypto\.js$/.test(filePath)) {
    const original = `const cipher = crypto.createCipheriv(\`aes-\${key.length * 8}-ecb\`, key, null)`;

    const replacement = `const cipher = crypto.createCipheriv(\`aes-\${key.length * 8}-ecb\`, key, Buffer.alloc(0))`;

    const next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] replaced AES-ECB null IV in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }

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

    const next2 = src.replace(original2, replacement2);

    if (next2 !== src) {
      console.log(
        "[patch] replaced AES-ECB decipher null IV in",
        path.relative(bridgeDir, filePath),
      );

      src = next2;
    }
  }

  // ------------------------------------------------------------
  // debug/src/index.js
  // ------------------------------------------------------------
  //
  // debug picks its implementation at module-load time:
  //
  //   if (process is browser-ish)  -> require('./browser.js')
  //   else                          -> require('./node.js')
  //
  // node.js does `require('tty')` + `require('util')` + `require('supports-color')`,
  // none of which bare-pack can resolve:
  //
  //   tty      -> missing (we polyfill node_modules/tty/ but...
  //   util     -> missing (no node_modules/util/, bare-utils is at a different specifier
  //              and bare-pack does not auto-redirect require('util'))
  //   supports-color -> resolves to its Node entry which itself
  //              imports `os` etc.
  //
  // The browser.js branch has zero external dependencies — it is exactly
  // what electron / nwjs / browser bundles use. We don't stub debug;
  // we just force it onto its official browser branch. Logging,
  // namespaces, formatters, save/load all keep working — only ANSI
  // colour detection is gone, which is correct for an NDJSON bridge.
  //
  // This patch is ONLY for the bare-pack pipeline.
  //
  if (target === "bare" && /debug[\\/\\\\]+src[\\/\\\\]+index\.js$/.test(filePath)) {
    const replacement = `// PATCHED FOR BARE: force the browser branch.
// See patch.mjs — debug/node.js pulls in 'tty', 'util', 'supports-color'
// which bare-pack cannot resolve. browser.js has zero external deps
// and is the official path for non-Node runtimes (electron, nwjs, web).
module.exports = require('./browser.js')
`;

    if (src !== replacement) {
      console.log(
        "[patch] forced debug/src/index.js onto browser branch in",
        path.relative(bridgeDir, filePath),
      );

      src = replacement;
    }
  }

  // ------------------------------------------------------------
  // music-metadata consumer: cloud.js
  // ------------------------------------------------------------
  //
  // cloud.js does `mm = require('music-metadata')` synchronously and
  // then awaits `mm.parseBuffer(...)`. music-metadata v11+ is pure
  // ESM with package.json#exports shaped as
  // `{node: {import: ...}, default: {import: ...}}` — no `require`
  // condition. bare-pack's resolver walks require('music-metadata')
  // with conditions `['require', 'bare', 'node', ...]` and fails with
  // PACKAGE_PATH_NOT_EXPORTED.
  //
  // bare-pack's lexer recognises `await import('…')` as IMPORT
// (conditions `['import', 'bare', 'node', ...]`), which DOES match
  // music-metadata's exports. Rewrite the synchronous require to a
  // cached dynamic import. cloud.js already runs inside an async
  // function, so the caller can `await` mm.
  //
  // This rewrite is ONLY for bare-pack.
  //
  if (
    target === "bare" &&
    /neteasecloudmusicapienhanced[\\/\\\\]+api[\\/\\\\]+module[\\/\\\\]+cloud\.js$/.test(
      filePath,
    )
  ) {
    const original =
      "let mm\n" +
      "module.exports = async (query, request) => {\n" +
      "  mm = require('music-metadata')";

    const replacement =
      "let mmPromise\n" +
      "module.exports = async (query, request) => {\n" +
      "  // PATCHED FOR BARE: dynamic import so music-metadata's\n" +
      "  // ESM-only exports map resolves.\n" +
      "  if (!mmPromise) {\n" +
      "    mmPromise = import('music-metadata').then((m) => m.default || m)\n" +
      "  }\n" +
      "  const mm = await mmPromise";

    const next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] rewrote music-metadata require -> dynamic import in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }
  }

  // ------------------------------------------------------------
  // register_checktoken_v2.js
  // ------------------------------------------------------------
  //
  // This module uses jsdom/Watchman/browser-side anti-cheat logic.
  //
  // It cannot run in Bare.
  //
  // IMPORTANT:
  //
  // This stub is ONLY inserted for bare-pack.
  //
  if (target === "bare" && /register_checktoken_v2\.js$/.test(filePath)) {
    const stub = `
// PATCHED FOR BARE
//
// register_checktoken_v2 depends on browser/jsdom/watchman functionality
// which is unavailable in the Bare runtime.
//
// Keep the exported API shape but make the operation a no-op.

module.exports = async function registerChecktokenV2() {
  return undefined
}
`;

    console.log("[patch] stubbed register_checktoken_v2.js for Bare");

    src = stub;
  }

  // ------------------------------------------------------------
  // node-forge/lib/util.js
  // ------------------------------------------------------------
  //
  // node-forge auto-detects its host environment through `util.isNodejs`
  // and treats Bare as non-Node, which forces it onto a browser-shaped
  // code path that crashes on missing window/document. Forcing it to
  // recognise Bare as Node is enough to keep node-forge's Node branch
  // active under bare-pack.
  //
  // On the esbuild pipeline the runtime is Node, so Bare is undefined
  // and this rewrite is dead code — gate it.
  //
  if (
    target === "bare" &&
    /node-forge[\\/]+lib[\\/]+util\.js$/.test(filePath)
  ) {
    const original = `util.isNodejs =
  typeof process !== 'undefined' && process.versions && process.versions.node;`;

    const replacement = `util.isNodejs =
  (typeof process !== 'undefined' && process.versions && process.versions.node) ||
  (typeof Bare !== 'undefined' && Bare);`;

    const next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] patched node-forge Node detection in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }
  }

  // ------------------------------------------------------------
  // node-forge/lib/prng.js
  // ------------------------------------------------------------
  //
  // node-forge's PRNG guard references `process.versions['node-webkit']`.
  // Bare's `process.versions` exists but reading an absent key can throw
  // depending on the runtime build. Wrapping the access in a
  // `typeof process === 'undefined' || …` short-circuit keeps the guard
  // truthy under bare-pack without changing behaviour elsewhere.
  //
  // On the esbuild pipeline the runtime is Node, where process.versions
  // is always present — the short-circuit is dead code — gate it.
  //
  if (
    target === "bare" &&
    /node-forge[\\/]+lib[\\/]+prng\.js$/.test(filePath)
  ) {
    const original = "!process.versions['node-webkit']) {";

    const replacement =
      "(typeof process === 'undefined' || !process.versions['node-webkit'])) {";

    const next = src.replace(original, replacement);

    if (next !== src) {
      console.log(
        "[patch] patched node-forge node-webkit detection in",
        path.relative(bridgeDir, filePath),
      );

      src = next;
    }
  }

  // ------------------------------------------------------------
  // bridge.js
  // ------------------------------------------------------------
  //
  // bare-node-runtime/global pulls in the bare-* addon shims
  // (bare-crypto, bare-events, …) and overrides process.versions.node
  // for compatibility. bare-pack needs it; the nodejs-mobile embed
  // runtime that consumes dist/bundle.js does not.
  //
  if (
    target === "bare" &&
    path.resolve(filePath) === path.resolve(path.join(bridgeDir, "bridge.js"))
  ) {
    const POLYFILL = `// bare runtime polyfill
require('bare-node-runtime/global')

`;

    if (!src.startsWith(POLYFILL)) {
      console.log("[patch] injected bare-node-runtime/global into bridge.js");

      src = POLYFILL + src;
    }
  }

  return src;
}

/**
 * Read + patch one file.
 *
 * This is a generic helper for callers that already have a URL.
 *
 * Default target is Bare because this helper is primarily intended for
 * direct module consumers.
 */
export async function readPatchedModule(url, { target = "bare" } = {}) {
  const filePath = pathFromURL(url);

  if (!filePath) {
    return null;
  }

  let source;

  try {
    source = await fs.promises.readFile(filePath, "utf8");
  } catch (error) {
    //
    // These are normal candidate-probing failures from module resolvers.
    //
    if (error?.code === "ENOENT" || error?.code === "EISDIR") {
      return null;
    }

    throw error;
  }

  return Buffer.from(patchSource(filePath, source, { target }), "utf8");
}

/**
 * esbuild plugin.
 *
 * build.js uses:
 *
 *   patchSource(..., { target: 'esbuild' })
 *
 * so esbuild-specific patches such as the china_ip_ranges path rewrite
 * remain isolated from bare-pack.
 */
export function createPatchPlugins() {
  return [
    {
      name: "shared-source-patches",

      setup(build) {
        build.onLoad(
          {
            filter:
              /(?:^|[\/\\])(?:util[\/\\]+(?:index|request|crypto)|node-forge[\/\\]+lib[\/\\]+(?:util|prng)|register_checktoken_v2|bridge)\.js$/,
          },

          async (args) => {
            const source = await fs.promises.readFile(args.path, "utf8");

            return {
              contents: patchSource(args.path, source, {
                target: "esbuild",
              }),

              loader: "js",
            };
          },
        );
      },
    },
  ];
}

/**
 * xhr-sync-worker is not a source patch.
 *
 * It is an external runtime asset, so keep its handling separate.
 */
export function createXhrWorkerPlugin() {
  return {
    name: "shim-xhr-worker",

    setup(build) {
      build.onResolve(
        {
          filter: /^\.\/.*xhr-sync-worker\.js$/,
        },

        (args) => {
          if (
            args.kind === "require-resolve" &&
            args.importer.includes("jsdom")
          ) {
            return {
              path: args.path,
              external: true,
            };
          }

          return null;
        },
      );

      build.onEnd(() => {
        const src = path.resolve(bridgeDir, "shims/xhr-sync-worker.js");

        const dest = path.resolve(bridgeDir, "dist/xhr-sync-worker.js");

        fs.mkdirSync(path.dirname(dest), {
          recursive: true,
        });

        fs.copyFileSync(src, dest);

        console.log("[shim] copied xhr-sync-worker.js -> dist/");
      });
    },
  };
}
