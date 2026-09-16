// assets/bridge/pack.mjs
//
// Build the NCM JS bridge directly from the original Bare module graph.
//
// IMPORTANT:
//
//   build.mjs:
//     bridge.js
//       -> patch.mjs
//       -> esbuild
//       -> dist/bundle.js
//
//   pack.mjs:
//     bridge.js
//       -> patch.mjs
//       -> bare-pack
//       -> dist/ncm.bundle
//
// Do NOT feed dist/bundle.js into bare-pack.
//
// bare-pack needs to see the original module boundaries of Bare native
// packages such as:
//
//   node_modules/bare-path/binding.js
//   node_modules/bare-fs/binding.js
//   node_modules/bare-crypto/binding.js
//
// so that require.addon() can resolve relative to the binding.js module.
//
// Output:
//   assets/bridge/dist/ncm.bundle
//

import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve as resolvePosix } from "node:path";
import { createRequire } from "node:module";
import { env, stdout, stderr, exit, platform, arch } from "node:process";
import { stat, readFile, readdir, writeFile, mkdir } from "node:fs/promises";

import { patchSource } from "./patch.mjs";

//
// --------------------------------------------------------------------------
// Paths
// --------------------------------------------------------------------------
//

const scriptDir = dirname(fileURLToPath(import.meta.url));

const bridgeDir = resolvePosix(scriptDir);

const bridgeNodeModules = resolvePosix(bridgeDir, "node_modules");

const distDir = resolvePosix(bridgeDir, "dist");

//
// IMPORTANT:
//
// Bare-pack MUST start from the original source entry.
//
// Do NOT use:
//
//   dist/bundle.js
//
// because esbuild has already flattened the module graph there and native
// Bare modules such as bare-path/binding.js lose their original referrer.
//

const entryPath = resolvePosix(bridgeDir, "bridge.js");

const outputPath = resolvePosix(distDir, "ncm.bundle");

const esbuildBundlePath = resolvePosix(distDir, "bundle.js");

//
// createRequire() needs an actual CommonJS file path.
//

const bridgeRequire = createRequire(resolvePosix(bridgeDir, "_anchor.cjs"));

//
// --------------------------------------------------------------------------
// Load bare-pack
// --------------------------------------------------------------------------
//

const pack = bridgeRequire(resolvePosix(bridgeNodeModules, "bare-pack"));

const resolveBare = bridgeRequire(
  resolvePosix(bridgeNodeModules, "bare-module-traverse"),
).resolve;

//
// Node -> Bare runtime builtin mappings.
//
// For example:
//
//   fs       -> bare-fs
//   path     -> bare-path
//   crypto   -> bare-crypto
//

const nodeRuntimeImports = JSON.parse(
  await readFile(
    resolvePosix(bridgeNodeModules, "bare-node-runtime/imports.json"),
    "utf8",
  ),
);

// ---------------------------------------------------------------------------
// bare-link: extract every bare-* native addon .so referenced by the
// module graph into android/addons/<host>/, where hook/build.dart can
// pick them up and register them as Flutter code assets.
//
// On iOS and Android, bare-pack writes addon resolutions as
// `linked:lib<name>.<version>.so` specifiers (see pack.mjs: `linked:
// true` below). bare-link is the matching helper that turns those
// specifiers into the actual prebuilt `.so` files baked into the
// host APK. Without bare-link, the worklet runtime at startup would
// hit ADDON_NOT_FOUND for every `linked:libbare-*.so` it tries to
// load.
//
// ---------------------------------------------------------------------------

const bareLink = bridgeRequire(
  resolvePosix(bridgeNodeModules, "bare-link"),
);

//
// --------------------------------------------------------------------------
// Validate entry
// --------------------------------------------------------------------------
//

try {
  await stat(entryPath);
} catch {
  stderr.write(`[pack] missing entry: ${entryPath}\n`);

  stderr.write(`[pack] expected source entry: ${bridgeDir}/bridge.js\n`);

  exit(1);
}

//
// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------
//

function pathFromURL(url) {
  return url.protocol === "file:" ? fileURLToPath(url) : null;
}

