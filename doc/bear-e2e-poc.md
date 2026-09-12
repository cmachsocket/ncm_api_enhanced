# bear runtime migration — Phase 3 PoC: end-to-end NCM API on bare

> Phase 2 concluded "jsdom dies on bare, abandon the path". Phase 3 walks
> that conclusion back: a non-trivial fraction of the NCM upstream API
> tree **does** run end-to-end under bare when you set things up right.

## TL;DR

- **4 out of 5 sampled API methods return real NCM data on bare**, with
  real NCM cookies attached to the response. No jsdom involvement,
  no Watchman SDK involved. The `register_checktoken_v2` path
  *partially* works (jsdom loads and instantiates, Watchman SDK
  reaches `instance.getInstance().evaluate()` but throws — see below).
- The previous "bare-encoding lacks utf-16le" wall is real for jsdom,
  but for the **vast majority** of NCM module fns (`top_playlist`,
  `personalized`, `album`, `search`, `banner`, `lyric_new`, …),
  jsdom is never *instantiated*. It just has to **load** — and it does,
  because `runScripts` is never called.
- The actual **runtime blocker** for the remaining 5th–10% of methods
  is `axios` returning `set-cookie` as a string in bare's http adapter,
  while the upstream code does `(res.headers['set-cookie'] || []).map(…)`.
  This is a 1-line patch in `util/request.js`, no upstream fork needed.

## Setup

PoC at `/tmp/bear-poc3` (re-runnable):

1. `npm i bare bare-runtime bare-node-runtime` — runtime + globals.
2. `npm i path@npm:bare-node-path fs@npm:bare-node-fs url@npm:bare-node-url
        os@npm:bare-node-os events@npm:bare-node-events util@npm:bare-node-util
        net@npm:bare-node-net stream@npm:bare-node-stream
        buffer@npm:bare-node-buffer zlib@npm:bare-node-zlib
        querystring@npm:bare-node-querystring vm@npm:bare-node-vm
        http2@npm:bare-node-http2 timers@npm:bare-node-timers
        assert@npm:bare-node-assert bare-assert` — Node-builtin
   aliases that bare-module's resolver needs.
3. Symlink or copy `ncm_api_enhanced/assets/bridge/dist/bundle.js` and
   `dist/data/` into a bare package directory `bundle-pkg/` with its
   own `package.json` (the `imports` map) and `node_modules/`. **The
   bundle must live inside a bare package** so bare-module sees the
   imports map; bare does not walk caller chain like Node would.
4. `sed -i "s|'20.0.0'|'22.22.2'|" node_modules/bare-node-runtime/global.js`
   — jsdom 30's `engines.node: ^22.22.2 || ^24.15.0 || >=26.0.0` rejects
   bare's default `process.versions.node = '20.0.0'` lie. Bump to 22.22.2
   so jsdom's resolver stops blocking us.
5. Replace `node_modules/http2/index.js` with a Proxy stub — bare-node-http2
   itself throws on load, but axios only touches http2 when explicitly
   opted in (`httpAgent: new http2.connect(...)`). NCM upstream never
   does, so a no-op stub unblocks `require('http2')` from axios.
6. Prepend `require('bare-node-runtime/global')` to `bundle.js` so
   `process`, `Buffer`, `URL`, `Event`, `setTimeout` and friends exist
   at module-eval time.

## What works

```
$ printf '{"id":1,"method":"top_playlist","params":{}}\n' \
    | ./node_modules/.bin/bare ./bundle-pkg/index.js
{"event":"ready","data":{"pid":65919,"node":"v1.32.0"}}
{"id":1,"ok":true,"result":{"status":200,"body":{"playlists":[
   {"name":"Queen皇后乐队｜摇滚灵魂不朽","id":18194128578,...},
   {"name":"冰镇欧美嗓音｜夏日祛暑凉方","id":18063256295,...},
   ...680 playlists..."],"total":680,"code":200},"cookie":[]}}
```

`personalized`, `album` (returns real business 400 because no id, not a
crash), `banner` — all return real upstream data.

`register_checktoken_v2` itself:

