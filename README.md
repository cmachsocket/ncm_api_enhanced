# ncm_api_enhanced

Unofficial Netease Cloud Music API as a Flutter package. Embeds
nodejs-mobile v18.20.4 (libnode.so on Android, NodeMobile.xcframework on
iOS) and exposes the upstream `@neteasecloudmusicapienhanced/api`
package's **439 module functions** as a Dart facade.

| Platform | Mechanism |
| --- | --- |
| Linux / macOS / Windows | Spawns the system `node` binary via `dart:io` `Process.start`. The upstream module is loaded directly via `require()`. |
| Android | Embeds `libnode.so` via a JNI bridge (`libncm_node_bridge.so`). `libnode.so` is downloaded by the Dart build hook (`hook/build.dart`) from the [nodejs-mobile v18.20.4 release](https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4). |
| iOS | Embeds `NodeMobile.xcframework`. The framework is added by `tool/patch_ios_pbxproj.rb` (or manually in Xcode). |

## Install

```yaml
dependencies:
  ncm_api_enhanced: ^0.1.0
```

Then:

```sh
flutter pub get
```

On the first build, `hook/build.dart` downloads `libnode.so` for Android.
On iOS, run `tool/patch_ios_pbxproj.rb path/to/NodeMobile.xcframework`
once (or add the framework manually).

## Usage

```dart
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

final api = NcmApi();
await api.start();

final album = await api.album({'id': 12345});
print(album['body']); // upstream NCM response shape

// Or call dynamically:
final r = await api.call('userAccount');
print(r['body']['profile']);

await api.shutdown();
```

### Concurrency

All 439 upstream module functions are async I/O. Issuing multiple
`api.xxx()` calls without awaiting them runs them concurrently on the
node event loop; results are matched by request id. There is no worker
pool — node handles parallelism natively.

### Error semantics

Upstream business errors (e.g. `body.code == 502` on bad login) come
back as **resolved** maps. Only bridge/IPC failures (process crash,
timeout, malformed JSON) throw.

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│ Flutter app (Dart)                                                  │
│   api.album(id: 12345)                                              │
│        │                                                           │
│        ▼  (noSuchMethod → NcmApi._bridge.call('album', {...}))    │
│   DesktopNcmBridge / MobileNcmBridge                               │
│        │  NDJSON over stdin/stdout (desktop)                      │
│        │  MethodChannel + EventChannel (mobile)                    │
└────────┼───────────────────────────────────────────────────────────┘
         ▼
┌────────────────────────────────────────────────────────────────────┐
│ Node process                                                        │
│   bridge.js (bundled in this package as a Flutter asset)          │
│        │  require('@neteasecloudmusicapienhanced/api')            │
│        ▼                                                           │
│   Upstream module function — pure async, returns Promise<Response> │
│        │  axios → music.163.com                                    │
└────────────────────────────────────────────────────────────────────┘
```

`bridge.js` lives at `bridge/bridge.js` in this package and is
packaged as a Flutter asset (`flutter.assets:`). On Android/iOS the
native plugin copies it out of the asset bundle to a writable
directory and runs node from there.

## Why two pieces (`tool/refresh_bridge.sh` + `hook/build.dart`)?

The Dart hooks system can only ship **single-file** native code
assets (`CodeAsset`). It cannot ship a 65 MB JS dependency tree.
That means upstream `@neteasecloudmusicapienhanced/api` and its
transitive deps can't be downloaded at consumer build time the way
libnode.so can — there's no Dart protocol that says "here's a
directory of JS files, copy it into the asset bundle".

So we split responsibilities cleanly:

| Piece | When it runs | What it does | Cached? |
| --- | --- | --- | --- |
| `tool/refresh_bridge.sh` | Once per release, by the package author | Downloads upstream NCM npm + `cp -rL` into `bridge/node_modules/`, prunes `@unblockneteasemusic` (which contains private keys and isn't used at runtime) | Committed to git |
| `hook/build.dart` | Once per consumer build, by the Dart SDK | Downloads libnode.so for the target Android ABI, extracts the right `.so`, copies to `android/src/main/jniLibs/<abi>/`, emits a `CodeAsset` for it | `~/.cache/ncm_api_enhanced/` (global) |

After `refresh_bridge.sh`, you also need to:

```sh
cd bridge
node scripts/generate_api.mjs   # regenerate the wrapper if module fns changed
node build.mjs                  # bundle → dist/bundle.js
git add bridge/
git commit -m "refresh upstream NCM bundle"
```

`build.mjs` applies several esbuild `onLoad` patches that the upstream
package needs to work inside Android's sandbox (no `/tmp`, no
`generateConfig.js` in the bundle graph). See
[`bridge/README.md`](assets/bridge/README.md) for the full rationale.

**Result**: consumer-side `flutter pub get` is fully
self-contained — no npm, no extra steps, no network at runtime.

If the package author bumps `@neteasecloudmusicapienhanced/api`
upstream, they run:

```
cd packages/ncm_api_enhanced
tool/refresh_bridge.sh
git add bridge/
git commit -m "refresh upstream NCM node_modules"
```

before cutting a new release.

## Testing

```sh
flutter pub get
flutter test test/
```

The smoke test suite covers:

1. Bridge protocol (NDJSON over stdin/stdout) end-to-end against a
   local `node` process.
2. Hook round-trip — verifies the hook downloads libnode.so for all
   three Android ABIs and emits a valid `CodeAsset`.
3. The hook is a no-op on iOS/desktop.
4. Unsupported architectures throw.

## License

MIT. The upstream `@neteasecloudmusicapienhanced/api` is also MIT;
see its `LICENSE` after running `tool/copy_bridge.sh`.