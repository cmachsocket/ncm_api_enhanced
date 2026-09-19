// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/debug-empty.js
//
// Empty stub for `debug` on the QuickJS / flutter_js mobile runtime.
//
// `debug` is a dev-time logger. Upstream NCM packages (music-metadata,
// @tokenizer/inflate, saxes, etc.) call `import debug from 'debug'` to
// get a logger function. None of these packages actually CALL the
// logger in production code paths that hit the NCM API — debug is
// only used in error branches and conditional debug paths.
//
// We replace debug with a no-op function so the `import debug from
// 'debug'` chain resolves cleanly through rollup-plugin-commonjs,
// without requiring the upstream `@tokenizer/inflate` packages to be
// patched to remove the debug dependency.

'use strict';

module.exports = function debug() { /* no-op */ };
module.exports.default = module.exports;
module.exports.formatters = { j: (v) => { try { return JSON.stringify(v); } catch { return '[Unserializable]'; } } };
