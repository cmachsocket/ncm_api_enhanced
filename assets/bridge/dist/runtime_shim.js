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
// XHR shim (QuickJS has no XMLHttpRequest).
//
// Production target is flutter_js, which provides XMLHttpRequest backed by
// dart:http. In the node smoke test we don't have flutter_js — we install
// a minimal XHR shim here, only when running under plain node. The shim is
// guarded so that production (QuickJS + dart-installed XHR) takes
// precedence and the node fallback doesn't fire.
// ---------------------------------------------------------------------------
if (typeof globalThis.XMLHttpRequest === 'undefined' &&
    typeof process !== 'undefined' && process.versions && process.versions.node) {
  // Node-only XHR shim. Uses node http / https to actually perform the
  // request. Synchronous-ish (axios calls .send() then awaits events).
  // This exists ONLY for smoke-testing the bundle in plain node. In the
  // QuickJS + flutter_js runtime, dart installs the real XMLHttpRequest
  // via the dart:http bridge before evaluating this bundle.
  //
  // Note on `require`: vendor package.json declares "type": "module", so
  // node treats .js files as ESM and forbids `require` at top level.
  // But this whole shim is inside the rollup-emitted IIFE wrapper which
  // rolls up to a CommonJS-shaped bundle (format: 'iife'). Inside that
  // IIFE, `require` IS available because rollup leaves it as a bareword
  // (not as an ESM import) when used at runtime. We use `require` here
  // because the IIFE bundle's overall call shape requires a synchronous
  // constructor — top-level await inside the IIFE is invalid.
  // eslint-disable-next-line no-undef
  const http  = require('http');
  // eslint-disable-next-line no-undef
  const https = require('https');
  // eslint-disable-next-line no-undef
  const { URL } = require('url');

  class NodeXhrShim {
    constructor() {
      this.readyState = 0;
      this.responseURL = '';
      this.status = 0;
      this.statusText = '';
      this.responseText = '';
      this.response = null;
      this.responseType = '';
      this._headers = {};
      this._requestHeaders = {};
      this._method = 'GET';
      this._url = null;
      this._aborted = false;
      this.onreadystatechange = null;
      this.onload = null;
      this.onerror = null;
    }
    open(method, url) {
      this._method = method;
      this._url = url;
      this.readyState = 1;
    }
    setRequestHeader(k, v) { this._requestHeaders[k] = v; }
    abort() { this._aborted = true; }
    getAllResponseHeaders() {
      return Object.entries(this._headers)
        .map(([k, v]) => `${k}: ${v}`).join('\r\n');
    }
    getResponseHeader(k) { return this._headers[k.toLowerCase()] || null; }
    send(body) {
      const url = new URL(this._url);
      const lib = url.protocol === 'https:' ? https : http;
      const req = lib.request({
        method: this._method,
        hostname: url.hostname,
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: url.pathname + url.search,
        headers: this._requestHeaders,
      }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          this.status = res.statusCode;
          this.statusText = res.statusMessage;
          this._headers = {};
          for (const [k, v] of Object.entries(res.headers)) this._headers[k.toLowerCase()] = v;
          this.responseText = Buffer.concat(chunks).toString('utf-8');
          this.readyState = 4;
          if (this.onreadystatechange) this.onreadystatechange();
          if (this.onload) this.onload();
        });
      });
      req.on('error', (err) => {
        if (this.onerror) this.onerror(err);
      });
      if (body != null) req.write(body);
      req.end();
    }
  }
  globalThis.XMLHttpRequest = NodeXhrShim;
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
