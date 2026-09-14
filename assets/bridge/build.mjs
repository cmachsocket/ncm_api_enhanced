// assets/bridge/build.mjs
//
// Build the NCM JS bridge bundle for Android/iOS via esbuild.
//
// IMPORTANT:
//
//   build.mjs:
//     bridge.js
//       -> patch.mjs  (createPatchPlugins, target: 'esbuild')
//       -> esbuild
//       -> dist/bundle.js
//
//   pack.mjs:
//     bridge.js
//       -> patch.mjs  (patchSource,       target: 'bare')
//       -> bare-pack
//       -> dist/ncm.bundle
//
// The esbuild pipeline MUST go through patch.mjs. Do not inline patches
// here — patch.mjs is the single source of truth and is shared with
// pack.mjs so that esbuild-specific patches (e.g. china_ip_ranges path
// rewrite) never leak into the Bare bundle, and Bare-specific patches
// (e.g. register_checktoken_v2 stub) never leak into the esbuild bundle.
//
// Output:
//   assets/bridge/dist/bundle.js
//   assets/bridge/dist/xhr-sync-worker.js   (copied by createXhrWorkerPlugin)

import * as esbuild from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  createPatchPlugins,
  createXhrWorkerPlugin,
} from './patch.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

const bridgeDir = __dirname

const outfile = path.resolve(bridgeDir, 'dist/bundle.js')

await esbuild.build({
  entryPoints: [path.resolve(bridgeDir, 'bridge.js')],

  bundle: true,

  platform: 'node',

  target: 'node18',

  format: 'cjs',

  outfile,

  sourcemap: false,

  minify: false,

  //
  // music-metadata v11+ is pure ESM and only exposes its entry via the
  // 'module-sync' / 'import' conditions in package.json#exports.
  //
  // Without this, esbuild cannot resolve require('music-metadata').
  //

  conditions: ['module-sync'],

  plugins: [
    //
    // Order matters only because both plugins touch distinct files; the
    // shim plugin marks jsdom's xhr-sync-worker require as external AND
    // copies the runtime shim, and the patch plugin rewrites the files
    // listed in patch.mjs (util/request, util/crypto, util/index,
    // node-forge, register_checktoken_v2, bridge.js itself).
    //

    createXhrWorkerPlugin(),
    ...createPatchPlugins(),
  ],
})