function isInside(filePath, directory) {
  return filePath === directory || filePath.startsWith(directory + "/");
}

function isJavaScriptFile(filePath) {
  return (
    filePath.endsWith(".js") ||
    filePath.endsWith(".cjs") ||
    filePath.endsWith(".mjs")
  );
}

//
// --------------------------------------------------------------------------
// bare-pack module reader
// --------------------------------------------------------------------------
//
// bare-pack traverses the ORIGINAL module graph.
//
// This is deliberately different from:
//
//   bridge.js -> esbuild -> dist/bundle.js
//
// We need:
//
//   bridge.js
//       |
//       +-- generated_api.js
//       |
//       +-- node_modules/...
//       |
//       +-- Bare native binding.js
//
// to remain separate modules.
//
// --------------------------------------------------------------------------
//
// IMPORTANT FIX:
//
// The previous whitelist only allowed:
//
//   bridge.js
//   node_modules/**
//   dist/**
//
// That caused:
//
//   bridge.js
//     require("./generated_api")
//
// to resolve correctly to:
//
//   assets/bridge/generated_api.js
//
// but then readModule() returned null because generated_api.js was not
// whitelisted.
//
// bare-module-traverse interprets readModule() === null as "module not
// found", resulting in:
//
//   MODULE_NOT_FOUND: Cannot find module './generated_api'
//
// Therefore all ORIGINAL source files under bridgeDir must be readable.
//
// dist/bundle.js is explicitly excluded because it is an esbuild artifact,
// not part of the original module graph.
//

async function readModule(url) {
  const filePath = pathFromURL(url);

  if (!filePath) {
    return null;
  }

  //
  // Only allow files inside the bridge source tree.
  //
  if (!isInside(filePath, bridgeDir)) {
    return null;
  }

  //
  // Never consume esbuild's generated bundle.
  //
  if (filePath === esbuildBundlePath) {
    return null;
  }

  //
  // Never consume the Bare bundle currently being generated.
  //
  if (filePath === outputPath) {
    return null;
  }

  let source;

  try {
    source = await readFile(filePath, "utf8");
  } catch (error) {
    //
    // bare-module-traverse probes multiple candidates.
    //
    // Examples:
    //
    //   ./generated_api
    //   ./generated_api.js
    //
    // and:
    //
    //   ./util
    //   ./util.js
    //   ./util/index.js
    //
    // A candidate can therefore fail because:
    //
    //   ENOENT -> path does not exist
    //   EISDIR -> path exists but is a directory
    //
    // Both mean that this particular candidate is not a readable module.
    // Return null so bare-module-traverse can continue resolving.
    //

    if (error?.code === "ENOENT" || error?.code === "EISDIR") {
      return null;
    }

    //
    // Other filesystem errors are real errors.
    //

    stderr.write(`[pack] readModule failed: ${filePath}\n`);

    stderr.write(`${error?.stack || error}\n`);

    throw error;
  }

  //
  // Non-JavaScript files are returned unchanged.
  //

  if (!isJavaScriptFile(filePath)) {
    return Buffer.from(source, "utf8");
  }

  //
  // Apply Bare-specific patches.
  //

  const patched = patchSource(filePath, source, {
    target: "bare",
  });

  return Buffer.from(patched, "utf8");
}

//
// --------------------------------------------------------------------------
// Asset enumeration
// --------------------------------------------------------------------------
//
// bare-pack can request a file: prefix to enumerate runtime assets.
//
// We only expose dist/ as an asset tree.
//
// node_modules are NOT recursively enumerated here because modules should
// be resolved through bare-module-traverse.
//

async function* listPrefix(url) {
  const dir = pathFromURL(url);

  if (!dir) {
    return;
  }

  //
  // Only enumerate dist/.
  //

  if (dir !== distDir) {
    return;
  }

  let entries;

  try {
    entries = await readdir(dir, {
      withFileTypes: true,
    });
  } catch {
    return;
  }

  for (const entry of entries) {
    const child = resolvePosix(dir, entry.name);

    yield pathToFileURL(child);

    if (!entry.isDirectory()) {
      continue;
    }

    //
    // Recurse one level.
    //
    // Current runtime assets include things such as:
    //
    //   dist/data/*
    //

    let children;

    try {
      children = await readdir(child, {
        withFileTypes: true,
      });
    } catch {
      continue;
    }

    for (const grandchild of children) {
      yield pathToFileURL(resolvePosix(child, grandchild.name));
    }
  }
}

