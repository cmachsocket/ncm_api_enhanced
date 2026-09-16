// hook/build.dart
//
// Build hook: at `flutter pub get` time, run `bare-link` against
// every bare-* addon reachable from the bridge module graph and
// copy the prebuilt .so files into android/addons/<abi>/. The
// Android plugin module (android/build.gradle) then packages those
// .so files into jars AGP auto-extracts into the APK's jniLibs.
//
// Why this hook exists
// --------------------
//
// The bare_flutter plugin (https://pub.dev/packages/bare_flutter) takes
// care of three things for us:
//
//   1. Downloading libbare-kit.so into the host APK at build time.
//   2. Providing the to.holepunch.bare.kit.* Java API on the runtime
//      classpath.
//   3. Exposing a MethodChannel + BasicMessageChannel that lets Dart
//      spin up Worklets and stream bytes to them.
//
// What bare_flutter does NOT do is link the 100+ `bare-*` addons
// (bare-type, bare-fs, bare-crypto, bare-os, bare-stdio, …) that
// the bridge bundle reaches via `require.addon()`. The bridge
// uses these addons heavily — jsdom, axios, pngjs, etc. all
// transitively require them. bare-pack writes `linked:lib<name>.<ver>.so`
// specifiers into the bundle, and at Worklet runtime each of those
// resolves to a `System.loadLibrary("<name>")` call. If the .so
// is not in the host APK's `lib/<abi>/`, Worklet startup dies with
// ADDON_NOT_FOUND.
//
// bare-link is the upstream helper that walks every bare-* addon
// in the bridge module graph and writes their prebuilt .so files
// into a single directory. We invoke it from here so that the
// prebuilt files exist on disk before the host app's first Gradle
// build runs.
//
// After this hook runs, android/addons/<abi>/lib<name>.<version>.so
// is on disk for every supported ABI. The plugin module's
// downloadAndPackageAddons Gradle task then re-runs bare-link at
// build time (for environments where flutter pub get was skipped)
// and packages the .so files into AGP-compatible jars.
//
// Why this hook runs `bare-link` even though the Gradle task does
// -----------------------------------------------------------------
//
// `flutter pub get` happens once per dependency change; subsequent
// `flutter build apk` runs do not re-run hooks. By writing the
// addon .so files in the hook, every developer who runs
// `flutter pub get` on a fresh checkout ends up with a complete
// android/addons/ tree. If the developer later deletes the tree
// (e.g. `git clean -fdx`) the Gradle task regenerates it.
//
// We invoke bare-link by spawning node with the bare-link CLI that
// ships inside assets/bridge/node_modules/.bin. assets/bridge/ is
// always present because it's part of this package's pubspec
// assets. The script path is resolved relative to this hook's
// `packageRoot`.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _androidAbis = <String, String>{
  'arm64-v8a': 'android-arm64',
  'armeabi-v7a': 'android-arm',
  'x86_64': 'android-x64',
  'x86': 'android-ia32',
};

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final config = input.config.code;

    if (config.targetOS != OS.android) {
      return;
    }

    final abi = _androidAbi(config.targetArchitecture);

    if (abi == null) {
      throw UnsupportedError(
        'ncm_api_enhanced: unsupported Android architecture: '
        '${config.targetArchitecture}',
      );
    }

    print(
      'ncm_api_enhanced: preparing bare-kit + bare-* addons '
      'for Android $abi',
    );

    //
    // Locate the bridge source directory. This hook lives at
    // <packageRoot>/hook/build.dart; assets/bridge/ sits at
    // <packageRoot>/assets/bridge/. We rely on packageRoot being
    // a file URI we can resolve.
    //

    final packageRoot = Directory.fromUri(input.packageRoot);

    final bridgeDir = Directory('${packageRoot.path}/assets/bridge');

    if (!await bridgeDir.exists()) {
      throw StateError(
        'ncm_api_enhanced: bridge source directory not found at '
        '${bridgeDir.path}. The flutter pub get that triggered this '
        'hook may have run in a stripped checkout.',
      );
    }

    //
    // Run bare-link for every Android ABI so that
    // android/addons/<abi>/lib<name>.<version>.so exists on disk
    // before any developer runs `flutter build apk`. The plugin
    // module's Gradle task (downloadAndPackageAddons in
    // android/build.gradle) will re-run bare-link at build time if
    // a developer runs `git clean` between `flutter pub get` and
    // `flutter build apk`, but the typical flow relies on this hook
    // having populated the tree.
    //
    // We do NOT download libbare-kit.so or classes.jar here.
    // bare_flutter (https://pub.dev/packages/bare_flutter) takes care
    // of both — its Gradle integration downloads
    // `bare-kit-v2.4.3-prebuilds.zip` and exposes libbare-kit.so +
    // classes.jar through its own plugin module's jniLibs + jar
    // dependencies. We only fill the gap that bare_flutter leaves:
    // the 100+ `bare-*` addon .so files.
    //

    final pluginAndroidRoot =
        Directory('${packageRoot.path}/android');

    for (final entry in _androidAbis.entries) {
      final abi = entry.key;
      final host = entry.value;

      await _runBareLink(
        bridgeDir: bridgeDir,
        pluginAndroidRoot: pluginAndroidRoot,
        abi: abi,
        host: host,
      );
    }
  });
}

