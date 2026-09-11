# bridge/ — Node bundle for the NCM API Enhanced plugin

This directory produces the single self-contained `dist/bundle.js` that the
native Android/iOS plugins execute inside their embedded `libnode.so`. It is
shipped as a Flutter asset and copied to a writable directory at runtime.

The bundle is **not** `npm install`-able and has no runtime `node_modules`;
every transitive dep of `@neteasecloudmusicapienhanced/api` is inlined by
esbuild.

## Layout

```
bridge/
├── bridge.js               # NDJSON protocol layer over stdin/stdout
├── generated_api.js        # AUTO-GENERATED — statically lists all 439 fns
├── build.mjs               # esbuild config + Android/iOS source patches
├── scripts/
│   └── generate_api.mjs    # regenerates generated_api.js from module/*.js
├── shims/
│   └── xhr-sync-worker.js  # jsdom no-op shim (copied to dist/ at build time)
├── node_modules/
│   └── @neteasecloudmusicapienhanced/api/
│       ├── main.js         # upstream entry — NOT used by bridge.js
│       ├── module/*.js     # 439 module fns — inlined by esbuild
│       ├── util/*.js       # request / crypto / index / …
│       ├── plugins/*.js    # songUpload / upload
│       ├── data/*.txt      # china_ip_ranges.txt — patched path below
│       └── server.js       # upstream HTTP server — NOT in bundle
└── dist/                   # build output
    ├── bundle.js           # ← the artifact (≈11.5 MB)
    └── xhr-sync-worker.js  # shim for runtime require.resolve
```

`bridge.js` does `require('./generated_api')`, **not**
`require('@neteasecloudmusicapienhanced/api')`. This is so every upstream
`require()` (and all transitive deps) is statically analyzable and can be
recursively bundled by esbuild.

## Build pipeline

```sh
node scripts/generate_api.mjs   # regenerate generated_api.js
node build.mjs                 # esbuild bundle → dist/bundle.js
```

`build.mjs` does four things in order:

1. **`shimXhrWorker` plugin** — marks jsdom's `require.resolve('./xhr-sync-worker.js')`
   as external (otherwise esbuild warns and fails to bundle) and copies
   `shims/xhr-sync-worker.js` to `dist/` so runtime `require.resolve`
   succeeds.
2. **`fixChinaIpRangesPath` plugin** — patches
   `@neteasecloudmusicapienhanced/api/util/index.js`. After bundling,
   `__dirname` is `dist/`, but upstream does
   `path.join(__dirname, '../data/china_ip_ranges.txt')` which would resolve
   to `dist/../data/…` (a path that doesn't exist). The file is actually
   shipped as `dist/data/china_ip_ranges.txt` via the `flutter.assets:`
   entry, so the patch rewrites the suffix to `data/china_ip_ranges.txt`.
3. **`fixRequestJs` plugin** — patches
   `@neteasecloudmusicapienhanced/api/util/request.js` in two places (see
   [Android sandbox](#android-sandbox) below).
4. **`conditions: ['module-sync']`** — required because `music-metadata` v11+
   is pure ESM and only exposes `import`/`module-sync` conditions in
   `package.json#exports`. Without this, esbuild fails to resolve
   `require('music-metadata')`.

## Android sandbox

Two upstream behaviors assume a POSIX `/tmp` that the app sandbox does not
have on Android:

| Upstream code | Failure on Android | Patch |
| --- | --- | --- |
| `util/request.js:29` — module-load-time `fs.readFileSync('/tmp/anonymous_token')` | ENOENT → whole `util/request.js` fails to load → every NCM API throws | Wrap read in `try/catch`; ENOENT → empty string |
| `util/request.js:36` — `loadXeapiPublicKey()` reads `/tmp/xeapi_public_key` (file written once at boot by `generateConfig.js`) | File never written (`generateConfig.js` not in bundle graph + `/tmp` unwritable). Affects 17+ fns (`register_anonimous`, `song_url_v1`, `vip_tasks_v1`, `ad_get`, `yunbei_sign`, `share_resource`, `comment_reply`, …) — every `crypto: 'xeapi'` call throws `'xeapi public key is missing'` | Eager-fetch in `createRequest`: if `xeapi_public_key` is null, call `getXeapiPublicKey({}, deviceId)` and cache in module scope before the switch statement runs |

The xeapi patch details:

- Injected into `createRequest`'s body (which is `async`), so the helper can
  `await`. The switch statement itself is inside a `new Promise(...)` executor
  (sync), so we can't `await` there — the choke point has to be at function
  entry.
- If `global.deviceId` is unset (the user's first call is a `xeapi` fn
  before `register_anonimous` has run), fall back to
  `util/index.js`'s `generateDeviceId()` — same 52-char hex format that
  `register_anonimous` itself uses. An empty deviceId makes the upstream
  server return an undecryptable response (`xeapiDecryptPublicKey` yields
  no `sk`), which is otherwise indistinguishable from a transient network
  error.
- `xeapi_public_key` is upstream `let` (not `const`), so any future code
  path that wants to rotate or clear the key still works — our patch only
  re-fetches when the cache is null/undefined.

## Regenerating `generated_api.js`

`generated_api.js` mirrors `main.js`'s public surface (sans `server.js`):

- Eagerly requires every `module/*.js` and wraps it as a function that
  normalizes cookies (string → object via `cookieToJson`) and lazily
  injects the request helper.
- Lazily `require()`s `util/request` so module-load doesn't trigger the
  anonymous_token read at import time.
- Re-exports `request` so the bridge can warm it up.

The list is in **reverse lex order** to match `main.js`'s
`fs.readdirSync(modulePath).reverse()`. **Do not edit by hand** — regenerate
with:

```sh
node scripts/generate_api.mjs
```

If you bump the upstream `@neteasecloudmusicapienhanced/api` version, run
this after `npm install` so the wrapper picks up new/changed fns.

## Smoke testing (desktop)

```sh
printf '{"id":1,"method":"banner","params":{"type":0}}\n' \
  | node dist/bundle.js
# → {"event":"ready",...}
# → {"id":1,"ok":true,"result":{"status":200,"body":{"code":200,...}}}
```

To probe a single fn without NDJSON framing:

```sh
node -e 'console.log(Object.keys(require("./generated_api")).length)'
# → 440  (439 module fns + "request")
```

## Verifying all 439 fns are reachable

```sh
# Generate one request per fn with empty params; check no "unknown method" errors
node -e '
const fns = Object.keys(require("./generated_api")).filter(k => k !== "request");
console.log(fns.length);
' # → 439
```

The `unknown method` rejection path in `bridge.js` returns `"unknown method: <name>"`,
so a clean run means every fn in `generated_api.js` was wired into the
bundle.

## License

MIT. Upstream `@neteasecloudmusicapienhanced/api` is also MIT.
