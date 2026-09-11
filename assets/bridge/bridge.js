// NCM API Enhanced — Dart ↔ Node bridge.
//
// Protocol: NDJSON over stdin/stdout. One JSON object per line.
//   Request  (Dart -> Node): {"id": <int>, "method": "<moduleFn>", "params": { ... }}
//   Response (Node -> Dart): {"id": <int>, "ok": true,  "result": { ... }}
//                             {"id": <int>, "ok": false, "error":  { "message": "...", "stack": "..." }}
//   Event    (Node -> Dart): {"event": "ready" | "log" | "fatal", "data": ...}
//
// In-flight requests are tracked in a Map keyed by id. The upstream NCM module
// functions are pure async (each returns Promise<Response>), so node's event
// loop handles concurrent Dart requests natively — no worker pool needed.

'use strict'

const readline = require('readline')
const path = require('path')

// Resolve the upstream module relative to this bridge script. The Flutter
// assets bundle places @neteasecloudmusicapienhanced at <bridge>/node_modules/.
const api = require('@neteasecloudmusicapienhanced/api')

// ---------------------------------------------------------------------------
// Protocol plumbing
// ---------------------------------------------------------------------------

let nextId = 1
const inFlight = new Map() // id -> { resolve, reject, method }

function send(obj) {
  // stdout must always be one line; we control all callers so JSON.stringify
  // will not emit newlines for our payload shape.
  process.stdout.write(JSON.stringify(obj) + '\n')
}

function reply(id, ok, payload) {
  const base = { id }
  if (ok) {
    base.ok = true
    base.result = payload
  } else {
    base.ok = false
    base.error = {
      message: payload && payload.message ? payload.message : String(payload),
      stack: payload && payload.stack ? payload.stack : undefined,
    }
  }
  send(base)
}

function fatal(message, err) {
  send({
    event: 'fatal',
    data: {
      message,
      stack: err && err.stack ? err.stack : undefined,
    },
  })
}

process.on('uncaughtException', (err) => fatal('uncaughtException', err))
process.on('unhandledRejection', (err) => fatal('unhandledRejection', err))

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

async function handleRequest(req) {
  const { id, method, params } = req
  const fn = api[method]
  if (typeof fn !== 'function') {
    reply(id, false, new Error(`unknown method: ${method}`))
    return
  }
  // Forward to upstream — it already accepts (data, request) but as a library
  // call it just needs (data). Upstream's main.js only injects a request
  // helper when serving over HTTP; library mode skips that and uses the
  // default axios path inside util/request.js (see module.exports wiring).
  try {
    const result = await fn(params || {})
    reply(id, true, result)
  } catch (err) {
    reply(id, false, err)
  }
}

const rl = readline.createInterface({ input: process.stdin })
let buffer = ''
rl.on('line', (line) => {
  if (!line) return
  let req
  try {
    req = JSON.parse(line)
  } catch (err) {
    fatal('invalid JSON on stdin: ' + line.slice(0, 200))
    return
  }
  if (typeof req.id !== 'number') {
    fatal('request missing numeric id: ' + line.slice(0, 200))
    return
  }
  // Fire-and-forget — concurrent in-flight is fine, event loop handles it.
  handleRequest(req)
})

rl.on('close', () => {
  // Dart closed stdin → tear down. Reject any pending so the dart side wakes.
  for (const [, entry] of inFlight) {
    try {
      entry.reject(new Error('bridge stdin closed'))
    } catch (_) {}
  }
  inFlight.clear()
  process.exit(0)
})

// We're up.
send({ event: 'ready', data: { pid: process.pid, node: process.version } })