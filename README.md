# ncm_api_enhanced

Unofficial Netease Cloud Music API as a Flutter package. Embeds a
[Bare](https://github.com/holepunchto/bare) runtime on Android and iOS via
[`bare_flutter`](https://pub.dev/packages/bare_flutter), and exposes the
upstream `@neteasecloudmusicapienhanced/api` package's 439 module
functions as a Dart facade.

| Platform | Mechanism |
| --- | --- |
| Linux / macOS / Windows | Spawns the system `node` binary via `dart:io` `Process.start`. The upstream module is loaded directly via `require()`. |
| Android | `bare_flutter` plugin hosts a Bare Worklet; the bundle ships as a Flutter asset (`assets/bridge/dist/ncm.bundle`) and the Dart side talks to it over `BasicMessageChannel`. `libbare-kit.so` is downloaded by `bare_flutter`'s Gradle integration; the 100+ `bare-*` addon .so files come from `assets/bridge/pack.mjs` running `bare-link` against the bridge module graph. |
| iOS | Same as Android via `bare_flutter`. |

## Install

```yaml
dependencies:
  ncm_api_enhanced: ^0.1.0
```

Then:

```sh
flutter pub get
```

## Building the bridge bundle

Before the host app can build the Android / iOS targets, run the
following from the package root to refresh the bundled JS:

```sh
cd assets/bridge
HOST=android-arm64 node pack.mjs    # produces dist/ncm.bundle + android/addons/
node build.mjs                       # produces dist/bundle.js for desktop
```

`pack.mjs` is the step that writes every `bare-*` addon's prebuilt
`.so` into `android/addons/<abi>/`. The host app's `android/app/build.gradle`
must then declare that directory as a jniLibs source (see "Host app
Gradle wiring" below).

`build.mjs` runs esbuild over the bridge and produces a 12 MB self-
contained `dist/bundle.js` that the desktop bridge spawns with the
system `node` binary.

## Host app Gradle wiring

Edit `android/app/build.gradle` in the host Flutter app:

```groovy
android {
    sourceSets.main.jniLibs.srcDirs += '<path>/ncm_api_enhanced/android/addons'
}
```

`<path>` is the resolved filesystem location of the
`ncm_api_enhanced` package (e.g. `~/.pub-cache/hosted/pub.dev/ncm_api_enhanced-x.y.z`
or `path/to/myapp/.dart_tool/package_config.json`-derived). The host
app's Gradle build bundles every `lib<name>.<version>.so` from that
directory into the APK at `lib/<abi>/`.

`bare_flutter` separately downloads `libbare-kit.so` itself; the
`addons/` directory does **not** contain that file (and must not —
it would collide with `bare_flutter`'s own wiring).

## Wire protocol

NDJSON over the IPC byte stream. On every platform the bridge emits
one JSON object per line:

```
{"id": <int>, "method": "<moduleFn>", "params": {...}}   # request
{"id": <int>, "ok": true,  "result": {...}}               # success
{"id": <int>, "ok": false, "error": {"message": ...}}     # failure
{"event": "ready" | "log" | "fatal", "data": ...}        # event
```

`bridge.js` is the same source for every platform; the I/O source
switches at runtime:

- desktop / esbuild: `process.stdin` / `process.stdout` / `process.stderr`
- bare Worklet: `Bare.IPC` (the global duplex injected by `bare-kit`)

## Verifying all 439 fns are reachable

```dart
final bridge = NcmBridgeFactory.create();
await bridge.start();
final fns = await bridge.call('api', {});
print(fns['result']['total']);   // → 439
```

## License

MIT. Upstream `@neteasecloudmusicapienhanced/api` is also MIT.
