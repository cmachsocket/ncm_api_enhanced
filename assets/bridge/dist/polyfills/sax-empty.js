// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/sax-empty.js
//
// Empty stub for `sax` on the QuickJS / flutter_js mobile runtime.
// See build_rollup.mjs for rationale. xml2js uses sax to parse
// streaming XML responses; for the mobile bundle, the endpoints that
// return XML (login_qr_create's QR polling response, some lyrics
// variants) throw at call time with a clear "sax disabled" error.

'use strict';

function disabled(name) {
  return () => {
    throw new Error('sax stubbed on mobile runtime: ' + name + ' is unavailable');
  };
}

module.exports = {
  parser:      disabled('sax.parser'),
  SAXParser:   class {},
  SAXStream:   class {},
  createStream: disabled('sax.createStream'),
  MAX_BUFFER_LENGTH: 64 * 1024,
  EVENT_: {},
};
