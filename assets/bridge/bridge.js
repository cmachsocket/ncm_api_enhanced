// NCM API Enhanced — Dart ↔ Node bridge.
//
// Protocol: NDJSON over stdin/stdout.
//
// Request:
//   {"id": <int>, "method": "<moduleFn>", "params": { ... }}
//
// Response:
//   {"id": <int>, "ok": true,  "result": { ... }}
//   {"id": <int>, "ok": false, "error": { "message": "...", "stack": "..." }}
//
// Event:
//   {"event": "ready" | "log" | "fatal", "data": ...}

'use strict'

const readline = require('readline')

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------
//
// generated_api.js MUST contain only statically analyzable imports/requires.
// Do NOT require the original @neteasecloudmusicapienhanced/api/main.js here.
//
// This allows esbuild to recursively bundle:
//
//   module/*.js
//   util/*.js
//   plugins/*.js
//   axios
//   xml2js
//   etc.
//
// into the final bundle.js.
//

const api = require('./generated_api')

// ---------------------------------------------------------------------------
// Protocol
// ---------------------------------------------------------------------------

function send(obj) {
  try {
    process.stdout.write(
      JSON.stringify(obj) + '\n',
    )
  } catch (err) {
    // At this point there is very little we can safely do.
    process.stderr.write(
      `[ncm bridge] failed to write response: ${
        err instanceof Error ? err.stack : String(err)
      }\n`,
    )
  }
}

function replySuccess(id, result) {
  send({
    id,
    ok: true,
    result,
  })
}

function replyError(id, err) {
  // Upstream fns sometimes Promise.reject({status, body, cookie}) instead of
  // an Error. JSON-stringify the value into `message` so Dart (which only
  // reads `message`/`stack` per the NDJSON protocol) sees something useful
  // instead of the useless "[object Object]".
  if (err && typeof err === 'object' && !(err instanceof Error)) {
    let msg
    try {
      msg = JSON.stringify(err)
    } catch {
      msg = String(err)
    }
    send({
      id,
      ok: false,
      error: {
        message: msg,
        stack: undefined,
      },
    })
    return
  }

  const error =
    err instanceof Error
      ? err
      : new Error(String(err))

  send({
    id,
    ok: false,
    error: {
      message: error.message,
      stack: error.stack,
    },
  })
}

function sendFatal(message, err) {
  const error =
    err instanceof Error
      ? err
      : err
        ? new Error(String(err))
        : null

  send({
    event: 'fatal',
    data: {
      message,
      stack: error?.stack,
    },
  })
}

// ---------------------------------------------------------------------------
// Request dispatch
// ---------------------------------------------------------------------------

async function handleRequest(req) {
  if (
    !req ||
    typeof req !== 'object'
  ) {
    return
  }

  const id = req.id

  if (!Number.isInteger(id)) {
    sendFatal(
      'request missing numeric id',
      new Error(
        `Invalid request id: ${JSON.stringify(id)}`,
      ),
    )
    return
  }

  const method = req.method

  if (
    typeof method !== 'string' ||
    method.length === 0
  ) {
    replyError(
      id,
      new Error('request missing method'),
    )
    return
  }

  const fn = api[method]

  if (typeof fn !== 'function') {
    replyError(
      id,
      new Error(`unknown method: ${method}`),
    )
    return
  }

  const params =
    req.params &&
    typeof req.params === 'object' &&
    !Array.isArray(req.params)
      ? req.params
      : {}

  try {
    const result = await fn(params)

    replySuccess(id, result)
  } catch (err) {
    replyError(id, err)
  }
}

// ---------------------------------------------------------------------------
// stdin
// ---------------------------------------------------------------------------

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
})

rl.on('line', (line) => {
  line = line.trim()

  if (!line) {
    return
  }

  let request

  try {
    request = JSON.parse(line)
  } catch (err) {
    sendFatal(
      'invalid JSON on stdin',
      err,
    )
    return
  }

  // Do not await here.
  //
  // Multiple requests may be in flight simultaneously.
  // Dart matches responses using the request id.
  handleRequest(request).catch((err) => {
    sendFatal(
      'request handler failure',
      err,
    )
  })
})

// ---------------------------------------------------------------------------
// stdin closed
// ---------------------------------------------------------------------------

rl.on('close', () => {
  // Dart closing stdin means the bridge is shutting down.
  //
  // There is no Node-side pending table because Dart owns the request
  // lifecycle and PendingTable.
  process.exit(0)
})

// ---------------------------------------------------------------------------
// Process-level failures
// ---------------------------------------------------------------------------

process.on('uncaughtException', (err) => {
  sendFatal(
    'uncaughtException',
    err,
  )

  process.exitCode = 1
})

process.on('unhandledRejection', (reason) => {
  sendFatal(
    'unhandledRejection',
    reason,
  )

  process.exitCode = 1
})

// ---------------------------------------------------------------------------
// Ready
// ---------------------------------------------------------------------------

send({
  event: 'ready',
  data: {
    pid: process.pid,
    node: process.version,
  },
})
