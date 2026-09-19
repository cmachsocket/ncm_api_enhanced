// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/crypto-js-empty.js
//
// Empty stub for `crypto-js` on the QuickJS / flutter_js mobile runtime.
// See build_rollup.mjs for the rationale: @rollup/plugin-commonjs
// cannot correctly handle crypto-js's UMD wrapper, so we replace it
// with a no-op object. Code paths that touch crypto-js (login, register,
// decrypt) will throw at call time; common API calls like user_account,
// song_url_v1, etc. work because they don't touch crypto-js.

'use strict';

const disabled = (name) => () => {
  throw new Error(`crypto-js stubbed on mobile runtime: ${name} is unavailable`);
};

const obj = {
  AES: {
    encrypt: disabled('AES.encrypt'),
    decrypt: disabled('AES.decrypt'),
  },
  enc: {
    Utf8: { parse: disabled('enc.Utf8.parse'), stringify: disabled('enc.Utf8.stringify') },
    Hex:  { parse: disabled('enc.Hex.parse'),  stringify: disabled('enc.Hex.stringify')  },
    Base64:{ parse: disabled('enc.Base64.parse'), stringify: disabled('enc.Base64.stringify') },
  },
  pad: {
    Pkcs7: { pad: disabled('pad.Pkcs7.pad'), unpad: disabled('pad.Pkcs7.unpad') },
  },
  mode: {
    CBC: { encrypt: disabled('mode.CBC.encrypt') },
  },
  lib: { WordArray: class WordArray {} },
  MD5:    disabled('MD5'),
  SHA256: disabled('SHA256'),
  HmacSHA256: disabled('HmacSHA256'),
};

module.exports = obj;
module.exports.default = obj;