// ===========================================================================
// Run bare-link via the Node CLI bundled inside assets/bridge/node_modules
// ===========================================================================

Future<void> _runBareLink({
  required Directory bridgeDir,
  required Directory pluginAndroidRoot,
  required String abi,
  required String host,
}) async {
  final addonsDir = Directory('${pluginAndroidRoot.path}/addons/$abi');
  await addonsDir.create(recursive: true);

  //
  // bare-link is per-package: it takes a single package root and
  // walks the bare-* addons reachable from it. We enumerate every
  // bare-* package under bridgeDir/node_modules/ and call bare-link
  // once per package. Each call writes the package's prebuild .so
  // (and any embedded .dex / .jar) into <out>/<abi>/.
  //
  // We invoke bare-link via its CLI shim under
  // assets/bridge/node_modules/.bin/bare-link, which is the package
  // npm-installed by the bridge dev dependencies (see
  // assets/bridge/package.json devDependencies). The CLI takes:
  //
  //   bare-link <addon-path>
  //              --host android-<arch>
  //              --out  <out-dir>
  //              --needs libbare-kit.so
  //
  // We use the bridge directory as the addon base path so the
  // module walk starts from a real package root. bare-link then
  // emits every bare-* prebuild it finds into <out-dir>/<arch>/.
  //

  final bareLinkBin = File(
    '${bridgeDir.path}/node_modules/.bin/bare-link',
  );

  if (!await bareLinkBin.exists()) {
    print(
      'ncm_api_enhanced: bare-link not found at '
      '${bareLinkBin.path}; skipping addon download for $abi. '
      'Run "npm install" inside assets/bridge/ to install dev '
      'dependencies, or rely on the Gradle task '
      '(downloadAndPackageAddons) to do the work at build time.',
    );
    return;
  }

  print('ncm_api_enhanced: bare-link host=$host -> ${addonsDir.path}');

  final result = await Process.run(
    'node',
    [
      bareLinkBin.path,
      bridgeDir.path,
      '--host', host,
      '--out', addonsDir.path,
      '--needs', 'libbare-kit.so',
    ],
    workingDirectory: bridgeDir.path,
  );

  if (result.exitCode != 0) {
    print(
      'ncm_api_enhanced: bare-link FAILED for $abi '
      '(exit=${result.exitCode})',
    );
    print(result.stdout);
    print(result.stderr);
    throw StateError(
      'ncm_api_enhanced: bare-link failed for ABI $abi; see logs above',
    );
  }

  print(
    'ncm_api_enhanced: bare-link finished for $abi '
    '(${result.stdout.split("\n").length} lines of output)',
  );
}

// ===========================================================================
// Android ABI mapping
// ===========================================================================

String? _androidAbi(Architecture architecture) {
  switch (architecture) {
    case Architecture.arm64:
      return 'arm64-v8a';

    case Architecture.arm:
      return 'armeabi-v7a';

    case Architecture.x64:
      return 'x86_64';

    default:
      return null;
  }
}

