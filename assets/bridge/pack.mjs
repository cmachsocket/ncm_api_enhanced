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
//       -> bundle.addons
//       -> bare-link
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
// The important build order is:
//
//   ORIGINAL GRAPH
//        |
//        v
//   bare-pack
//        |
//        +---- bundle.addons
//        |
//        v
//   resolve actual addon packages
//        |
//        v
//   bare-link
//        |
//        v
//   android/addons/
//
// Output:
//   assets/bridge/dist/ncm.bundle
//

import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve as resolvePosix } from "node:path";
import { createRequire } from "node:module";
import { env, stdout, stderr, exit, platform, arch } from "node:process";
import {
  stat,
  readFile,
  readdir,
  writeFile,
  mkdir,
} from "node:fs/promises";

import { patchSource } from "./patch.mjs";

//
// --------------------------------------------------------------------------
// Paths
// --------------------------------------------------------------------------
//

const scriptDir = dirname(fileURLToPath(import.meta.url));

const bridgeDir = resolvePosix(scriptDir);

const bridgeNodeModules = resolvePosix(
  bridgeDir,
  "node_modules",
);

const distDir = resolvePosix(
  bridgeDir,
  "dist",
);

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

const entryPath = resolvePosix(
  bridgeDir,
  "bridge.js",
);

const outputPath = resolvePosix(
  distDir,
  "ncm.bundle",
);

const esbuildBundlePath = resolvePosix(
  distDir,
  "bundle.js",
);

//
// Native addons linked by bare-link are written here.
//
// hook/build.dart can subsequently consume this directory.
//
const androidAddonsRoot = resolvePosix(
  bridgeDir,
  "..",
  "..",
  "android",
  "addons",
);

//
// createRequire() needs an actual CommonJS file path.
//

const bridgeRequire = createRequire(
  resolvePosix(
    bridgeDir,
    "_anchor.cjs",
  ),
);

//
// --------------------------------------------------------------------------
// Load Bare tooling
// --------------------------------------------------------------------------
//

const pack = bridgeRequire(
  resolvePosix(
    bridgeNodeModules,
    "bare-pack",
  ),
);

const resolveBare = bridgeRequire(
  resolvePosix(
    bridgeNodeModules,
    "bare-module-traverse",
  ),
).resolve;

const bareLink = bridgeRequire(
  resolvePosix(
    bridgeNodeModules,
    "bare-link",
  ),
);

//
// --------------------------------------------------------------------------
// Node -> Bare runtime builtin mappings
// --------------------------------------------------------------------------
//
// Examples:
//
//   fs       -> bare-fs
//   path     -> bare-path
//   crypto   -> bare-crypto
//
// bare-node-runtime is therefore NOT unused. Its imports.json is the
// import map consumed by bare-pack while traversing the original graph.
//

const nodeRuntimeImports = JSON.parse(
  await readFile(
    resolvePosix(
      bridgeNodeModules,
      "bare-node-runtime/imports.json",
    ),
    "utf8",
  ),
);

//
// --------------------------------------------------------------------------
// Validate entry
// --------------------------------------------------------------------------
//

try {
  await stat(entryPath);
} catch {
  stderr.write(
    `[pack] missing entry: ${entryPath}\n`,
  );

  stderr.write(
    `[pack] expected source entry: ${bridgeDir}/bridge.js\n`,
  );

  exit(1);
}

//
// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------
//

function pathFromURL(url) {
  return url.protocol === "file:"
    ? fileURLToPath(url)
    : null;
}

function isInside(filePath, directory) {
  return (
    filePath === directory ||
    filePath.startsWith(directory + "/")
  );
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
// All ORIGINAL source files under bridgeDir must be readable.
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
    source = await readFile(
      filePath,
      "utf8",
    );
  } catch (error) {
    //
    // bare-module-traverse probes multiple candidates.
    //
    // Examples:
    //
    //   ./generated_api
    //   ./generated_api.js
    //
    //   ./util
    //   ./util.js
    //   ./util/index.js
    //
    // ENOENT/EISDIR simply mean this candidate is not a readable module.
    //

    if (
      error?.code === "ENOENT" ||
      error?.code === "EISDIR"
    ) {
      return null;
    }

    stderr.write(
      `[pack] readModule failed: ${filePath}\n`,
    );

    stderr.write(
      `${error?.stack || error}\n`,
    );

    throw error;
  }

  //
  // Non-JavaScript files are returned unchanged.
  //

  if (!isJavaScriptFile(filePath)) {
    return Buffer.from(
      source,
      "utf8",
    );
  }

  //
  // Apply Bare-specific source patches.
  //

  const patched = patchSource(
    filePath,
    source,
    {
      target: "bare",
    },
  );

  return Buffer.from(
    patched,
    "utf8",
  );
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
// node_modules are NOT recursively enumerated here because modules are
// resolved through bare-module-traverse.
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
    entries = await readdir(
      dir,
      {
        withFileTypes: true,
      },
    );
  } catch {
    return;
  }

  for (const entry of entries) {
    const child = resolvePosix(
      dir,
      entry.name,
    );

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
      children = await readdir(
        child,
        {
          withFileTypes: true,
        },
      );
    } catch {
      continue;
    }

    for (const grandchild of children) {
      yield pathToFileURL(
        resolvePosix(
          child,
          grandchild.name,
        ),
      );
    }
  }
}

