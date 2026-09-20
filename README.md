# ncm_api_enhanced

Unofficial [Netease Cloud Music API](https://github.com/Binaryify/NeteaseCloudMusicApi) as a Flutter package.
Embeds Node.js **v26.9.0** via [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) (custom
build at [`cmachsocket/node`](https://github.com/cmachsocket/node)) and exposes **438 upstream
module functions** of `@neteasecloudmusicapienhanced/api` behind a single typed dispatch.

```dart
final api = NcmApi();
await api.start();

final album = await api.call('album', {'id': 12345});
print(album['body']);          // upstream NCM response shape

final me = await api.call('user_account');
print(me['body']['profile']);

await api.shutdown();
```

| Platform | Runtime | Bridge transport |
| --- | --- | --- |
| Linux / macOS | System `node` (≥18) spawned via `Process.start` | NDJSON over stdin/stdout |
| Windows | Embedded `node.exe` (Node 26.8.2) shipped as a Flutter asset | NDJSON over stdin/stdout |
| Android | Embedded `libnode.so` loaded by native FFI | `dart:ffi` → `libncm_node_bridge.so` ↔ pipes |
| iOS | **Not implemented in this version.** See [iOS status](#ios-status) | — |

## Install

```yaml
dependencies:
  ncm_api_enhanced: ^0.1.0
```

Then:

```sh
flutter pub get
flutter build apk          # or `flutter run`
```

On Android, the first build runs `hook/build.dart`, which:

1. Downloads `libnode.so` for your target ABI from
   [`cmachsocket/node v26.9.0`](https://github.com/cmachsocket/node/releases/tag/v26.9.0).
2. Downloads `libcpufeatures.so` (same release).
3. Compiles `native/android/node_bridge.cpp` into `libncm_node_bridge.so` using the
   NDK clang that the Flutter SDK ships with.
4. Registers both `.so` files as `CodeAsset`s so Gradle packages them into
   `<apk>/lib/<abi>/`.

Cached under `~/.cache/ncm_api_enhanced/`; subsequent builds skip the downloads.

## Usage

All 438 upstream functions are reachable through the single typed method
`api.call(method, [params])`. The method name is the upstream module filename
stem (`album`, `user_account`, `login_qr_create`, `song_url`, …).

```dart
final banner = await api.call('banner');
final me     = await api.call('user_account');
final qr     = await api.call('login_qr_create', {'type': 1});
final key    = qr['body']['data']['qrcode'] as String;
final check  = await api.call('login_qr_check', {'key': key, 'qrimg': true});
```

### Parameter shapes follow the upstream HTTP API

The `params` map is the same shape you'd POST to the corresponding NCM HTTP
endpoint. A few common ones:

| Method | Required / common params |
| --- | --- |
| `album` | `id` (album id) |
| `song_url` | `id`, `br` (bitrate, e.g. 999000) |
| `lyric` | `id` |
| `search` | `keywords`, `type` (1=song, 10=album, …), `limit`, `offset` |
| `login_qr_create` | `type` (1=mobile web, etc.), optional `qrimg` |
| `login_qr_check` | `key` (from `login_qr_create`), `qrimg` |

The full list of 438 module filenames is generated at build time from the
upstream npm package — see `bridge/dist/bundle.js` for the canonical names.

`api.call` validates the method name against the upstream whitelist and
throws `ArgumentError` before any IPC if the name is wrong — so a typo fails
fast instead of hitting node's "unknown method" path.

### Method-style is also available (untyped)

`NcmApi` overrides `noSuchMethod`, so `api.album({'id': 12345})` and similar
work at *runtime* — the method name is forwarded to `api.call` behind the
scenes. **The Dart analyzer cannot see these methods**, so the IDE will flag
them as errors and the static type system offers no help:

```dart
// Runtime-only. The Dart analyzer will mark this as "method not defined"
// even though noSuchMethod dispatches it to api.call('album', ...).
final r = await api.album({'id': 12345});
```

Prefer `api.call(...)` unless you really want shorter call sites and are OK
working without analyzer support.

### Concurrency

All 438 upstream functions are pure async I/O (axios). Issuing N calls without
awaiting them runs them concurrently on node's event loop; responses are matched
by request id. There is no Dart-side worker pool — node handles parallelism
natively.

### Error semantics

| What | What you get |
| --- | --- |
| Unknown method name (typo) | `ArgumentError` thrown synchronously from `api.call` |
| Upstream business error (e.g. `body.code == 502` on bad login) | **Resolved** map with the upstream `body` |
| Timeout (`kDefaultCallTimeout = 30s`) | `TimeoutException` |
| Bridge/IPC failure (process crash, malformed JSON, dlopen failure) | `BridgeError` |
| Upstream rejects with a non-`Error` value (e.g. `{status: 502}`) | `BridgeError` whose `message` is the JSON-stringified rejection |

You don't need to wrap happy-path calls in `try`. You do need to wrap calls if
you care about distinguishing "API returned an error" from "the bridge died".

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│ Flutter app (Dart)                                             │
│   api.album({'id': 12345})                                    │
│      │                                                        │
│      ▼  noSuchMethod → _bridge.call('album', {...})           │
│   DesktopNcmBridge (NDJSON over stdin/stdout)                  │
│        or                                                     │
│   MobileNcmBridge (dart:ffi → libncm_node_bridge.so ↔ pipes)   │
└─────────────┬─────────────────────────────────────────────────┘
              │ JSON: {"id":N,"method":"album","params":{...}}\n
              ▼
┌───────────────────────────────────────────────────────────────┐
│ Node process / embedded libnode.so                            │
│   bridge.js (NDJSON-line reader on stdin)                     │
│      │  require('./generated_api') — bundled by esbuild      │
│      ▼                                                        │
│   generated_api wraps 438 upstream module fns                  │
│      │  axios → music.163.com                                 │
│      ▼                                                        │
│   stdout: {"id":N,"ok":true,"result":{...}}\n                 │
└───────────────────────────────────────────────────────────────┘
```

The full Node-side implementation ships as a single esbuild bundle:
`assets/bridge/dist/bundle.js` (~11 MB). `bridge.js` (the NDJSON dispatcher)
is the entry point and sits next to it as `assets/bridge/bridge.js`. Both are
declared as Flutter assets in `pubspec.yaml`.

## Build-time assets

| Asset | Source | Shipped by | Cached? |
| --- | --- | --- | --- |
| `bridge.js` + `dist/bundle.js` | This repo (`assets/bridge/`) | Flutter `assets:` declaration | Committed to git |
| `libnode.so` (Android) | [`cmachsocket/node v26.9.0`](https://github.com/cmachsocket/node/releases/tag/v26.9.0) | `hook/build.dart` | `~/.cache/ncm_api_enhanced/` |
| `libcpufeatures.so` (Android) | Same release, separate asset | `hook/build.dart` | Same cache |
| `node.exe` (Windows, x64 + arm64) | This repo (`assets/runtime/win-*/`) | Flutter `assets:` declaration | Committed to git |

### Why `libcpufeatures.so`?

`libnode.so` imports `android_getCpuFeatures()`, but Bionic libc on Android
doesn't export it — NDK only ships the symbol inside the static
`libcpufeatures.a`. Without a bundled `libcpufeatures.so`, `dlopen(libnode.so)`
fails at runtime with:

```
cannot locate symbol "android_getCpuFeatures"
```

We ship a tiny stub `.so` (4 KB) per ABI that returns 0 from
`android_getCpuFeatures()`. V8 only consults the value to pick CPU-specialized
code paths; a 0 return is safe and triggers portable fallbacks.

### ABI coverage

Each `cmachsocket/node v26.9.0` release tag carries **one** `libcpufeatures.so`
matching the ABI of the `libnode.so` on the same tag. We publish per-ABI; an
arm64-v8a tag fixes dlopen only on arm64 devices. To ship for `armeabi-v7a` or
`x86_64`, cut additional tags built with
[`tools/build_libcpufeatures.sh`](../../node/tools/build_libcpufeatures.sh)
on the node fork.

## iOS status

iOS support is **not implemented in this version.** The package's pubspec
declares `flutter.plugin.platforms.ios: NcmNodeBridge` and the Swift /
Objective-C++ wrappers at `ios/Classes/` are present, but the Dart-side
`MobileNcmBridge` only opens `libncm_node_bridge.so` via `dart:ffi` — it does
not communicate with the Swift plugin over `MethodChannel` / `EventChannel`.
Calling `NcmApi()` on iOS fails immediately at `_loadNative()` with
`ArgumentError: Failed to load dynamic library 'libncm_node_bridge.so'`.

To enable iOS, either (a) port `MobileNcmBridge` to use `MethodChannel` to
delegate to `NcmNodePlugin.swift`, or (b) drop the plugin and FFI-dlopen
`NodeMobile.framework` directly. Tracked in repo issues.

## Tests

```sh
flutter pub get
flutter test test/
```

| Test | Covers |
| --- | --- |
| `test/bridge_smoke_test.dart` | NDJSON bridge protocol end-to-end against a local `node` process (5 concurrent `banner` calls, unknown-method rejection). Requires `NCM_BRIDGE_ROOT=$PWD/bridge` to be set. |
| `test/hook_test.dart` | Hook behavior per ABI: emits a valid `CodeAsset` for both `libnode.so` and `libcpufeatures.so`; no-op on iOS / desktop; throws on unsupported architectures. Uses the official `hooks+code_assets` test harness, no device required. |

## Release procedure (package author)

When `@neteasecloudmusicapienhanced/api` updates upstream:

```sh
cd packages/ncm_api_enhanced
tool/refresh_bridge.sh        # downloads upstream + cp -rL into bridge/node_modules/
cd bridge
node scripts/generate_api.mjs # regenerate wrapper if module fns changed
node build.mjs                # bundle → dist/bundle.js
cd ..
git add bridge/
git commit -m "refresh upstream NCM bundle"
```

`build.mjs` applies esbuild `onLoad` patches the upstream package needs to
work inside Android's sandbox (no `/tmp`, no `generateConfig.js` in the bundle
graph). See [`bridge/README.md`](assets/bridge/README.md) for the rationale.

## License

MIT. The upstream `@neteasecloudmusicapienhanced/api` is also MIT; see
its `LICENSE` after running `tool/refresh_bridge.sh`.