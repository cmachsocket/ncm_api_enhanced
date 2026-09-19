// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/crypto-js-shim.js
//
// Minimal `crypto-js`-compatible shim for the QuickJS / flutter_js mobile
// runtime. Upstream NCM packages use the `crypto-js` API for weapi
// encryption (login_qr_key, login, etc.):
//
//   CryptoJS.AES.encrypt(plaintext, key, {iv, mode, padding})
//   CryptoJS.AES.decrypt(ciphertext, key, {iv, mode, padding})
//   CryptoJS.enc.Utf8.parse(string)
//   CryptoJS.enc.Hex.parse(string)
//   CryptoJS.pad.Pkcs7
//   CryptoJS.mode.CBC
//
// The real `crypto-js` package's UMD wrapper does NOT survive
// @rollup/plugin-commonjs in strictRequires mode — the bundle ends up
// with `var core = Object.freeze({__proto__: null})` (an empty object)
// because plugin-commonjs fails to detect that `module.exports =
// exports = factory()` should make the factory's return value the
// module's exports. We sidestep the problem entirely by aliasing
// `crypto-js` to this shim, which provides the exact API surface NCM
// uses, backed by our existing node-forge shim for the AES primitives.
//
// Production: dart does NOT install this — QuickJS gets the real
// crypto-js when one is available. We only install this alias when
// running rollup-plugin-commonjs over the mobile bundle. desktop builds
// use the real crypto-js via esbuild (which handles UMD correctly).

'use strict';

const forge = require('node-forge');

// ---------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------
// crypto-js has encoders that produce WordArray-like objects with
// `words` (Array of 32-bit ints) and `sigBytes` (length). Our shim
// mimics that interface for the few operations NCM uses (.toString()
// .concat() .clamp() etc.). WordArray is just a Uint8Array-shaped view.

function wordArray(bytes) {
  return {
    words: bytesToWords(bytes),
    sigBytes: bytes.length,
    toString(encoder) {
      if (encoder === undefined) return bytesToHex(this.words, this.sigBytes);
      return encoder.stringify(this);
    },
    concat(other) {
      const a = wordsToBytes(this.words, this.sigBytes);
      const b = wordsToBytes(other.words, other.sigBytes);
      return wordArray(Buffer.concat([a, b]));
    },
  };
}

function bytesToWords(bytes) {
  // crypto-js words are big-endian 32-bit ints. We don't need exact
  // crypto-js layout — we only use words for sigBytes accounting and
  // for the rare `concat` case (which goes through wordArray above).
  // Returning the raw bytes as a flat array is enough.
  return Array.from(bytes);
}

function wordsToBytes(words, sigBytes) {
  return Buffer.from(words.slice(0, sigBytes));
}

function bytesToHex(words, sigBytes) {
  let s = '';
  for (let i = 0; i < sigBytes; i++) {
    s += (words[i] & 0xff).toString(16).padStart(2, '0');
  }
  return s;
}

const enc = {
  Utf8: {
    parse(str) {
      const bytes = Buffer.from(str, 'utf-8');
      return wordArray(bytes);
    },
    stringify(wa) {
      return Buffer.from(wordsToBytes(wa.words, wa.sigBytes)).toString('utf-8');
    },
  },
  Hex: {
    parse(hex) {
      const bytes = Buffer.from(hex, 'hex');
      return wordArray(bytes);
    },
    stringify(wa) {
      return bytesToHex(wa.words, wa.sigBytes);
    },
  },
};

// ---------------------------------------------------------------------------
// Padding
// ---------------------------------------------------------------------------
const pad = {
  Pkcs7: {
    pad(data, blockSize) {
      const bytes = wordsToBytes(data.words, data.sigBytes);
      const padLen = blockSize - (bytes.length % blockSize);
      const padded = Buffer.concat([bytes, Buffer.alloc(padLen, padLen)]);
      return wordArray(padded);
    },
    unpad(data, blockSize) {
      const bytes = wordsToBytes(data.words, data.sigBytes);
      if (bytes.length === 0) return data;
      const padLen = bytes[bytes.length - 1];
      // Validate (crypto-js is strict: throw on bad padding)
      if (padLen < 1 || padLen > blockSize) throw new Error('Invalid PKCS7 padding');
      for (let i = 1; i <= padLen; i++) {
        if (bytes[bytes.length - i] !== padLen) throw new Error('Invalid PKCS7 padding');
      }
      return wordArray(bytes.subarray(0, bytes.length - padLen));
    },
  },
};

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------
const mode = {
  CBC: {
    encrypt(cipher, keyWords, ivWords, blockSize) {
      // Pull the key bytes out of the word-array shape.
      const key = forge.util.createBuffer(wordsToBytes(keyWords, keyWords.length).toString('binary'));
      cipher.start({ iv: forge.util.createBuffer(wordsToBytes(ivWords, ivWords.length).toString('binary')) });
      cipher.update(forge.util.createBuffer(wordsToBytes(encrypt_data_input_to_bytes(...), 16).toString('binary')));
      return wordArray(bytesFromCipherOutput(cipher));
    },
  },
};

