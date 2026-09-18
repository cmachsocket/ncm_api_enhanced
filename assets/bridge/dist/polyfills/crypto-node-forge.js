// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/crypto-node-forge.js
//
// CJS shim for `require('crypto')` on the QuickJS / flutter_js mobile
// runtime. Pulls node-forge directly (the same implementation Stackline's
// older rollup-plugin-node-polyfills bundled in its `crypto-browserify.js`,
// minus the broken `import { default as Buffer }` ESM bridge that fails
// under @rollup/plugin-commonjs v29 with strictRequires).
//
// Why this exists instead of using Stackline's bundled crypto-browserify:
//   1. Stackline (the modern fork) deliberately ships an EMPTY_PATH stub
//      for crypto (see modules.js — `libs.set('crypto', EMPTY_PATH)`)
//      and `throws` on `require('crypto')` unless `opts.crypto: true`,
//      which then STILL resolves to EMPTY_PATH. They don't ship a real
//      crypto polyfill in their 1.0.0 release.
//   2. We need createHash / createHmac / createDecipheriv for upstream
//      NCM's xeapi code path. node-forge provides all of these.
//
// CAVEAT (same as the older rollup-plugin-node-polyfills version):
//   - This is a thin CJS re-export wrapper around node-forge. Bundling
//     it brings the entire node-forge library (~1.5 MB) into the bundle.
//   - Performance is much slower than real crypto — node-forge is pure JS.
//   - QuickJS + node-forge is viable for login + song-url-decrypt but
//     not high-throughput use cases.

'use strict';

const forge = require('node-forge');

const cipherAlgorithms = {
  'aes-128-ecb': { keySize: 16, blockSize: 16, mode: 'ECB' },
  'aes-192-ecb': { keySize: 24, blockSize: 16, mode: 'ECB' },
  'aes-256-ecb': { keySize: 32, blockSize: 16, mode: 'ECB' },
  'aes-128-cbc': { keySize: 16, blockSize: 16, mode: 'CBC' },
  'aes-256-cbc': { keySize: 32, blockSize: 16, mode: 'CBC' },
};

function createHash(algorithm) {
  if (algorithm !== 'md5' && algorithm !== 'sha1' && algorithm !== 'sha256') {
    throw new Error('Unsupported hash algorithm: ' + algorithm);
  }
  const md = forge.md[algorithm].create();
  return {
    update(data) {
      md.update(typeof data === 'string' ? data : forge.util.createBuffer(data));
      return this;
    },
    digest(encoding) {
      const bytes = md.digest().getBytes();
      if (encoding === 'hex') return forge.util.bytesToHex(bytes);
      if (encoding === 'base64') return forge.util.encode64(bytes);
      return bytes;
    },
  };
}

function createDecipheriv(algorithm, key, iv) {
  const alg = cipherAlgorithms[algorithm];
  if (!alg) throw new Error('Unsupported cipher: ' + algorithm);
  const cipher = forge.cipher.createDecipher(
    algorithm.toUpperCase().replace(/-/g, '_'),
    forge.util.createBuffer(typeof key === 'string' ? forge.util.encode64(key) : key),
  );
  // forge expects start() with iv in CBC modes; empty Buffer for ECB
  if (alg.mode === 'CBC' && iv && iv.length > 0) {
    cipher.start({ iv: forge.util.createBuffer(iv) });
  } else {
    cipher.start();
  }
  return {
    update(data, _inputEnc, outputEnc) {
      cipher.update(forge.util.createBuffer(typeof data === 'string'
        ? forge.util.encode64(data)
        : data));
      return this;
    },
    final(outputEnc) {
      cipher.finish();
      const out = cipher.output.getBytes();
      return outputEnc === 'hex' ? forge.util.bytesToHex(out) : out;
    },
  };
}

module.exports = {
  createHash,
  createHmac: forge.hmac.create,
  createDecipheriv,
  randomBytes: (n) => {
    const bytes = forge.random.getBytesSync(n);
    return Buffer.from(bytes, 'binary');
  },
  // Pass-through to forge for anything else upstream might use
  defaults: forge.util,
};
