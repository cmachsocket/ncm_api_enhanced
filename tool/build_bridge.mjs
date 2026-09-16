#!/usr/bin/env node
// tool/build_bridge.mjs
//
// Run one (or all) of the three assets/bridge build scripts:
//
//   pack           HOST=android-arm64 node pack.mjs
//                  → dist/ncm.bundle  +  android/addons/<abi>/*.so
//   addons         HOST=android-arm64 node package-addons.mjs
//                  → android/addons-jars/<abi>.jar
//                  (must run AFTER `pack`, because it zips up the
//                  android/addons/<abi>/*.so that pack produces)
//   build          node build.mjs
//                  → dist/bundle.js   (desktop / esbuild pipeline;
//                  no HOST required)
//   all            `pack` then `addons`.  Does NOT run `build`, because
//                  the desktop bundle is independent of the mobile
//                  bundle and is only needed when shipping to desktop.
//
// Why a wrapper instead of "just cd assets/bridge && node pack.mjs"
// -----------------------------------------------------------------
//
// - The script resolves assets/bridge/ from its own location
//   (tool/build_bridge.mjs -> ../../assets/bridge), so it works from
//   any cwd. Calling it from the package root, from an IDE run config,
//   from a CI script, or from flutter_netease_music/ all behave the
//   same.
//
// - It defaults HOST=android-arm64 and lets you override via either an
//   environment variable (HOST=ios-arm64) or a CLI flag (--host=...).
//   The pack.mjs / package-addons.mjs scripts read HOST themselves;
//   we just forward it.
//
// - It composes `pack` + `addons` in the right order in `all`, since
//   `addons` zips the .so files that `pack` writes.
//
// Usage:
//   node tool/build_bridge.mjs pack
//   node tool/build_bridge.mjs addons
//   node tool/build_bridge.mjs build
//   node tool/build_bridge.mjs all
//   node tool/build_bridge.mjs pack --host=ios-arm64
//   HOST=ios-arm64 node tool/build_bridge.mjs pack

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// tool/build_bridge.mjs -> ../../assets/bridge
const bridgeDir = resolve(__dirname, "..", "assets", "bridge");

const DEFAULT_HOST = "android-arm64";

const nodeCmd = process.platform === "win32" ? "node.exe" : "node";

const SUBCOMMANDS = ["pack", "addons", "build", "all"];

function parseArgs(argv) {
  const subcommand = argv[0];

  if (!SUBCOMMANDS.includes(subcommand)) {
    return { subcommand: null, hostOverride: null, unknown: argv };
  }

  let hostOverride = null;

  for (const arg of argv.slice(1)) {
    const m = /^--host=(.+)$/.exec(arg);
    if (m) hostOverride = m[1];
  }

  return { subcommand, hostOverride, unknown: [] };
}

function runNodeScript(script, { host } = {}) {
  const env = { ...process.env };

  if (host) env.HOST = host;

  const result = spawnSync(nodeCmd, [script], {
    cwd: bridgeDir,
    stdio: "inherit",
    env,
  });

  if (result.error) {
    console.error(
      `[build_bridge] failed to spawn node for ${script}: ${result.error.message}`,
    );
    process.exit(1);
  }

  if (result.status !== 0) {
    console.error(
      `[build_bridge] ${script} failed in ${bridgeDir} (exit ${result.status})`,
    );
    process.exit(result.status ?? 1);
  }
}

const { subcommand, hostOverride, unknown } = parseArgs(process.argv.slice(2));

if (!subcommand) {
  console.error(
    `[build_bridge] usage: node tool/build_bridge.mjs <${SUBCOMMANDS.join("|")}> [--host=<host>]`,
  );

  if (unknown.length) {
    console.error(`[build_bridge] unknown arg(s): ${unknown.join(" ")}`);
  }

  process.exit(2);
}

const host = hostOverride ?? process.env.HOST ?? DEFAULT_HOST;

switch (subcommand) {
  case "pack":
    runNodeScript("pack.mjs", { host });
    break;

  case "addons":
    runNodeScript("package-addons.mjs", { host });
    break;

  case "build":
    // build.mjs is the desktop / esbuild pipeline and does not consume
    // HOST — it produces dist/bundle.js for the system-node bridge.
    runNodeScript("build.mjs");
    break;

  case "all":
    // pack writes android/addons/<abi>/*.so; addons zips them into
    // android/addons-jars/<abi>.jar.  addons depends on pack, so the
    // order is fixed.
    runNodeScript("pack.mjs", { host });
    runNodeScript("package-addons.mjs", { host });
    break;
}

console.log(`[build_bridge] ${subcommand} ok (host=${subcommand === "build" ? "n/a" : host})`);