//
// --------------------------------------------------------------------------
// Hosts
// --------------------------------------------------------------------------
//

const HOSTS = (env.HOST ?? `${platform}-${arch}`)
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

//
// --------------------------------------------------------------------------
// Build information
// --------------------------------------------------------------------------
//

stderr.write(`[pack] entry: ${entryPath}\n`);

stderr.write(`[pack] hosts: ${HOSTS.join(", ")}\n`);

stderr.write(`[pack] out:   ${outputPath}\n`);

stderr.write(`[pack] mode:  source -> patch -> bare-pack\n`);

//
// ---------------------------------------------------------------------------
// Bare pack
// ---------------------------------------------------------------------------
//
// First run bare-link for every host we are targeting. bare-link
// walks the same module graph that bare-pack is about to walk and
// writes the prebuilt `.so` for each `bare-*` addon into a host-
// specific subdirectory. On Android / iOS those files become the
// targets of the `linked:lib<name>.<version>.so` specifiers that
// bare-pack writes into the bundle (see `linked: true` below).
//
// We run bare-link for each host entry individually — the tool
// accepts `--out` and treats `--host` as a multi-occurrence flag,
// but writing each host to its own subdirectory makes the host
// layout match what Android Gradle Plugin expects for jniLibs.
//

const androidAddonsRoot = resolvePosix(bridgeDir, "..", "..", "android", "addons");

const androidHosts = HOSTS.filter((host) => host.startsWith("android-"));

if (androidHosts.length > 0) {
  // ---------------------------------------------------------------------
  // Run bare-link for every bare-* addon we depend on.
  //
  // bare-link is per-package — its API takes a single package root and
  // walks its addon prebuilds into `--out`. We can't hand it
  // `bridgeDir` (which is not an addon package itself), so we enumerate
  // the bare-* addons under bridgeDir/node_modules/ and call bare-link
  // once per addon. The walk traverses transitive dependencies, so
  // each addon we list also pulls in its own addons.
  //
  // ---------------------------------------------------------------------

  const outDir = androidAddonsRoot;

  stderr.write(`[pack] bare-link -> ${outDir} (hosts=${androidHosts.join(",")})\n`);

  //
  // bare-link walks `pkg.dependencies` (one level, no transitive
  // recursion through arbitrary package deps), so calling it once
  // with the bridgeDir as the entry would only see @neteasecloudmusicapienhanced/api
  // and miss every transitive `bare-*` addon. The supported pattern
  // is to invoke bare-link once per addon package; it then handles
  // each addon's own deps recursively. Enumerate every addon under
  // bridgeDir/node_modules/bare-* and bare-* (scoped) and link each.
  //

  const bridgeNodeModulesPath = resolvePosix(bridgeDir, "node_modules");
  const bridgeNodeModulesDir = await readdir(bridgeNodeModulesPath, {
    withFileTypes: true,
  });

  let addonCount = 0;

  for (const entry of bridgeNodeModulesDir) {
    if (!entry.isDirectory()) continue;

    if (entry.name === "bare") {
      for (const scoped of await readdir(
        resolvePosix(bridgeNodeModulesPath, "bare"),
        { withFileTypes: true },
      )) {
        if (!scoped.isDirectory()) continue;

        const addonPath = resolvePosix(
          bridgeNodeModulesPath,
          "bare",
          scoped.name,
        );

        const pkgJson = JSON.parse(
          await readFile(resolvePosix(addonPath, "package.json"), "utf8"),
        );

        if (pkgJson.addon === true) {
          for await (const resource of bareLink(addonPath, {
            hosts: androidHosts,
            out: outDir,
            needs: ["libbare-kit.so"],
          })) {
            addonCount++;
          }
        }
      }
    } else if (entry.name.startsWith("bare-")) {
      const addonPath = resolvePosix(bridgeNodeModulesPath, entry.name);

      const pkgJson = JSON.parse(
        await readFile(resolvePosix(addonPath, "package.json"), "utf8"),
      );

      if (pkgJson.addon === true) {
        for await (const resource of bareLink(addonPath, {
          hosts: androidHosts,
          out: outDir,
          needs: ["libbare-kit.so"],
        })) {
          addonCount++;
        }
      }
    }
  }

  stderr.write(`[pack] bare-link processed ${addonCount} addons\n`);

  //
  // libbare-kit.so is mirrored into android/addons/<abi>/ by
  // hook/build.dart, not here. hook has direct access to the
  // prebuilds.zip and can extract the .so for every ABI the host
  // app targets, while pack.mjs only sees the ABIs the user
  // explicitly passed via HOST=. Doing it in the hook keeps the
  // copy idempotent and tied to the same archive download that
  // produces classes.jar.
  //
}

