// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/jsdom-empty.js
//
// Empty stub for the `jsdom` module on the QuickJS / flutter_js mobile
// runtime. axios.browser.cjs's xhr adapter references `JSDOM` and the
// jsdom package's XMLHttpRequest class, but jsdom needs DOM/Canvas/Worker
// APIs that don't exist in QuickJS and would crash the bundle even if
// only loaded.
//
// In mobile runtime, the dart-side bridge installs `globalThis.XMLHttpRequest`
// (via flutter_js) before evaluating the bundle. axios uses that. Anything
// that explicitly imports `{ JSDOM, VirtualConsole }` (currently only
// register_checktoken_v2.js, which we already stub out under BUILD_TARGET=bare)
// gets this empty module instead.

'use strict';

module.exports = {
  JSDOM:         function () { throw new Error('jsdom disabled on mobile runtime'); },
  VirtualConsole: function () {},
  ResourceLoader: function () {},
  CookieJar:     function () {},
};
module.exports.JSDOM.fromURL = function () { throw new Error('jsdom disabled on mobile runtime'); };
