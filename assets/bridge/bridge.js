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
// I/O source
// ---------------------------------------------------------------------------
//
// On the desktop / esbuild path the bridge runs as `node bridge.js` and
// talks to the host over NDJSON on stdin/stdout/stderr. On the
// bare-pack path it runs as a bare-kit Worklet — there is no stdin
// or stdout file descriptor — so we route everything through
// `BareKit.IPC` (the duplex stream exposed to the worklet by the
// Kotlin host side). The wire protocol is unchanged (NDJSON, one
// JSON object per line) so the Dart / Kotlin sides do not need to
// know which runtime is hosting the worklet.
//
// `bare-kit` is a real npm package published by holepunchto. Its
// worker-side entry is `require('bare-kit').IPC` which, when the
// JS runs inside a bare-kit Worklet, returns the same global that
// is reachable as `BareKit.IPC`. We pin `require('bare-kit')` here
// because bundlers and the bare module loader both understand it.

const isBare = typeof Bare !== 'undefined' && Bare

//
// When the worklet runs inside a bare-kit Worklet, the host sets the
// `Bare.IPC` global to a bare-stream Duplex connected to the Android
// `IPC` Java object. There is no npm package to require — `Bare.IPC`
// is just a global, the same way `process` is a global under Node.

const ipc = isBare ? Bare.IPC : null

const stdin = isBare ? ipc : process.stdin
const stdout = isBare ? ipc : process.stdout
const stderr = isBare ? ipc : process.stderr

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
    stdout.write(
      JSON.stringify(obj) + '\n',
    )
  } catch (err) {
    // At this point there is very little we can safely do.
    stderr.write(
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
  input: stdin,
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