let bundle;

try {
  bundle = await pack(
    pathToFileURL(entryPath),
    {
      //
      // Common ancestor:
      //
      //   assets/bridge/
      //
      // This allows the bundle to retain the original module structure.
      //

      base: pathToFileURL(bridgeDir),

      //
      // Node -> Bare builtin redirects.
      //

      imports: nodeRuntimeImports,

      //
      // Bare-aware module resolver.
      //

      resolve: resolveBare.bare,

      //
      // Conditions:
      //
      // music-metadata v11+ is pure ESM and only exposes its entry via
      // 'module-sync' / 'import' in package.json#exports. Worse, its
      // exports map is wrapped under the 'node' condition:
      //
      //   {
      //     "node": { "module-sync": "./lib/index.js", ... },
      //     "default": { "module-sync": "./lib/core.js",  ... }
      //   }
      //
      // bare-pack does NOT implicitly enable the 'node' condition, so we
      // must opt in explicitly. Mirrors build.mjs so both pipelines
      // resolve identically.
      //

      conditions: ['node', 'module-sync'],

      //
      // Native addon target.
      //
      // Default:
      //
      //   linux-x64
      //
      // Android:
      //
      //   HOST=android-arm64
      //
      // iOS:
      //
      //   HOST=ios-arm64
      //

      hosts: HOSTS,

      //
      // On iOS and Android, native code must be linked ahead of time
      // (typically via System.loadLibrary() / dlopen of an .so bundled
      // into the APK). bare-pack therefore has to write addon
      // resolutions as `linked:` URLs rather than `file:` paths to
      // prebuilt `.bare` artifacts, because the worklet runtime inside
      // a bare-kit Worklet cannot read from disk.
      //
      // bare-link (https://github.com/holepunchto/bare-link) is the
      // matching host-side helper that wires `linked:<name>` to the
      // actual `.so` exposed by libbare-kit. The Dart side hooks
      // libbare-kit.so as a code asset (see hook/build.dart) and
      // bare-link resolves `linked:bare-type` to it at runtime.
      //
      // Omit this on desktop paths where the .bare files are
      // readable from disk and direct `file:` URLs work.
      //

      linked: true,
    },

    //
    // Read original source modules.
    //

    readModule,

    //
    // Enumerate runtime assets.
    //

    listPrefix,
  );
} catch (error) {
  stderr.write("\n[pack] bare-pack failed\n");

  stderr.write(`${error?.stack || error}\n`);

  exit(1);
}

//
// --------------------------------------------------------------------------
// Write bundle
// --------------------------------------------------------------------------
//

const data = bundle.toBuffer();

await writeFile(outputPath, data);

stdout.write(`[pack] wrote ${outputPath} (${data.byteLength} bytes)\n`);

//
// --------------------------------------------------------------------------
// Diagnostics
// --------------------------------------------------------------------------
//

if (bundle.addons?.length) {
  stdout.write("\n[pack] embedded native addons:\n");

  for (const addon of bundle.addons) {
    stdout.write(`  ${addon}\n`);
  }
}

if (bundle.assets?.length) {
  stdout.write("\n[pack] bundled assets:\n");

  for (const asset of bundle.assets) {
    stdout.write(`  ${asset}\n`);
  }
}