// crypto-js CBC.encrypt passes a single block at a time and accumulates
// output bytes. We adapt our forge cipher (which expects all bytes up
// front) by buffering. This is not how crypto-js does it under the
// hood, but the call sites (NCM's util/crypto.js) only call encrypt once
// per operation, so the per-block streaming behaviour doesn't matter.

function encrypt_data_input_to_bytes() { return []; } // unused — see below
function bytesFromCipherOutput(cipher) {
  const out = cipher.output.getBytes();
  cipher.output = forge.util.createBuffer();
  return Buffer.from(out, 'binary');
}

// Real implementation of CBC.encrypt using forge:
function cbcEncrypt(key, iv, paddedData) {
  // key + iv are WordArrays. Padded data is a WordArray.
  const cipher = forge.cipher.createCipher('AES-CBC', forge.util.createBuffer(wordsToBytes(key.words, key.sigBytes).toString('binary')));
  cipher.start({ iv: forge.util.createBuffer(wordsToBytes(iv.words, iv.sigBytes).toString('binary')) });
  cipher.update(forge.util.createBuffer(wordsToBytes(paddedData.words, paddedData.sigBytes).toString('binary')));
  cipher.finish();
  const out = cipher.output.getBytes();
  return wordArray(Buffer.from(out, 'binary'));
}

function cbcDecrypt(key, iv, ciphertext) {
  const decipher = forge.cipher.createDecipher('AES-CBC', forge.util.createBuffer(wordsToBytes(key.words, key.sigBytes).toString('binary')));
  decipher.start({ iv: forge.util.createBuffer(wordsToBytes(iv.words, iv.sigBytes).toString('binary')) });
  decipher.update(forge.util.createBuffer(wordsToBytes(ciphertext.words, ciphertext.sigBytes).toString('binary')));
  decipher.finish();
  const out = decipher.output.getBytes();
  return wordArray(Buffer.from(out, 'binary'));
}

// ---------------------------------------------------------------------------
// AES
// ---------------------------------------------------------------------------
const AES = {
  encrypt(plaintext, key, opts = {}) {
    // plaintext can be a string OR a WordArray (enc.Utf8.parse result)
    let ptWa;
    if (typeof plaintext === 'string') ptWa = enc.Utf8.parse(plaintext);
    else ptWa = plaintext;

    const keyWa = (typeof key === 'string') ? enc.Utf8.parse(key) : key;
    const blockSize = 16;
    const padded = opts.padding
      ? opts.padding.pad(ptWa, blockSize)
      : ptWa;

    if (opts.mode === mode.CBC) {
      const iv = opts.iv || enc.Utf8.parse('\0'.repeat(16));
      const ct = cbcEncrypt(keyWa, iv, padded);
      // crypto-js AES.encrypt returns an object with .ciphertext (the
      // cipher output bytes) and .key/.iv/.algorithm for completeness.
      return {
        ciphertext: ct,
        key: keyWa,
        iv: iv,
        algorithm: AES,
        toString(encoder) {
          const text = ct.toString(encoder || enc.Hex);
          return text;
        },
      };
    }
    throw new Error('crypto-js-shim: only CBC mode is supported');
  },

  decrypt(ciphertextInput, key, opts = {}) {
    // ciphertextInput can be:
    //   - a string (base64 by default, or hex if {ciphertext: WordArray})
    //   - an object { ciphertext: WordArray }
    let ctWa;
    if (typeof ciphertextInput === 'string') {
      // crypto-js default is base64 ciphertext for toString; but
      // .decrypt expects base64 string and parses it as base64 by default.
      // NCM uses Hex in most paths — caller passes { ciphertext: HexWa }.
      ctWa = enc.Utf8.parse(forge.util.decode64(ciphertextInput));
    } else if (ciphertextInput.ciphertext) {
      ctWa = ciphertextInput.ciphertext;
    } else {
      ctWa = ciphertextInput;
    }

    const keyWa = (typeof key === 'string') ? enc.Utf8.parse(key) : key;
    const blockSize = 16;
    const iv = opts.iv || enc.Utf8.parse('\0'.repeat(16));
    const padded = cbcDecrypt(keyWa, iv, ctWa);
    const unpadded = opts.padding
      ? opts.padding.unpad(padded, blockSize)
      : padded;
    return unpadded;
  },
};

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------
const CryptoJS = {
  AES,
  enc,
  pad,
  mode,
  lib: { WordArray: wordArray },
  MD5:    null,  // not used by NCM API paths
  SHA256: null,  // not used by NCM API paths
};

// Some NCM code does `const { AES, enc, mode, pad } = require('crypto-js')`
// destructuring. UMD-wrapped crypto-js returns a single object whose
// properties include those. To support destructuring at the require()
// call site, expose them as own properties.
module.exports = CryptoJS;
module.exports.AES  = AES;
module.exports.enc  = enc;
module.exports.pad  = pad;
module.exports.mode = mode;
module.exports.lib  = CryptoJS.lib;
