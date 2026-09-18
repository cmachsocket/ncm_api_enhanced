// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/mobile_entry.js
//
// Mobile entry point for the QuickJS / flutter_js bundle. Replaces
// bridge.js's stdin/stdout NDJSON loop with a direct in-process dispatcher:
//
//   dart:  __ncm_call('user_account', '{"uid":"123"}')
//   JS:    api.user_account({uid:'123'})
//   JS:    reply via __ncm_pending map (promise resolution)
//   dart:  Promise<JsonString> resolves with result
//
// No readline, no process.stdin/stdout, no dart round-trip per call.
// The dart side invokes __ncm_call synchronously via flutter_js's
// JavascriptRuntime.evaluateAsync and awaits the Promise result.

'use strict';

// generated_api.js is built by upstream NCM refresh; same artifact
// desktop bridge.js consumes, so we keep the dependency shape identical.
// It lives one directory up from dist/ (alongside bridge.js).
const api = require('../generated_api');

// ---------------------------------------------------------------------------
// Outbound pipe (JS -> dart). __ncm_dart_recv is set by the dart runtime
// shim before evaluating this entry. If for some reason it wasn't set,
// fall back to a no-op so we don't crash.
// ---------------------------------------------------------------------------
if (typeof globalThis.__ncm_dart_recv !== 'function') {
  globalThis.__ncm_dart_recv = function (_s) { /* drop */ };
}

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

// ---------------------------------------------------------------------------
// Request dispatch (no stdin loop — dart invokes us directly).
// ---------------------------------------------------------------------------

const __ncm_pending = new Map();
let __ncm_next_id = 1;

// Override __ncm_dart_send (installed by runtime_shim if any inbound traffic
// from dart comes in — for our model dart doesn't reply per call, so this
// is mainly for graceful shutdown). We keep the no-op if it isn't set.
if (typeof globalThis.__ncm_dart_send !== 'function') {
  globalThis.__ncm_dart_send = function (_rawJson) { /* drop */ };
}

// __ncm_call is the dart-callable surface. Returns a Promise<string> of
// JSON-serialised result. Errors resolve with the upstream NCM error
// shape (status/body/cookie) as the message so dart can decode it.
globalThis.__ncm_call = function (method, paramsJson) {
  return new Promise((resolve, reject) => {
    let params;
    try { params = paramsJson == null ? {} : JSON.parse(paramsJson); }
    catch (e) { reject(new Error('bad paramsJson: ' + e.message)); return; }

    if (typeof api[method] !== 'function') {
      reject(new Error('unknown module fn: ' + method));
      return;
    }

    Promise.resolve()
      .then(() => api[method](params))
      .then(
        (result) => resolve(JSON.stringify(result == null ? null : result)),
        (err) => {
          // Preserve enough context for dart to log. We re-throw as a fresh
          // Error so the stack frames from inside the upstream API call are
          // visible (we've already lost them at this point because the
          // thrown value here is what the upstream Promise rejected with,
          // but the new Error carries them).
          //
          // For object-shaped rejections (the upstream code's idiom is
          // Promise.reject({status, body, cookie})), JSON-stringify the
          // value so dart sees something useful rather than "[object Object]".
          if (err && typeof err === 'object' && !(err instanceof Error)) {
            let msg;
            try { msg = JSON.stringify(err); } catch { msg = String(err); }
            reject(new Error(msg));
          } else {
            reject(err instanceof Error ? err : new Error(String(err)));
          }
        },
      );
  });
};

// Silence "unused" warnings — these are reachable from runtime_shim/dart.
void __ncm_pending;
void __ncm_next_id;
void __ncm_dart_send;

// ---------------------------------------------------------------------------
// Process-level safety nets.
// ---------------------------------------------------------------------------
if (typeof globalThis.process !== 'undefined' && typeof globalThis.process.on === 'function') {
  globalThis.process.on('uncaughtException',  (err) => sendFatal('uncaughtException',  err));
  globalThis.process.on('unhandledRejection', (err) => sendFatal('unhandledRejection', err));
}

// ---------------------------------------------------------------------------
// Signal readiness to dart.
// ---------------------------------------------------------------------------
sendReady();
