# bear runtime migration — Phase 2 PoC: jsdom on bare

> Status: **negative**. jsdom *loads* under bare but the Watchman SDK
> reverse-captcha path is blocked by bare's stdlib gaps. Detailed below.

## What was tried

**Setup** (`/tmp/bear-poc2` on this machine):

```sh
npm i bare bare-runtime bare-node-runtime jsdom
npm i path@npm:bare-node-path fs@npm:bare-node-fs \
        url@npm:bare-node-url os@npm:bare-node-os \
        events@npm:bare-node-events util@npm:bare-node-util \
        net@npm:bare-node-net stream@npm:bare-node-stream \
        buffer@npm:bare-node-buffer zlib@npm:bare-node-zlib \
        querystring@npm:bare-node-querystring vm@npm:bare-node-vm
sed -i "s|process.versions.node = '20.0.0'|process.versions.node = '22.22.2'|" \
    node_modules/bare-node-runtime/global.js
```

The npm aliases are the only way to inject bare-* equivalents for the
Node builtins that jsdom's internals `require()` — bare-module's resolver
only consults the *caller* package's `imports` map, not the parent's. Without
the aliases, jsdom's `lib/api.js` triggers
`MODULE_NOT_FOUND: 'path'`/`'fs'`/`'url'`/… and dies at load time.

Also patched `bare-node-runtime/global.js` to lie about its Node version.
jsdom 30 declares `engines.node: ^22.22.2 || ^24.15.0 || >=26.0.0`, and bare
shipped as 20.0.0 trips the engine check at resolution time.

## Result: jsdom loads, then crashes at runtime

```
jsdom package: 30.0.1
require jsdom...  ← OK after the npm-alias dance
new JSDOM(...)
Uncaught EncodingError: INVALID_LABEL: The label 'utf-16le' is not a valid encoding
    at getEncoding (bare:/bare.bundle/node_modules/bare-encoding/index.js:72:20)
    at new TextDecoder (bare:/bare.bundle/node_modules/bare-encoding/index.js:38:21)
    at file:///tmp/bear-poc2/node_modules/@exodus/bytes/fallback/utf16.js:32:33
```

## Root cause: bare-encoding is utf-8 only

```js
// bare-encoding/index.js
function getEncoding(label) {
  switch (label.trim().toLowerCase()) {
    case 'utf-8': case 'utf8': case 'unicode11utf8': /* … */
      return 'utf-8'
    default:
      throw errors.INVALID_LABEL(`The label '${label}' is not a valid encoding`)
  }
}
```

jsdom needs `utf-16le`, `latin1`, `windows-1252`, plus WHATWG-Encoding-style
labels like `'unicode-1-1-utf-8'`. Bare ships **only** utf-8.

`bare-node-runtime/global` overrides `globalThis.TextDecoder` /
`globalThis.TextEncoder` with the bare-encoding stubs. So **anything** in
the bundle that does `new TextDecoder(...)` and passes a non-utf-8 label
crashes at first use.

### Why this matters for the upstream NCM API

The jsdom consumer in this codebase is
`module/register_checktoken_v2.js` — it spawns jsdom with
`runScripts: 'dangerously'` and executes the **Watchman SDK** (the
anti-captcha library that computes the `X-antiCheatToken` header). Inside
that JS sandbox, jsdom must expose a complete DOM *and* a full
WHATWG-Encoding implementation, because the SDK touches both.

Three independent paths into `TextDecoder` fail:

1. **Direct**: jsdom's DOM code (HTML parser, URL helpers, …) constructs
   `TextDecoder('utf-16le')` internally. Single throw, no recovery.
2. **`@exodus/bytes` fallback** (jsdom's transitive dep): same root
   cause — when bare isn't recognised as Node, `@exodus/bytes` falls back
   to its pure-JS path, which itself calls `globalThis.TextDecoder` and
   inherits the bare-encoding limit.
3. **`text-encoding` npm package is a no-op**: its `module.exports =
   { TextDecoder: global['TextDecoder'] }` — it just re-exports
   whatever's on the global, which is bare-encoding in our setup. Don't
   bother installing it.

## Workarounds considered (and why each fails)

| Approach | Result |
| --- | --- |
| Override `globalThis.TextDecoder` before bundle starts | Needs a pure-JS implementation that supports utf-8, utf-16le/be, latin1, windows-1252, gb18030, … Equivalent to shipping ~30 KB of ICU tables inside `@exodus/bytes` (already done — but it's the same code that crashes because it *uses* the global TextDecoder). |
| Pin jsdom to an older version (≤24) that doesn't use `@exodus/bytes` | Upstream comment in `register_checktoken_v2.js` explicitly says jsdom is pinned to v24 for that reason. v24 still uses the global TextDecoder for its own DOM code. Same wall. |
| Swap `register_checktoken_v2.js` for a non-jsdom implementation of the Watchman protocol | Effectively rewriting ~150 lines of fragile anti-captcha code. Out of scope. |
| Patch `@exodus/bytes/fallback/utf16.js` to never call `TextDecoder` | The fallback *is* the alternative to calling TextDecoder. There's no further fallback. |
| Wait for `bare-encoding` to grow multi-byte support | Could be months; tracked upstream at https://github.com/holepunchto/bare. Not a path forward for this project. |

## Recommendation

**Don't pursue bare-jsdom any further.** The Workarounds table above
exhausts what's achievable without forking either `bare-encoding` or
`@exodus/bytes`. The remaining path is to keep `node-mobile` for the
embed runtime and reserve `bare` for platforms where it actually adds
value (none currently — bare's only edge is "smaller than node-mobile",
but the upstream NCM dependency tree forces us to pull all the same
code in either case).

If the user wants to revisit bare later, the gap to close is **multi-byte
encoding support in bare-encoding**. Until then, `bear` branch should
stay in the "documented, not implemented" state established by the
earlier commits.

## What still works on bare (without jsdom)

Modules that don't transitively touch jsdom load and run under bare if you
alias the Node builtins the way described above. Concretely:

- `axios`, `tunnel`, `pac-proxy-agent`, `crypto-js`, `xml2js`,
  `qrcode`, `node-forge`, `safe-decode-uri-component` — all CJS, no
  jsdom, all reach `load` and `call` under bare.

But because **any one** call to `crypto: 'xeapi'` reaches
`register_checktoken_v2.js` transitively (it's the source of
`antiCheatTokenV2`), and that module pulls in jsdom, the *entire* bridge
fails the moment a single `xeapi`-mode API is called.

## Files

- PoC scripts: `/tmp/bear-poc2/test-jsdom*.js`
- npm-alias dance captured in `/tmp/bear-poc2/package.json` (not
  committed — re-generated locally each time)