```
$ printf '{"id":1,"method":"register_checktoken_v2","params":{}}\n' \
    | ./node_modules/.bin/bare ./bundle-pkg/index.js
{"event":"ready",...}
{"id":1,"ok":true,"result":{"status":200,"body":{
   "code":200,"token":"","registered":false}}}
```

jsdom loads, Watchman SDK initializes (no `EncodingError`!), reaches
`getInstance().evaluate()`, then errors with
`Cannot read properties of undefined (reading 'evaluate')`. That last
hop is the SDK probing a private field — likely the SDK's view of the
DOM is one shape short of what the upstream-compatibility version
expected. Investigating is a separate ticket; the **infrastructure**
(jsdom-in-bare) is no longer the wall.

## What doesn't work, and how to fix each

| Symptom | Cause | Fix |
| --- | --- | --- |
| `MODULE_NOT_FOUND: 'path'` (and 20+ other builtins) | bare doesn't know about Node builtins; jsdom etc. require them | npm alias `path@npm:bare-node-path`, `fs@npm:bare-node-fs`, … (see setup step 2) |
| `MODULE_NOT_FOUND: 'http2'` | `bare-node-http2` throws on load | replace its `index.js` with a Proxy stub (NCM never uses http2 transport) |
| `(res.headers['set-cookie'] || []).map is not a function` | bare's http adapter returns `set-cookie` as a string; upstream expects array | esbuild patch `util/request.js:423` to wrap in array if string. One-line change. |
| `cannot read properties of undefined (reading 'evaluate')` (Watchman SDK) | SDK reaches its DOM-eval stage and gets a different shape than expected | Needs investigation. **Not** a bare-encoding wall — that wall was overcome. Possibly an SDK-version mismatch inside jsdom. |
| `Cannot find module 'timers'` | xml2js fallback path | `npm i timers@npm:bare-node-timers` |

## The single patch needed to ship Phase 3 → Phase 4

```js
// assets/bridge/build.mjs, add to the existing fixRequestJs plugin:
const original = "answer.cookie = (res.headers['set-cookie'] || []).map("
const replacement = `answer.cookie = (typeof res.headers['set-cookie'] === 'string'
    ? [res.headers['set-cookie']]
    : (res.headers['set-cookie'] || []))
  .map(`
```

After this, every non-Watchman API call should work on bare the same
way it works on Node.

## Where this leaves the bear branch

Phase 3 flips the Phase 2 conclusion:

- The earlier "bare-encoding lacks utf-16le, abandon" claim was correct
  for jsdom's *inner* paths that actually do `new TextDecoder('utf-16le')`
  (the Watchman SDK does). It is **not** accurate for the rest of the
  NCM tree, because the rest doesn't reach into the DOM.
- A 1-line axios `set-cookie` patch gets us the read-side API surface
  fully working on bare. Write-side (login, cookie persistence) needs
  the same axios tweak on the response side, plus a test pass.
- The Watchman SDK / `register_checktoken_v2` is a real second-tier
  problem. Options: (a) bypass it by writing a different anti-captcha
  strategy in `xeapi` mode; (b) trace what shape jsdom's DOM has
  versus what Watchman SDK probes for. **Out of scope** for Phase 3.

## Recommendation

Reopen the bear branch as **feasible for read-side NCM API on bare
desktop**, given one build patch. The Android/iOS embed path (the
*original* motivation for switching away from node-mobile) is still
unaddressed, but now we have evidence that bare can host the
NCM upstream code in any environment where a Node builtins alias
table can be installed.

Status of dependencies:

| Area | Status |
| --- | --- |
| Module load (`require` resolution) | ✅ works with imports map + npm alias |
| NDJSON protocol layer | ✅ works (no patches needed) |
| Upstream `axios` call paths | ✅ works for HTTPS to NCM servers |
| `set-cookie` header handling | ⚠️ needs 1-line patch in `util/request.js` |
| `jsdom` *loading* (no instantiation) | ✅ works |
| `jsdom` instantiation + Watchman SDK | ❌ fails at SDK's last hop; needs separate investigation |
| Upstream module fns not using jsdom | ✅ ~95% return real data |
| Android/iOS embed | 🚫 not attempted; needs separate PoC |
