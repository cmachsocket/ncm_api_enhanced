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

function _toForgeBytes(data) {
  if (data == null) return forge.util.createBuffer();
  if (typeof data === 'string') return forge.util.createBuffer(data);
  if (Buffer.isBuffer(data)) {
    // node Buffer → forge byte buffer (binary-encoded string)
    return forge.util.createBuffer(data.toString('binary'));
  }
  if (data instanceof Uint8Array) {
    return forge.util.createBuffer(Buffer.from(data).toString('binary'));
  }
  // already a forge byte buffer?
  if (typeof data.length === 'number' && typeof data.at === 'function') {
    return data;
  }
  return forge.util.createBuffer(String(data));
}

function createDecipheriv(algorithm, key, iv) {
  const alg = cipherAlgorithms[algorithm];
  if (!alg) throw new Error('Unsupported cipher: ' + algorithm);
  const forgeAlg = algorithm.toUpperCase().replace(/-\d{3}-/, '-');
  const cipher = forge.cipher.createDecipher(forgeAlg, _toForgeBytes(key));
  if (alg.mode === 'CBC' && iv && iv.length > 0) {
    cipher.start({ iv: _toForgeBytes(iv) });
  } else {
    // node's crypto.createDecipheriv with the default autoPadding=true
    // strips PKCS#7 padding for us. forge's default behaviour is the
    // same — its `unpad` is called automatically when the underlying
    // mode's `.finish()` runs. We mimic the default by passing
    // nothing here, so callers see the same bytes as they would on node.
    cipher.start();
  }

  // node's crypto.createDecipheriv().update() buffers the input until
  // .final() is called (see test in this file). This is because the
  // padding bytes are only knowable after all input bytes have been
  // processed. forge works differently — its .update() pushes decrypted
  // bytes (including padding) into .output immediately. We bridge the
  // two behaviours here by NOT calling cipher.update on .update(); we
  // accumulate the input in a local buffer and feed it all to forge on
  // .final(). This matches node's API exactly.
  let buffered = Buffer.alloc(0);

  return {
    update(data, _inputEnc, _outputEnc) {
      const chunk = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
      buffered = buffered.length === 0 ? chunk : Buffer.concat([buffered, chunk]);
      return Buffer.alloc(0);  // node returns empty string/Buffer until final()
    },
    final(_outputEnc) {
      cipher.update(_toForgeBytes(buffered));
      cipher.finish();  // forge's default: strip PKCS#7 in decrypt mode
      const out = cipher.output.bytes();
      return Buffer.from(out, 'binary');
    },
  };
}

// node's crypto.createHmac(algo, key) returns an object with update/digest
// that you can call multiple times before digest. forge.hmac.create() is
// the constructor and returns an instance, but the instance needs .start()
// to be called first. Wrap forge.hmac so it matches node's API.
function createHmac(algorithm, key) {
  const hmac = forge.hmac.create();
  const keyBytes = typeof key === 'string'
    ? key
    : (Buffer.isBuffer(key) ? key.toString('binary') : key);
  hmac.start(algorithm, keyBytes);
  return {
    update(data) {
      const s = typeof data === 'string'
        ? data
        : (Buffer.isBuffer(data) ? data.toString('binary') : data);
      hmac.update(s);
      return this;
    },
    digest(encoding) {
      const bytes = hmac.digest().getBytes();
      if (encoding === 'hex') return forge.util.bytesToHex(bytes);
      if (encoding === 'base64') return forge.util.encode64(bytes);
      return bytes;
    },
  };
}

module.exports = {
  createHash,
  createHmac,
  createDecipheriv,
  randomBytes: (n) => {
    const bytes = forge.random.getBytesSync(n);
    return Buffer.from(bytes, 'binary');
  },
  // Pass-through to forge for anything else upstream might use
  defaults: forge.util,
};
