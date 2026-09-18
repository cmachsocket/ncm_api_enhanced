// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/fs-empty.js
//
// Empty stub for `require('fs')` on the QuickJS / flutter_js mobile
// runtime. Upstream NCM uses fs.readFileSync in a handful of paths
// (xeapi public key, anonymous token); per user direction, those are
// being removed in the next upstream release, so we just make every
// fs.* call throw ENOENT — which the upstream code already wraps in
// try/catch.
//
// This stub exists so the Stackline polyfill plugin's resolveId
// doesn't throw on `require('fs')` (which would kill the build before
// any actual call site is reached). All fs methods throw so callers
// see a meaningful error rather than silently misbehaving.

'use strict';

function enoent(method) {
  return () => {
    const err = new Error(`fs.${method} is not available on mobile runtime`);
    err.code = 'ENOENT';
    throw err;
  };
}

const stub = {
  readFileSync:        enoent('readFileSync'),
  readFile:            enoent('readFile'),
  writeFileSync:       enoent('writeFileSync'),
  writeFile:           enoent('writeFile'),
  existsSync:          () => false,
  statSync:            enoent('statSync'),
  mkdirSync:           enoent('mkdirSync'),
  readdirSync:         enoent('readdirSync'),
  unlinkSync:          enoent('unlinkSync'),
  constants:           { O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2 },
};

module.exports = stub;
module.exports.default = stub;
module.exports.promises = {
  readFile:   enoent('promises.readFile'),
  writeFile:  enoent('promises.writeFile'),
  stat:       enoent('promises.stat'),
  mkdir:      enoent('promises.mkdir'),
  readdir:    enoent('promises.readdir'),
  unlink:     enoent('promises.unlink'),
};