//
// --------------------------------------------------------------------------
// Hosts
// --------------------------------------------------------------------------
//

const HOSTS = (
  env.HOST ??
  `${platform}-${arch}`
)
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

const androidHosts = HOSTS.filter(
  (host) => host.startsWith("android-"),
);

//
// --------------------------------------------------------------------------
// Build information
// --------------------------------------------------------------------------
//

stderr.write(
  `[pack] entry: ${entryPath}\n`,
);

stderr.write(
  `[pack] hosts: ${HOSTS.join(", ")}\n`,
);

stderr.write(
  `[pack] out:   ${outputPath}\n`,
);

stderr.write(
  `[pack] mode:  source -> patch -> bare-pack -> bare-link\n`,
);

//
// --------------------------------------------------------------------------
// Pack
// --------------------------------------------------------------------------
//
// IMPORTANT:
//
// bare-pack runs FIRST.
//
// It traverses the actual module graph and determines the exact native
// addon URLs that belong to this bundle.
//
// We intentionally do NOT scan all node_modules/bare-* packages before
// packing.
//
// bundle.addons is the source of truth.
//

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

      base: pathToFileURL(
        bridgeDir,
      ),

      //
      // Node -> Bare builtin redirects.
      //

      imports: nodeRuntimeImports,

      //
      // Bare-aware module resolver.
      //

      resolve: resolveBare.bare,

      //
      // music-metadata v11+ is pure ESM and uses the node/module-sync
      // conditions in its exports map.
      //

      conditions: [
        "node",
        "module-sync",
      ],

      //
      // Native addon target.
      //
      // Examples:
      //
      //   HOST=android-arm64
      //   HOST=android-arm64,android-x64
      //   HOST=ios-arm64
      //

      hosts: HOSTS,

      //
      // Mobile runtimes link native addons ahead of time.
      //
      // Therefore addon resolutions must use:
      //
      //   linked:
      //
      // rather than runtime-loadable file: URLs.
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
  stderr.write(
    "\n[pack] bare-pack failed\n",
  );

  stderr.write(
    `${error?.stack || error}\n`,
  );

  exit(1);
}

//
// --------------------------------------------------------------------------
// Pack diagnostics
// --------------------------------------------------------------------------
//

const bundledAddons = Array.isArray(
  bundle?.addons,
)
  ? bundle.addons
  : [];

const bundledAssets = Array.isArray(
  bundle?.assets,
)
  ? bundle.assets
  : [];

stdout.write(
  `\n[pack] bare-pack discovered ${bundledAddons.length} native addon(s)\n`,
);

if (bundledAddons.length > 0) {
  stdout.write(
    "\n[pack] bundle.addons:\n",
  );

  for (const addon of bundledAddons) {
    stdout.write(
      `  ${addon}\n`,
    );
  }
}

if (bundledAssets.length > 0) {
  stdout.write(
    "\n[pack] bundle.assets:\n",
  );

  for (const asset of bundledAssets) {
    stdout.write(
      `  ${asset}\n`,
    );
  }
}

//
// --------------------------------------------------------------------------
// Addon package discovery
// --------------------------------------------------------------------------
//
// bundle.addons contains RESOLVED addon URLs, for example:
//
//   linked:libbare-type.1.1.1.so
//
// bare-link, however, operates on an addon PACKAGE ROOT.
//
// Therefore we build a small index of addon packages:
//
//   linked URL
//        |
//        v
//   package.json
//        |
//        v
//   package root
//
// IMPORTANT:
//
// We do NOT use this index to decide which addons are needed.
//
// bare-pack has already made that decision.
//
// The index is only used to map the addons discovered by bare-pack back
// to their package roots for bare-link.
//

async function readPackageJson(packagePath) {
  try {
    return JSON.parse(
      await readFile(
        resolvePosix(
          packagePath,
          "package.json",
        ),
        "utf8",
      ),
    );
  } catch {
    return null;
  }
}

