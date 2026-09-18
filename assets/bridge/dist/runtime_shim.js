// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/runtime_shim.js
//
// Prepended to bundle.browser.js via esbuild's `banner` option. Provides:
//
//   1. Browser-API globals (window / self / document / location / navigator)
//      because QuickJS has none of these, but @jspm/core's crypto polyfill
//      (node-forge) and axios.browser.cjs reference them.
//
//   2. The transport shim between the JS bundle and the dart side via
//      flutter_js's sendMessage / onMessage channels:
//        - globalThis.__ncm_dart_recv(s)  — JS calls this to send to dart
//          (dart wires it to sendMessage('ncm_req', s))
//        - globalThis.__ncm_dart_send(s)  — dart calls this to send to JS
//          (dart wires onMessage('ncm_res') to invoke it)
//
//   3. The high-level request API that dart uses to invoke an upstream
//      NCM module function:
//
//        const resultJson = await runtime.evaluateAsync(
//          "__ncm_call('user_account', '{}')"
//        )
//
//      Internally __ncm_call generates a request id, calls the upstream
//      api[method](params) via handleRequest (which the entry point
//      mobile_entry.js provides), and resolves the promise when the
//      reply fires.
//
// Note: top-level await is forbidden (QuickJS / IIFE bundle wrapper).

'use strict';

// ---------------------------------------------------------------------------
// 1. Browser-API globals
// ---------------------------------------------------------------------------
if (typeof globalThis.window   === 'undefined') globalThis.window   = globalThis;
if (typeof globalThis.self     === 'undefined') globalThis.self     = globalThis;
if (typeof globalThis.document === 'undefined') {
  globalThis.document = { addEventListener() {}, removeEventListener() {} };
}
if (typeof globalThis.location === 'undefined') {
  globalThis.location = { href: 'http://localhost', protocol: 'http:', host: 'localhost' };
}
if (typeof globalThis.navigator === 'undefined') {
  globalThis.navigator = { userAgent: 'quickjs-mobile-bridge' };
}

// ---------------------------------------------------------------------------
// 2. Transport
// ---------------------------------------------------------------------------
// globalThis.__ncm_dart_recv is the OUTBOUND pipe: JS -> dart.
// In production (mobile / flutter_js) the dart runtime sets this before
// evaluating the bundle, typically by evaluating
//   `globalThis.__ncm_dart_recv = (s) => dart_send('ncm_req', s)`
// at init time. The fallback below is a silent no-op so the ready event
// below doesn't throw if dart hasn't wired it yet (defensive).
if (typeof globalThis.__ncm_dart_recv !== 'function') {
  globalThis.__ncm_dart_recv = function (_s) { /* drop */ };
}

// globalThis.__ncm_dart_send is the INBOUND pipe: dart -> JS.
// Dart's runtime (lib/src/mobile/ncm_js_runtime.dart) wires
// `onMessage('ncm_res', ...)` to call this with the raw JSON string.
//
// Mobile entry (mobile_entry.js) installs its own __ncm_call which uses
// __ncm_pending + __ncm_dart_send resolution; that file MUST load after
// this banner so it can install __ncm_call. The banner installs a
// no-op __ncm_call here so the bundle never crashes if for some reason
// mobile_entry.js didn't define one.
if (typeof globalThis.__ncm_call !== 'function') {
  globalThis.__ncm_call = function (_method, _paramsJson) {
    return Promise.reject(new Error(
      'ncm bridge: __ncm_call not initialized. mobile_entry.js must load ' +
      'after this shim to provide the dispatcher.',
    ));
  };
}

// ---------------------------------------------------------------------------
// 3. Ready signal
// ---------------------------------------------------------------------------
globalThis.__ncm_dart_recv(JSON.stringify({
  event: 'ready',
  data: { engine: 'quickjs', pid: -1 },
}));
