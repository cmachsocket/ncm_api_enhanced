// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/mobile_bridge_stub.js
//
// Replacement for bridge.js's stdin/stdout machinery on the QuickJS /
// flutter_js mobile runtime. The dart side calls `globalThis.__ncm_call`
// (defined by runtime_shim.js) which routes directly to handleRequest —
// the readline loop is bypassed entirely.
//
// We keep:
//   - handleRequest (the actual NCM API dispatch)
//   - send / replySuccess / replyError (now stubbed via runtime_shim's
//     globalThis.__ncm_original_send override)
//   - sendReady / sendFatal events
//   - uncaughtException / unhandledRejection handlers
//
// We remove:
//   - require('readline')
//   - the readline.createInterface() loop
//   - process.stdin/process.stdout references
//
// This file is loaded by build_browser.mjs via an esbuild onLoad plugin
// that intercepts the real bridge.js entry point when the bundle target
// is mobile.
//
// The downstream dart-side expects these globals/functions to exist after
// this module loads:
//   globalThis.__ncm_call(method, paramsJson) -> Promise<result>
//   globalThis.__ncm_dart_recv(s)             <- from runtime_shim.js
//   globalThis.__ncm_dart_send(s)            -> to dart
//
// handleRequest dispatches to the generated_api (same as desktop).

'use strict';

// We do NOT require('readline'), do NOT touch process.stdin/stdout.
// The runtime_shim.js banner has already patched globalThis.send to
// forward through globalThis.__ncm_dart_recv.

const api = require('./generated_api');

// ---------------------------------------------------------------------------
// Protocol: identical to desktop bridge.js except no readline loop.
// ---------------------------------------------------------------------------

function sendReady() {
  globalThis.__ncm_dart_recv(JSON.stringify({
    event: 'ready',
    data: { engine: 'quickjs', pid: -1 },
  }));
}

function sendFatal(msg, err) {
  try {
    globalThis.__ncm_dart_recv(JSON.stringify({
      event: 'fatal',
      data: {
        message: msg,
        error: err instanceof Error ? { message: err.message, stack: err.stack } : String(err),
      },
    }));
  } catch (_) { /* swallow */ }
}

function replySuccess(id, result) {
  globalThis.__ncm_dart_recv(JSON.stringify({ id, ok: true, result }));
}

function replyError(id, err) {
  if (err && typeof err === 'object' && !(err instanceof Error)) {
    let msg;
    try { msg = JSON.stringify(err); } catch { msg = String(err); }
    globalThis.__ncm_dart_recv(JSON.stringify({
      id, ok: false, error: { message: msg, stack: null },
    }));
  } else {
    globalThis.__ncm_dart_recv(JSON.stringify({
      id, ok: false,
      error: {
        message: err && err.message ? err.message : String(err),
        stack: err && err.stack ? err.stack : null,
      },
    }));
  }
}

async function handleRequest(request) {
  const { id, method, params } = request;
  try {
    if (typeof api[method] !== 'function') {
      throw new Error(`unknown module fn: ${method}`);
    }
    const result = await api[method](params || {});
    replySuccess(id, result);
  } catch (err) {
    replyError(id, err);
  }
}

// ---------------------------------------------------------------------------
// Public API exposed to dart via runtime_shim.js:
//   globalThis.__ncm_call(method, paramsJson) -> Promise<result>
// (replaces the readline loop's per-line dispatch)
// ---------------------------------------------------------------------------

if (typeof globalThis.__ncm_call !== 'function') {
  // runtime_shim.js defines __ncm_call before this file loads; if missing,
  // define a best-effort fallback that resolves immediately.
  let __ncm_id = 100000;
  globalThis.__ncm_call = function (method, paramsJson) {
    const id = __ncm_id++;
    return new Promise((resolve, reject) => {
      globalThis.__ncm_dart_recv(JSON.stringify({
        id, method, params: paramsJson == null ? {} : JSON.parse(paramsJson),
      }));
      // No way to resolve without a reply channel — throw loudly.
      reject(new Error('no reply channel; runtime_shim.js not loaded?'));
    });
  };
}

// Override runtime_shim.js's __ncm_call so it routes through handleRequest
// (which knows how to dispatch to api[method]). This way, dart calls
// __ncm_call(method, paramsJson), gets a Promise back, and we resolve it
// via __ncm_dart_send when the actual upstream API call completes.
globalThis.__ncm_call = function (method, paramsJson) {
  return new Promise((resolve, reject) => {
    const id = -1 - Math.floor(Math.random() * 1e9);
    let params;
    try { params = paramsJson == null ? {} : JSON.parse(paramsJson); }
    catch (e) { reject(new Error('bad paramsJson: ' + e.message)); return; }

    // We need to monkey-patch __ncm_dart_send so it resolves THIS promise
    // when it sees our id. Cleanest path: route through handleRequest,
    // which writes its response via __ncm_dart_recv — and we override
    // __ncm_dart_recv to capture the response keyed by id.
    //
    // BUT runtime_shim.js defines __ncm_dart_recv as the outbound pipe to
    // dart. We can't replace it without breaking the channel.
    //
    // Solution: handleRequest's replySuccess/replyError route through
    // globalThis.__ncm_dart_recv — but we also want __ncm_dart_send (inbound
    // pipe) to be a side channel for our internal promises. So we install
    // a per-id resolver that handleRequest consults before forwarding.
    const prevSend = globalThis.__ncm_dart_recv;
    globalThis.__ncm_dart_recv = function (s) {
      let parsed;
      try { parsed = JSON.parse(s); } catch { prevSend(s); return; }
      // If this is a reply to our internal id, resolve the promise.
      if (parsed && parsed.id === id) {
        globalThis.__ncm_dart_recv = prevSend;  // restore
        if (parsed.ok) resolve(parsed.result);
        else reject(new Error(parsed.error && parsed.error.message || 'bridge error'));
        return;
      }
      // Otherwise forward to dart (ready event, log, fatal).
      prevSend(s);
    };

    // Kick off the upstream call. handleRequest's reply will hit our
    // patched __ncm_dart_recv which checks the id.
    handleRequest({ id, method, params }).catch((err) => {
      globalThis.__ncm_dart_recv = prevSend;
      reject(err);
    });
  });
};

// ---------------------------------------------------------------------------
// Process-level safety nets. In QuickJS we may not have process.on, but
// __ncm_dart_send provides a generic channel for error reporting.
// ---------------------------------------------------------------------------

if (typeof globalThis.process !== 'undefined' && typeof globalThis.process.on === 'function') {
  globalThis.process.on('uncaughtException', (err) => sendFatal('uncaughtException', err));
  globalThis.process.on('unhandledRejection', (err) => sendFatal('unhandledRejection', err));
}

// Signal readiness to dart.
sendReady();