async function collectAddonPackages() {
  const result = [];

  let entries;

  try {
    entries = await readdir(
      bridgeNodeModules,
      {
        withFileTypes: true,
      },
    );
  } catch (error) {
    stderr.write(
      `[pack] failed to read node_modules: ${error?.stack || error}\n`,
    );

    throw error;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    //
    // Handle:
    //
    //   node_modules/bare-*
    //
    // and:
    //
    //   node_modules/bare/*
    //

    if (entry.name === "bare") {
      const scopedRoot = resolvePosix(
        bridgeNodeModules,
        "bare",
      );

      let scopedEntries;

      try {
        scopedEntries = await readdir(
          scopedRoot,
          {
            withFileTypes: true,
          },
        );
      } catch {
        continue;
      }

      for (const scoped of scopedEntries) {
        if (!scoped.isDirectory()) {
          continue;
        }

        const packagePath = resolvePosix(
          scopedRoot,
          scoped.name,
        );

        const packageJson = await readPackageJson(
          packagePath,
        );

        if (
          packageJson?.addon === true
        ) {
          result.push({
            path: packagePath,
            name: packageJson.name,
            version: packageJson.version,
          });
        }
      }

      continue;
    }

    if (!entry.name.startsWith("bare-")) {
      continue;
    }

    const packagePath = resolvePosix(
      bridgeNodeModules,
      entry.name,
    );

    const packageJson = await readPackageJson(
      packagePath,
    );

    if (
      packageJson?.addon === true
    ) {
      result.push({
        path: packagePath,
        name: packageJson.name,
        version: packageJson.version,
      });
    }
  }

  return result;
}

//
// --------------------------------------------------------------------------
// Match bare-pack addon URL -> addon package
// --------------------------------------------------------------------------
//
// For Android/Linux-style linked addons, bare-pack produces:
//
//   linked:lib<package-name>.<version>.so
//
// Example:
//
//   bare-type@1.1.1
//
// becomes:
//
//   linked:libbare-type.1.1.1.so
//
// We therefore derive the expected linked filename from package metadata
// instead of guessing from arbitrary node_modules directory names.
//

function getLinkedAddonBasename(
  packageJson,
) {
  if (
    !packageJson?.name ||
    !packageJson?.version
  ) {
    return null;
  }

  //
  // bare-pack's Android/Linux linked addon convention:
  //
  //   lib<name>.<version>.so
  //
  //

  return `lib${packageJson.name}.${packageJson.version}.so`;
}

function normalizeAddonHref(href) {
  if (
    typeof href !== "string"
  ) {
    return null;
  }

  //
  // The bundle may contain:
  //
  //   linked:libbare-type.1.1.1.so
  //
  // but for matching we only need the URL path/basename.
  //

  if (
    href.startsWith("linked:")
  ) {
    return href.slice(
      "linked:".length,
    );
  }

  return href;
}

async function resolveAddonPackages(
  addons,
) {
  const packages = await collectAddonPackages();

  const packageByLinkedBasename =
    new Map();

  for (const pkg of packages) {
    const packageJson = await readPackageJson(
      pkg.path,
    );

    const basename =
      getLinkedAddonBasename(
        packageJson,
      );

    if (!basename) {
      continue;
    }

    packageByLinkedBasename.set(
      basename,
      {
        ...pkg,
        packageJson,
      },
    );
  }

  const resolved = [];
  const unresolved = [];

  for (const addon of addons) {
    const normalized =
      normalizeAddonHref(addon);

    //
    // We only need package mapping for actual linked addons.
    //

    if (
      !normalized ||
      !normalized.startsWith("lib") ||
      !normalized.endsWith(".so")
    ) {
      continue;
    }

    const pkg =
      packageByLinkedBasename.get(
        normalized,
      );

    if (!pkg) {
      unresolved.push(addon);
      continue;
    }

    resolved.push({
      addon,
      ...pkg,
    });
  }

  return {
    resolved,
    unresolved,
  };
}

//
// --------------------------------------------------------------------------
// Link addons
// --------------------------------------------------------------------------
//
// This is the SECOND stage.
//
// bare-pack has already told us which native addons are actually required.
//
// bare-link is now responsible only for materializing those packages into:
//
//   android/addons/
//
// This keeps pack.mjs as the unified pack + link entry point while making
// bare-pack the source of truth for addon reachability.
//

