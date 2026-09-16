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
//       -> actual node_modules package tree
//       -> bare-link
//       -> android/addons/
//
// DO NOT feed dist/bundle.js into bare-pack.
//
// bare-pack needs to see the original module boundaries of Bare native
// packages such as:
//
//   node_modules/bare-path/binding.js
//   node_modules/bare-fs/binding.js
//   node_modules/bare-crypto/binding.js
//
// so that require.addon() remains associated with the correct binding.js
// module and bare-pack can produce the correct linked: resolution.
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
//   ACTUAL node_modules TREE
//        |
//        +---- package.json { addon: true }
//        |
//        v
//   addon package path
//        |
//        v
//   bare-link
//        |
//        v
//   android/addons/
//
// Output:
//
//   assets/bridge/dist/ncm.bundle
//

import { fileURLToPath, pathToFileURL } from "node:url";
import {
  dirname,
  resolve as resolvePosix,
  relative,
  basename,
} from "node:path";
import { createRequire } from "node:module";
import { env, stdout, stderr, exit, platform, arch } from "node:process";
import {
  stat,
  realpath,
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
// because esbuild has already flattened the module graph and native Bare
// module boundaries such as bare-path/binding.js would no longer be visible
// as the original module graph.
//

const entryPath = resolvePosix(bridgeDir, "bridge.js");

const outputPath = resolvePosix(distDir, "ncm.bundle");

const esbuildBundlePath = resolvePosix(distDir, "bundle.js");

//
// Native addons linked by bare-link are written here.
//
// Flutter's Android build hook subsequently consumes this directory.
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

const bridgeRequire = createRequire(resolvePosix(bridgeDir, "_anchor.cjs"));

//
// --------------------------------------------------------------------------
// Load Bare tooling
// --------------------------------------------------------------------------
//

const pack = bridgeRequire(resolvePosix(bridgeNodeModules, "bare-pack"));

const bareModuleTraverse = bridgeRequire(
  resolvePosix(bridgeNodeModules, "bare-module-traverse"),
);

const resolveBare = bareModuleTraverse.resolve;

const bareLink = bridgeRequire(resolvePosix(bridgeNodeModules, "bare-link"));

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
// bare-node-runtime is therefore part of the ORIGINAL dependency graph.
// Its imports.json is supplied to bare-pack so Node builtin imports are
// redirected to the corresponding Bare modules.
//

const nodeRuntimeImports = JSON.parse(
  await readFile(
    resolvePosix(bridgeNodeModules, "bare-node-runtime", "imports.json"),
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
    //   ./util
    //   ./util.js
    //   ./util/index.js
    //
    // ENOENT/EISDIR simply mean this candidate is not a readable module.
    //

    if (error?.code === "ENOENT" || error?.code === "EISDIR") {
      return null;
    }

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
  // Apply Bare-specific source patches.
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

const androidHosts = HOSTS.filter((host) => host.startsWith("android-"));

//
// --------------------------------------------------------------------------
// Build information
// --------------------------------------------------------------------------
//

stderr.write(`[pack] entry: ${entryPath}\n`);

stderr.write(`[pack] hosts: ${HOSTS.join(", ")}\n`);

stderr.write(`[pack] out:   ${outputPath}\n`);

stderr.write(
  `[pack] mode:  source -> patch -> bare-pack -> addon-tree -> bare-link\n`,
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
// bundle.addons is the source of truth.
//
// We intentionally do NOT scan node_modules before packing.
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
      // music-metadata v11+ is pure ESM and uses the node/module-sync
      // conditions in its exports map.
      //

      conditions: ["node", "module-sync"],

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
      // Therefore addon resolutions use:
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
  stderr.write("\n[pack] bare-pack failed\n");
  stderr.write(`${error?.stack || error}\n`);

  exit(1);
}

//
// --------------------------------------------------------------------------
// Pack diagnostics
// --------------------------------------------------------------------------
//

const bundledAddons = Array.isArray(bundle?.addons) ? bundle.addons : [];

const bundledAssets = Array.isArray(bundle?.assets) ? bundle.assets : [];

stdout.write(
  `\n[pack] bare-pack discovered ${bundledAddons.length} native addon(s)\n`,
);

if (bundledAddons.length > 0) {
  stdout.write("\n[pack] bundle.addons:\n");

  for (const addon of bundledAddons) {
    stdout.write(`  ${addon}\n`);
  }
}

if (bundledAssets.length > 0) {
  stdout.write("\n[pack] bundle.assets:\n");

  for (const asset of bundledAssets) {
    stdout.write(`  ${asset}\n`);
  }
}

//
// --------------------------------------------------------------------------
// Actual node_modules addon discovery
// --------------------------------------------------------------------------
//
// DO NOT use:
//
//   npm ls --all --json
//
// here.
//
// `npm ls` describes npm's logical dependency tree, but the thing
// bare-link needs is the ACTUAL physical addon package directory.
//
// In this project there can be:
//
//   node_modules/bare-module
//
// and:
//
//   node_modules/bare-node-runtime/node_modules/bare-module
//
// with different versions.
//
// The filesystem therefore remains the authoritative source for package
// roots.
//
// We recursively inspect every actual `node_modules` directory under the
// bridge tree.
//
// We do NOT link everything we discover.
//
// Discovery only builds:
//
//   name + version -> package path
//
// bundle.addons remains the authority for what actually gets linked.
//

//
// --------------------------------------------------------------------------
// Package JSON cache
// --------------------------------------------------------------------------
//

const packageJsonCache = new Map();

async function loadPackageJson(packagePath) {
  const normalizedPath = resolvePosix(packagePath);

  const cached = packageJsonCache.get(normalizedPath);

  if (cached !== undefined) {
    return cached;
  }

  let packageJson;

  try {
    packageJson = JSON.parse(
      await readFile(resolvePosix(normalizedPath, "package.json"), "utf8"),
    );
  } catch {
    packageJson = null;
  }

  packageJsonCache.set(normalizedPath, packageJson);

  return packageJson;
}

//
// --------------------------------------------------------------------------
// Realpath helper
// --------------------------------------------------------------------------
//
// pnpm and other package managers may represent dependencies using
// symlinks.
//
// We retain BOTH:
//
//   logical path
//
// and:
//
//   physical real path
//
// because a linked package can be reached through several node_modules
// locations.
//

const realpathCache = new Map();

async function getRealPath(filePath) {
  const normalizedPath = resolvePosix(filePath);

  const cached = realpathCache.get(normalizedPath);

  if (cached !== undefined) {
    return cached;
  }

  let result;

  try {
    result = await realpath(normalizedPath);
  } catch {
    result = normalizedPath;
  }

  realpathCache.set(normalizedPath, result);

  return result;
}

//
// --------------------------------------------------------------------------
// Find package root
// --------------------------------------------------------------------------
//
// A node_modules child can itself be:
//
//   node_modules/foo
//
// or:
//
//   node_modules/@scope/foo
//
// We inspect package.json directly instead of relying on directory name
// parsing.
//

async function inspectPackageDirectory(packagePath) {
  const packageJson = await loadPackageJson(packagePath);

  if (!packageJson) {
    return null;
  }

  if (packageJson.addon !== true) {
    return null;
  }

  if (
    typeof packageJson.name !== "string" ||
    typeof packageJson.version !== "string"
  ) {
    return null;
  }

  return {
    path: resolvePosix(packagePath),
    realPath: await getRealPath(packagePath),
    name: packageJson.name,
    version: packageJson.version,
    packageJson,
  };
}

//
// --------------------------------------------------------------------------
// Recursive node_modules traversal
// --------------------------------------------------------------------------
//
// This deliberately traverses:
//
//   node_modules/*
//
// and:
//
//   node_modules/*/node_modules/*
//
// and so on.
//
// This is the important difference from the old implementation, which
// only looked at:
//
//   bridge/node_modules/*
//
// and therefore missed:
//
//   bridge/node_modules/bare-node-runtime/node_modules/bare-module
//
// The traversal is filesystem based because the physical package roots are
// exactly what bare-link's API expects.
//

async function collectAddonPackages() {
  stderr.write(
    "\n[pack] resolving addon packages from actual node_modules tree...\n",
  );

  const result = [];

  //
  // Logical package paths already visited.
  //

  const visitedPaths = new Set();

  //
  // Real package locations already visited.
  //
  // This prevents following the same pnpm symlink target repeatedly.
  //

  const visitedRealPaths = new Set();

  //
  // Prevent traversing arbitrary non-node_modules directories.
  //

  const visitedNodeModules = new Set();

  async function visitNodeModules(nodeModulesPath) {
    const normalizedNodeModules = resolvePosix(nodeModulesPath);

    if (visitedNodeModules.has(normalizedNodeModules)) {
      return;
    }

    visitedNodeModules.add(normalizedNodeModules);

    let entries;

    try {
      entries = await readdir(normalizedNodeModules, {
        withFileTypes: true,
      });
    } catch {
      return;
    }

    for (const entry of entries) {
      //
      // Ignore files.
      //

      if (!entry.isDirectory() && !entry.isSymbolicLink()) {
        continue;
      }

      //
      // Ignore npm metadata directories.
      //

      if (entry.name === ".bin" || entry.name === ".package-lock.json") {
        continue;
      }

      //
      // Resolve scoped package layout:
      //
      //   node_modules/@scope/package
      //

      let packagePath;

      if (entry.name.startsWith("@")) {
        let scopeEntries;

        try {
          scopeEntries = await readdir(
            resolvePosix(normalizedNodeModules, entry.name),
            {
              withFileTypes: true,
            },
          );
        } catch {
          continue;
        }

        for (const scopeEntry of scopeEntries) {
          if (!scopeEntry.isDirectory() && !scopeEntry.isSymbolicLink()) {
            continue;
          }

          packagePath = resolvePosix(
            normalizedNodeModules,
            entry.name,
            scopeEntry.name,
          );

          await inspectAndQueuePackage(packagePath);
        }

        continue;
      }

      //
      // Normal package:
      //
      //   node_modules/package
      //

      packagePath = resolvePosix(normalizedNodeModules, entry.name);

      await inspectAndQueuePackage(packagePath);
    }
  }

  async function inspectAndQueuePackage(packagePath) {
    const normalizedPackagePath = resolvePosix(packagePath);

    if (visitedPaths.has(normalizedPackagePath)) {
      return;
    }

    visitedPaths.add(normalizedPackagePath);

    //
    // Check whether this directory itself is an addon.
    //

    const addon = await inspectPackageDirectory(normalizedPackagePath);

    if (addon) {
      //
      // If this is a symlink, avoid collecting the same physical package
      // more than once.
      //

      if (!visitedRealPaths.has(addon.realPath)) {
        visitedRealPaths.add(addon.realPath);

        result.push(addon);
      }
    }

    //
    // IMPORTANT:
    //
    // Even if the package is NOT an addon, its own nested node_modules
    // can contain addons.
    //
    // Example:
    //
    //   bare-node-runtime/
    //     node_modules/
    //       bare-module/
    //
    const nestedNodeModules = resolvePosix(
      normalizedPackagePath,
      "node_modules",
    );

    await visitNodeModules(nestedNodeModules);
  }

  //
  // Start at the project's root node_modules.
  //

  await visitNodeModules(bridgeNodeModules);

  //
  // Deterministic order.
  //

  result.sort(
    (a, b) =>
      a.name.localeCompare(b.name) ||
      a.version.localeCompare(b.version) ||
      a.realPath.localeCompare(b.realPath),
  );

  stdout.write(
    `[pack] actual node_modules tree contains ${result.length} addon package node(s)\n`,
  );

  if (result.length > 0) {
    stdout.write("\n[pack] discovered addon packages:\n");

    for (const pkg of result) {
      stdout.write(`  ${pkg.name}@${pkg.version}\n`);

      stdout.write(`    path:     ${pkg.path}\n`);

      if (pkg.realPath !== pkg.path) {
        stdout.write(`    realPath: ${pkg.realPath}\n`);
      }
    }
  }

  return result;
}

//
// --------------------------------------------------------------------------
// Match bundle addon -> package
// --------------------------------------------------------------------------
//
// For Android/Linux linked addons:
//
//   bare-type@1.1.1
//
// becomes:
//
//   linked:libbare-type.1.1.1.so
//
// We therefore derive the exact artifact name from package metadata.
//

function getLinkedAddonBasename(packageJson) {
  if (
    !packageJson ||
    typeof packageJson.name !== "string" ||
    typeof packageJson.version !== "string"
  ) {
    return null;
  }

  return `lib${packageJson.name}.${packageJson.version}.so`;
}

function normalizeAddonHref(href) {
  if (typeof href !== "string") {
    return null;
  }

  if (href.startsWith("linked:")) {
    return href.slice("linked:".length);
  }

  return href;
}

//
// --------------------------------------------------------------------------
// Resolve bundle.addons against actual package tree
// --------------------------------------------------------------------------
//
// bundle.addons is the source of truth.
//
// The actual node_modules tree is ONLY used to find the package root.
//
// A package being present in node_modules does NOT mean it will be linked.
//

async function resolveAddonPackages(addons) {
  const packages = await collectAddonPackages();

  //
  // basename -> physical package nodes
  //

  const packageByLinkedBasename = new Map();

  for (const pkg of packages) {
    const basename = getLinkedAddonBasename(pkg.packageJson);

    if (!basename) {
      continue;
    }

    const existing = packageByLinkedBasename.get(basename);

    if (existing) {
      existing.push(pkg);
    } else {
      packageByLinkedBasename.set(basename, [pkg]);
    }
  }

  const resolved = [];
  const unresolved = [];

  for (const addon of addons) {
    const normalized = normalizeAddonHref(addon);

    //
    // This stage only handles linked Android/Linux .so artifacts.
    //

    if (
      !normalized ||
      !normalized.startsWith("lib") ||
      !normalized.endsWith(".so")
    ) {
      continue;
    }

    const matches = packageByLinkedBasename.get(normalized);

    if (!matches || matches.length === 0) {
      unresolved.push(addon);
      continue;
    }

    //
    // Normally there should be exactly one physical package matching a
    // name/version artifact.
    //
    // If several logical package locations resolve to the same physical
    // package, the realpath dedup above already collapsed them.
    //
    // If genuinely different physical packages have identical
    // name/version, the generated artifact is nevertheless identical.
    // Pick the deterministic first path.
    //

    if (matches.length > 1) {
      stderr.write(
        `\n[pack] WARNING: multiple addon packages match ${addon}:\n`,
      );

      for (const match of matches) {
        stderr.write(`  ${match.path}\n`);

        if (match.realPath !== match.path) {
          stderr.write(`    -> ${match.realPath}\n`);
        }
      }

      stderr.write(`[pack] using: ${matches[0].path}\n`);
    }

    resolved.push({
      addon,
      ...matches[0],
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
// bare-pack has already determined which addons are required.
//
// We now map:
//
//   linked:libbare-type.1.1.1.so
//
// back to:
//
//   node_modules/.../bare-type
//
// and call:
//
//   bareLink(packagePath, {
//     hosts,
//     out
//   })
//
// IMPORTANT:
//
// `needs` is NOT passed.
//
// It is not part of bare-link's public API.
//

async function linkBundleAddons() {
  if (androidHosts.length === 0) {
    stderr.write("\n[pack] no Android hosts requested; skipping bare-link\n");

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

  const linkedAddons = bundledAddons.filter(
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

  await mkdir(androidAddonsRoot, {
    recursive: true,
  });

  stderr.write(`\n[pack] bare-link -> ${androidAddonsRoot}\n`);

  stderr.write(`[pack] Android hosts: ${androidHosts.join(", ")}\n`);

  stderr.write(`[pack] linking ${linkedAddons.length} bundle addon(s)\n`);

  //
  // Map bundle.addons back to actual addon packages.
  //

  const { resolved, unresolved } = await resolveAddonPackages(linkedAddons);

  //
  // Report anything bare-pack requested that cannot be mapped.
  //

  if (unresolved.length > 0) {
    stderr.write(
      "\n[pack] ERROR: unable to map these bundle addons to actual addon packages:\n",
    );

    for (const addon of unresolved) {
      stderr.write(`  ${addon}\n`);
    }

    throw new Error(
      [
        `Unable to resolve ${unresolved.length} bundled native addon(s)`,
        "to addon packages in the actual node_modules tree.",
      ].join(" "),
    );
  }

  //
  // Deduplicate by REAL physical package path.
  //
  // This matters when two node_modules locations point at the same package.
  //

  const uniquePackages = new Map();

  for (const pkg of resolved) {
    if (!uniquePackages.has(pkg.realPath)) {
      uniquePackages.set(pkg.realPath, pkg);
    }
  }

  //
  // Print exact mapping.
  //

  stdout.write("\n[pack] bundle addon -> addon package mapping:\n");

  for (const pkg of resolved) {
    stdout.write(`  ${pkg.addon}\n`);

    stdout.write(`    ${pkg.name}@${pkg.version}\n`);

    stdout.write(`    ${pkg.path}\n`);

    if (pkg.realPath !== pkg.path) {
      stdout.write(`    -> ${pkg.realPath}\n`);
    }
  }

  //
  // Link each required addon package.
  //

  let linkedResourceCount = 0;

  for (const pkg of uniquePackages.values()) {
    stderr.write(`\n[pack] link ${pkg.name}@${pkg.version}\n`);

    stderr.write(`[pack]   package: ${pkg.path}\n`);

    //
    // IMPORTANT:
    //
    // This follows the public bare-link API:
    //
    //   link(base, {
    //     hosts,
    //     out
    //   })
    //
    // No `needs` option.
    //

    for await (const resource of bareLink(pkg.path, {
      hosts: androidHosts,
      out: androidAddonsRoot,
    })) {
      linkedResourceCount++;

      if (env.DEBUG_BARE_LINK === "1") {
        stdout.write(`[pack] linked resource: ${String(resource)}\n`);
      }
    }
  }

  stdout.write(
    `\n[pack] bare-link linked ${uniquePackages.size} addon package(s), ${linkedResourceCount} resource(s)\n`,
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
  await linkBundleAddons();
} catch (error) {
  stderr.write("\n[pack] bare-link failed\n");

  stderr.write(`${error?.stack || error}\n`);

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
// bare-link does NOT modify the bundle itself.
//
// It materializes the native libraries corresponding to the linked:
// resolutions in the bundle.
//

const data = bundle.toBuffer();

await writeFile(outputPath, data);

stdout.write(`\n[pack] wrote ${outputPath} (${data.byteLength} bytes)\n`);

//
// --------------------------------------------------------------------------
// Final diagnostics
// --------------------------------------------------------------------------
//

stdout.write(`\n[pack] summary:\n`);

stdout.write(`  entry:  ${entryPath}\n`);

stdout.write(`  output: ${outputPath}\n`);

stdout.write(`  hosts:  ${HOSTS.join(", ")}\n`);

stdout.write(`  addons: ${bundledAddons.length}\n`);

stdout.write(`  assets: ${bundledAssets.length}\n`);

if (bundledAddons.length > 0) {
  stdout.write("\n[pack] linked native addons required by bundle:\n");

  for (const addon of bundledAddons) {
    stdout.write(`  ${addon}\n`);
  }
}

if (bundledAssets.length > 0) {
  stdout.write("\n[pack] bundled assets:\n");

  for (const asset of bundledAssets) {
    stdout.write(`  ${asset}\n`);
  }
}
