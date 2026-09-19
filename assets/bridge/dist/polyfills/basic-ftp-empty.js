// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/basic-ftp-empty.js
//
// Empty stub for the `basic-ftp` package. Upstream NCM pulls it via
// `util/request.js → https-proxy-agent → get-uri/dist/ftp.js`, but
// basic-ftp requires a real `net.Socket` (TCP) which doesn't exist
// in the QuickJS / flutter_js runtime. NCM API endpoints are HTTPS
// only — FTP-style handlers (proxy/ftp.js, get-uri's "ftp://" etc.)
// are never hit in production. Stubbing basic-ftp leaves those code
// paths to fail loudly if someone tries to use them, instead of
// crashing the whole bundle at module load time.

'use strict';

function disabled(method) {
  return () => {
    throw new Error(`basic-ftp.${method} is not available on mobile runtime`);
  };
}

module.exports = function Client() { throw new Error('basic-ftp disabled on mobile runtime'); };
module.exports.Client = module.exports;
module.exports.prototype = {};
module.exports.default = module.exports;