async function linkBundleAddons() {
  if (androidHosts.length === 0) {
    stderr.write(
      "\n[pack] no Android hosts requested; skipping bare-link\n",
    );

    return;
  }

  if (bundledAddons.length === 0) {
    stderr.write(
      "\n[pack] bundle contains no native addons; skipping bare-link\n",
    );

    return;
  }

  //
  // Only linked Android/Linux .so addons are handled here.
  //

  const linkedAddons =
    bundledAddons.filter(
      (addon) =>
        typeof addon === "string" &&
        addon.startsWith("linked:") &&
        addon.endsWith(".so"),
    );

  if (linkedAddons.length === 0) {
    stderr.write(
      "\n[pack] bundle has no linked Android .so addons; skipping bare-link\n",
    );

    return;
  }

  //
  // Ensure destination exists.
  //

  await mkdir(
    androidAddonsRoot,
    {
      recursive: true,
    },
  );

  stderr.write(
    `\n[pack] bare-link -> ${androidAddonsRoot}\n`,
  );

  stderr.write(
    `[pack] Android hosts: ${androidHosts.join(", ")}\n`,
  );

  stderr.write(
    `[pack] linking ${linkedAddons.length} bundle addon(s)\n`,
  );

  //
  // Map bundle.addons back to addon packages.
  //

  const {
    resolved,
    unresolved,
  } = await resolveAddonPackages(
    linkedAddons,
  );

  //
  // Report anything bare-pack requested that we cannot map.
  //

  if (unresolved.length > 0) {
    stderr.write(
      "\n[pack] WARNING: unable to map these bundle addons to local addon packages:\n",
    );

    for (const addon of unresolved) {
      stderr.write(
        `  ${addon}\n`,
      );
    }

    //
    // Do NOT silently link every bare-* package as a fallback.
    //
    // If bare-pack says an addon is required but our package index cannot
    // resolve it, failing here is safer than producing a bundle that
    // appears complete but crashes later with ADDON_NOT_FOUND.
    //

    throw new Error(
      `Unable to resolve ${unresolved.length} bundled native addon(s) to local addon packages`,
    );
  }

  //
  // Deduplicate packages.
  //

  const uniquePackages =
    new Map();

  for (const pkg of resolved) {
    const key = `${pkg.name}@${pkg.version}`;

    if (!uniquePackages.has(key)) {
      uniquePackages.set(
        key,
        pkg,
      );
    }
  }

  let linkedResourceCount = 0;

  for (const pkg of uniquePackages.values()) {
    stderr.write(
      `[pack] link ${pkg.name}@${pkg.version}\n`,
    );

    for await (
      const resource of bareLink(
        pkg.path,
        {
          hosts: androidHosts,
          out: androidAddonsRoot,

          //
          // bare-kit itself is supplied separately by the Flutter build
          // hook, so native addon linking only needs to resolve resources
          // against libbare-kit.so.
          //

          needs: [
            "libbare-kit.so",
          ],
        },
      )
    ) {
      linkedResourceCount++;

      //
      // Keep the resource object available for diagnostics without
      // depending on its exact shape.
      //

      if (env.DEBUG_BARE_LINK === "1") {
        stdout.write(
          `[pack] linked resource: ${String(resource)}\n`,
        );
      }
    }
  }

  stdout.write(
    `\n[pack] bare-link linked ${uniquePackages.size} addon package(s), ${linkedResourceCount} resource(s)\n`,
  );

  //
  // libbare-kit.so is intentionally NOT copied here.
  //
  // hook/build.dart owns libbare-kit.so because it already has access to
  // the bare-kit prebuild archive and knows which Flutter code assets /
  // Android ABIs the application is actually building.
  //
}

//
// --------------------------------------------------------------------------
// Link stage
// --------------------------------------------------------------------------
//

try {
  await linkBundleAddons();
} catch (error) {
  stderr.write(
    "\n[pack] bare-link failed\n",
  );

  stderr.write(
    `${error?.stack || error}\n`,
  );

  exit(1);
}

//
// --------------------------------------------------------------------------
// Write bundle
// --------------------------------------------------------------------------
//
//
// IMPORTANT:
//
// bare-pack has already finalized:
//
//   bundle.resolutions
//   bundle.addons
//   bundle.assets
//
// bare-link does NOT modify the bundle itself.
//
// It materializes the native libraries that those `linked:` resolutions
// expect to find in the host application.
//

const data = bundle.toBuffer();

await writeFile(
  outputPath,
  data,
);

stdout.write(
  `\n[pack] wrote ${outputPath} (${data.byteLength} bytes)\n`,
);

//
// --------------------------------------------------------------------------
// Final diagnostics
// --------------------------------------------------------------------------
//

stdout.write(
  `\n[pack] summary:\n`,
);

stdout.write(
  `  entry:  ${entryPath}\n`,
);

stdout.write(
  `  output: ${outputPath}\n`,
);

stdout.write(
  `  hosts:  ${HOSTS.join(", ")}\n`,
);

stdout.write(
  `  addons: ${bundledAddons.length}\n`,
);

stdout.write(
  `  assets: ${bundledAssets.length}\n`,
);

if (bundledAddons.length > 0) {
  stdout.write(
    "\n[pack] embedded native addons:\n",
  );

  for (const addon of bundledAddons) {
    stdout.write(
      `  ${addon}\n`,
    );
  }
}

if (bundledAssets.length > 0) {
  stdout.write(
    "\n[pack] bundled assets:\n",
  );

  for (const asset of bundledAssets) {
    stdout.write(
      `  ${asset}\n`,
    );
  }
}