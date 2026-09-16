// assets/bridge/pack.mjs
//
// Build the NCM JS bridge directly from the original Bare module graph.
//
// Build pipeline:
//
//   bridge.js
//      |
//      +--> patchSource()
//      |
//      +--> bare-pack
//      |       |
//      |       +--> dist/ncm.bundle
//      |              |
//      |              +--> bundle.addons
//      |
//      +--> bare-link(bridge project root)
//              |
//              +--> android/addons/
//
// IMPORTANT:
//
// bare-pack and bare-link have DIFFERENT jobs.
//
// bare-pack:
//   - traverses the JavaScript module graph
//   - determines which native addons are referenced by the bundle
//   - writes bundle.addons / bundle.resolutions
//
// bare-link:
//   - traverses the package dependency tree
//   - looks at package.json
//   - links packages where:
//
//       pkg.addon === true
//
//   - produces the ABI-specific native libraries
//
// DO NOT feed dist/bundle.js into bare-pack.
//
// bare-pack must see the original module boundaries of Bare native
// packages such as:
//
//   node_modules/bare-path/binding.js
//   node_modules/bare-fs/binding.js
//   node_modules/bare-crypto/binding.js
//
// so that require.addon() remains associated with the correct package.
//
// NOTE:
//
// The native addons are NOT extracted from ncm.bundle.
//
// ncm.bundle only contains the linked addon resolutions:
//
//   linked:libbare-type.1.1.1.so
//
// bare-link obtains the actual addon package from the package dependency
// tree and materializes the corresponding native library.
//

import { fileURLToPath, pathToFileURL } from "node:url";

import {
  dirname,
  resolve as resolvePosix,
} from "node:path";

import { createRequire } from "node:module";

import {
  env,
  stdout,
  stderr,
  exit,
  platform,
  arch,
} from "node:process";

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

//
// This is the package/project root passed to bare-link.
//
// Example:
//
//   assets/bridge/
//
// bare-link will read:
//
//   assets/bridge/package.json
//
// and recursively follow its dependency tree.
//

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
// bare-pack starts from the ORIGINAL source entry.
//
// DO NOT use:
//
//   dist/bundle.js
//
// because that file has already been flattened by esbuild.
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
// Flutter's Android build hook subsequently packages this directory.
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

const bareModuleTraverse = bridgeRequire(
  resolvePosix(
    bridgeNodeModules,
    "bare-module-traverse",
  ),
);

const resolveBare = bareModuleTraverse.resolve;

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
// bare-node-runtime provides the mapping:
//
//   node:fs
//      -> bare-fs
//
//   node:path
//      -> bare-path
//
//   node:crypto
//      -> bare-crypto
//
// etc.
//

const nodeRuntimeImports = JSON.parse(
  await readFile(
    resolvePosix(
      bridgeNodeModules,
      "bare-node-runtime",
      "imports.json",
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
// bare-pack traverses the ORIGINAL JavaScript module graph.
//
// This deliberately remains separate from the esbuild pipeline.
//
//
//
//   bridge.js
//       |
//       +-- generated_api.js
//       |
//       +-- node_modules/...
//       |
//       +-- bare-*/binding.js
//
// Native Bare module boundaries must remain visible.
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
    // ENOENT/EISDIR means this candidate simply is not a readable module.
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
// bare-pack may request file: URLs for runtime assets.
//
// Only dist/ is exposed here.
//

async function* listPrefix(url) {
  const dir = pathFromURL(url);

  if (!dir) {
    return;
  }

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
  `[pack] mode:  source -> bare-pack + bare-link(project root)\n`,
);

//
// --------------------------------------------------------------------------
// Pack
// --------------------------------------------------------------------------
//
// FIRST STAGE:
//
//   bridge.js
//      |
//      v
//   bare-pack
//      |
//      +--> bundle.addons
//      +--> bundle.resolutions
//
// We deliberately do NOT inspect node_modules here.
//
// bare-pack itself determines which addons are referenced by the
// JavaScript module graph.
//

let bundle;

try {
  bundle = await pack(
    pathToFileURL(entryPath),
    {
      //
      // Common source ancestor.
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
      // music-metadata v11+ uses node/module-sync conditions.
      //

      conditions: [
        "node",
        "module-sync",
      ],

      //
      // Native addon target.
      //

      hosts: HOSTS,

      //
      // Mobile runtimes use linked native addons.
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
// Link addons
// --------------------------------------------------------------------------
//
// SECOND STAGE:
//
//   bridgeDir
//      |
//      v
//   bare-link
//      |
//      +--> package.json
//      |
//      +--> dependency tree
//             |
//             +--> pkg.addon === true
//                    |
//                    v
//                  platform linker
//                    |
//                    v
//                  android/addons/
//
// IMPORTANT:
//
// We do NOT:
//
//   - scan node_modules ourselves
//   - inspect npm's logical dependency tree
//   - map bundle.addons back to package names
//   - pin a particular bare-module version
//
// bare-link already owns the package-tree traversal.
//
// The bundle and native addon tree are intentionally produced by their
// respective tools.
//

async function linkAddons() {
  if (androidHosts.length === 0) {
    stderr.write(
      "\n[pack] no Android hosts requested; skipping bare-link\n",
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
    `\n[pack] bare-link project root -> ${androidAddonsRoot}\n`,
  );

  stderr.write(
    `[pack] Android hosts: ${androidHosts.join(", ")}\n`,
  );

  //
  // bundle.addons is diagnostic information here.
  //
  // It is NOT fed into bare-link.
  //
  // bare-link works from the package dependency tree.
  //

  stderr.write(
    `[pack] bundle requires ${bundledAddons.length} native addon(s)\n`,
  );

  //
  // Start bare-link from the actual package root.
  //
  // This is the important part.
  //
  // bare-link will:
  //
  //   read bridge/package.json
  //   follow dependencies
  //   recursively follow dependency package.json files
  //   detect pkg.addon === true
  //   invoke the Android platform linker
  //

  let resourceCount = 0;

  for await (
    const resource of bareLink(
      bridgeDir,
      {
        hosts: androidHosts,
        out: androidAddonsRoot,
      },
    )
  ) {
    resourceCount++;

    if (env.DEBUG_BARE_LINK === "1") {
      stdout.write(
        `[pack] linked resource: ${String(resource)}\n`,
      );
    }
  }

  stdout.write(
    `\n[pack] bare-link linked ${resourceCount} resource(s)\n`,
  );

  //
  // libbare-kit.so is intentionally NOT copied here.
  //
  // BareKit is supplied separately by the Flutter Android build hook.
  //
}

//
// --------------------------------------------------------------------------
// Link stage
// --------------------------------------------------------------------------
//

try {
  await linkAddons();
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
// bare-pack has already finalized:
//
//   bundle.resolutions
//   bundle.addons
//   bundle.assets
//
// bare-link does NOT modify the bundle.
//
// It only materializes the native addon libraries corresponding to the
// package dependency tree.
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
  "\n[pack] summary:\n",
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
    "\n[pack] native addons required by bundle:\n",
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
