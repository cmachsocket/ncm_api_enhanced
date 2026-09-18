// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/unblock-empty.js
//
// Empty stub for `@neteasecloudmusicapienhanced/unblockmusic-utils` on
// the QuickJS / flutter_js mobile runtime.
//
// The real package is a CLI tool that requires `fs.readdirSync` and
// `process.exit` at module top level — fine on desktop where fs is real,
// broken on mobile where fs is stubbed. The NCM API only references it
// inside try/catch blocks (module/song_url_v1.js, module/song_url_match.js),
// so an empty module that throws "disabled on mobile" if anyone actually
// calls a method preserves behaviour without dragging in fs and express.

'use strict';

function disabled(name) {
  return () => {
    throw new Error('unblockmusic-utils disabled on mobile runtime');
  };
}

module.exports = {
  unblock:                       disabled('unblock'),
  match:                         disabled('match'),
  parseSongInfo:                 disabled('parseSongInfo'),
  DEFAULT_SERVER:                null,
  parseCookie:                   disabled('parseCookie'),
  setCookie:                     disabled('setCookie'),
  getServerFromConfig:           disabled('getServerFromConfig'),
};
