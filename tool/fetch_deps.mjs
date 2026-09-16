#!/usr/bin/env node
// tool/fetch_deps.mjs
//
// Install / refresh the npm dependencies for assets/bridge/.
//
// assets/bridge/ is a self-contained Node project. Its dependencies
// (@neteasecloudmusicapienhanced/api, @noble/curves, @noble/ciphers,
// esbuild, bare-pack, bare-link, …) live in
// assets/bridge/node_modules/ and are not declared by the host Flutter
// app's pubspec.yaml.
//
// Why a wrapper instead of "just run npm install"
// -----------------------------------------------
//
// - The script chdirs to assets/bridge/ based on its own location, so
//   it works regardless of where it is invoked from (package root,
//   IDE run config, CI, …).
//
// - It is idempotent. `npm install` honours package-lock.json on each
//   run, so re-running after a clean checkout or after editing
//   package.json always converges to the locked tree.
//
// - It fails loudly if npm is missing or the lockfile is out of sync.
//
// Usage:
//   node tool/fetch_deps.mjs
//
// Optional:
//   node tool/fetch_deps.mjs --no-audit       # pass through to npm
//   node tool/fetch_deps.mjs --frozen-lockfile  # fail on lockfile drift

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// tool/fetch_deps.mjs -> ../../assets/bridge
const bridgeDir = resolve(__dirname, "..", "assets", "bridge");

// Pass any extra args through to npm (--no-audit, --frozen-lockfile, …).
const passthrough = process.argv.slice(2);

const npmCmd = process.platform === "win32" ? "npm.cmd" : "npm";

const result = spawnSync(npmCmd, ["install", ...passthrough], {
  cwd: bridgeDir,
  stdio: "inherit",
  env: process.env,
});

if (result.error) {
  // Spawning the binary itself failed (npm not on PATH, EACCES, …).
  console.error(`[fetch_deps] failed to spawn npm: ${result.error.message}`);
  process.exit(1);
}

if (result.status !== 0) {
  console.error(
    `[fetch_deps] npm install failed in ${bridgeDir} (exit ${result.status})`,
  );
  process.exit(result.status ?? 1);
}

console.log(`[fetch_deps] ok (cwd=${bridgeDir})`);