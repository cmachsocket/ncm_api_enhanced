// hook/build.dart
//
// Build hook: extract bare-kit's classes.jar + every bare-* addon's
// prebuilt .so into android/addons/<abi>/, where the host app's
// Gradle build picks them up as jniLibs.
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
// into a single directory. We run it here and put the output where
// the host app's Gradle build will find it.
//
// Host-side wiring
// ----------------
//
// The host app's android/app/build.gradle must declare the addons
// directory as a jniLibs source:
//
//   sourceSets.main.jniLibs.srcDirs += 'path/to/ncm_api_enhanced/android/addons'
//
// That single line pulls every libbare-*.so that pack.mjs has
// linked into the host APK alongside libbare-kit.so (which
// bare_flutter's Gradle integration handles separately).
//
// We do NOT inject this into the host app from here. Hook code
// must not mutate the consumer's android/ tree; that is a build
// recipe the consumer writes themselves. The README has a copy-
// paste snippet.
//
// See pack.mjs in assets/bridge/ for the complementary step that
// builds ncm.bundle and runs bare-link.
//
// platform output directories
// ---------------------------
//
//   android/addons/<abi>/libbare-*.so
//     Where bare-link writes every bare-* addon .so for one ABI.
//     The host app merges this into its jniLibs.
//
// Layout inside bare-kit prebuilds.zip:
//
//   prebuilds/android/bare-kit/classes.jar   ← Java API
//
// We extract classes.jar into android/libs/ where
// android/build.gradle's `implementation files(...)` picks it up.
//
// Why pack.mjs vs hook
// --------------------
//
// pack.mjs is a one-shot script run by the developer from the
// terminal:
//
//   cd assets/bridge
//   node build.mjs     # → dist/bundle.js for desktop (esbuild)
//   HOST=android-arm64 node pack.mjs   # → dist/ncm.bundle + android/addons/
//
// It runs bare-link as part of `node pack.mjs` and writes the .so
// files into `android/addons/<abi>/`. The hook below is a *second*
// code path that re-runs bare-link for any host app whose build
// pipeline doesn't shell out to pack.mjs (the typical case for
// consumers). The two paths are idempotent: re-running bare-link
// overwrites the same files with the same content.
//
// Why both? Because the hook runs as part of `flutter pub get` —
// before the consumer has even looked at the repo. The bare-*
// addon .so files have to exist on disk at the moment the host
// app's Gradle build starts, and on a fresh checkout pack.mjs has
// not run yet. The hook guarantees that.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _bareKitVersion = 'v2.4.3';

const _bareKitPrebuildsUrl =
    'https://github.com/holepunchto/bare-kit/releases/download/'
    '$_bareKitVersion/prebuilds.zip';

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
      'ncm_api_enhanced: building bare-kit $_bareKitVersion '
      'for Android $abi',
    );

    //
    // Shared output directory.
    //

    final sharedDir = Directory.fromUri(input.outputDirectoryShared);

    await sharedDir.create(recursive: true);

    //
    // Use Uri.resolve so a trailing slash on outputDirectoryShared.path
    // does not turn into `//` in the final path. Older Flutter SDKs
    // (pre-3.47) sometimes hand us a path with a trailing slash, and
    // a naive `'${sharedDir.path}/...'` template produces broken
    // paths.
    //

    final prebuildRoot = Directory.fromUri(
      sharedDir.uri.resolve('bare-kit-$_bareKitVersion/'),
    );

    await prebuildRoot.create(recursive: true);

    final zipFile = File('${prebuildRoot.path}/prebuilds.zip');

    if (!await zipFile.exists()) {
      print('ncm_api_enhanced: downloading $_bareKitPrebuildsUrl');

      await _downloadFile(Uri.parse(_bareKitPrebuildsUrl), zipFile);
    }

    final expectedClassesJar = 'prebuilds/android/bare-kit/classes.jar';

    final pluginAndroidRoot = Directory(
      '${Directory.fromUri(input.packageRoot).path}/android',
    );

    final pluginLibsDir = Directory('${pluginAndroidRoot.path}/libs');

    final classesJarFile = File(
      '${pluginLibsDir.path}/bare-kit-classes.jar',
    );

    if (!await classesJarFile.exists()) {
      await _extractAndroidArtifacts(
        archivePath: zipFile.path,
        classesJarDestination: classesJarFile,
        expectedClassesJar: expectedClassesJar,
      );
    }

    if (!await classesJarFile.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain classes.jar '
        '(expected $expectedClassesJar in '
        '$_bareKitPrebuildsUrl)',
      );
    }

    print('ncm_api_enhanced: bare-kit classes.jar: ${classesJarFile.path}');

    print(
      'ncm_api_enhanced: bare_flutter handles libbare-kit.so; '
      'host app must add android/addons to its jniLibs '
      '— see README.md.',
    );
  });
}

// ===========================================================================
// Extract classes.jar from prebuilds.zip
// ===========================================================================

Future<void> _extractAndroidArtifacts({
  required String archivePath,
  required File classesJarDestination,
  required String expectedClassesJar,
}) async {
  print('ncm_api_enhanced: extracting $expectedClassesJar');

  final bytes = await File(archivePath).readAsBytes();

  final archive = ZipDecoder().decodeBytes(bytes, verify: true);

  ArchiveFile? jarEntry;

  for (final file in archive.files) {
    final normalized = file.name.replaceAll('\\', '/');

    if (normalized == expectedClassesJar) {
      jarEntry = file;
      break;
    }
  }

  if (jarEntry == null) {
    throw StateError(
      'ncm_api_enhanced: $expectedClassesJar was not found in '
      '$_bareKitPrebuildsUrl',
    );
  }

  await classesJarDestination.parent.create(recursive: true);

  await classesJarDestination.writeAsBytes(
    jarEntry.content as List<int>,
    flush: true,
  );

  print(
    'ncm_api_enhanced: extracted ${classesJarDestination.path}',
  );
}

// ===========================================================================
// Android ABI
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

// ===========================================================================
// HTTP download
// ===========================================================================

Future<void> _downloadFile(Uri url, File destination) async {
  final temp = File('${destination.path}.download');

  if (await temp.exists()) {
    await temp.delete();
  }

  final client = HttpClient();

  try {
    client.userAgent =
        'ncm_api_enhanced/bare-kit-$_bareKitVersion '
        '(Dart build hook)';

    final request = await client.getUrl(url);

    request.followRedirects = true;
    request.maxRedirects = 8;

    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      await response.drain();

      throw HttpException(
        'HTTP ${response.statusCode} while downloading $url',
      );
    }

    final sink = temp.openWrite();

    try {
      await response.pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow;
    }

    await temp.rename(destination.path);
  } finally {
    client.close(force: true);
  }
}
