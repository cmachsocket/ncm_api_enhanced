// hook/build.dart
//
// Build hook for Android: bundle the bare-kit prebuild into the host
// Flutter app so that libbare-kit.so (the libbare-kit.so from
// holepunchto/bare-kit) is shipped alongside the plugin module's
// classes.jar.
//
// Architecture:
//
//   Dart (mobile_bridge.dart)
//       ↕ MethodChannel('ncm_bridge') + EventChannel
//   Kotlin  (android/src/main/kotlin/.../NcmBareBridge.kt)
//       ↕
//   to.holepunch.bare.kit.Worklet + IPC  (Java API from bare-kit classes.jar)
//       ↕ JNI
//   libbare-kit.so  ← installed by this hook
//
// What this hook does:
//
//   1. Download https://github.com/holepunchto/bare-kit/releases/download/
//      v2.4.3/prebuilds.zip into shared output.
//
//   2. Extract `prebuilds/android/bare-kit/jni/<abi>/libbare-kit.so`
//      into shared output.
//
//   3. Extract `prebuilds/android/bare-kit/classes.jar` into
//      android/libs/ — picked up by android/build.gradle's
//      `implementation files("libs/bare-kit-classes.jar")` so the
//      plugin module ships the bare-kit Java API to host apps.
//
//   4. Register libbare-kit.so as a Flutter code asset for the
//      target ABI. Flutter copies the .so into the host app's
//      lib/<abi>/ at build time.
//
// Why this design
// ---------------
//
// Previous design (nodejs-mobile v18.20.4) used Dart FFI directly
// against `libnode.so` with C++ glue that faked stdio pipes. bare-kit
// has no equivalent C ABI — its Android side is Java + JNI, where
// every entry point (Worklet.start / IPC.read / IPC.write) is
// registered via `JNI_OnLoad` → `RegisterNatives` and is callable
// only from a Java thread with a JNIEnv attached.
//
// The repository is therefore structured as a Flutter plugin: the
// Kotlin plugin class implements FlutterPlugin, the Flutter build
// toolchain auto-registers it with the host app, and MethodChannel
// / EventChannel are the only surface Dart needs.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _bareKitVersion = 'v2.4.3';

const _bareKitPrebuildsUrl =
    'https://github.com/holepunchto/bare-kit/releases/download/'
    '$_bareKitVersion/prebuilds.zip';

const _bridgeAssetName = 'native/bare_bridge.dart';

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

    // ---------------------------------------------------------------------
    // Shared output directory (one place Flutter reads from for every
    // target ABI built in the same `flutter build` invocation).
    // ---------------------------------------------------------------------

    final sharedDir = Directory.fromUri(
      input.outputDirectoryShared,
    );

    await sharedDir.create(
      recursive: true,
    );

    // ---------------------------------------------------------------------
    // Download + extract bare-kit prebuilds.zip.
    //
    // Layout inside the zip:
    //
    //   prebuilds/
    //     android/
    //       bare-kit/
    //         classes.jar    ← Java API (to.holepunch.bare.kit.*)
    //         jni/
    //           arm64-v8a/libbare-kit.so
    //           armeabi-v7a/libbare-kit.so
    //           x86_64/libbare-kit.so
    //           ...
    // ---------------------------------------------------------------------

    final prebuildRoot = Directory(
      '${sharedDir.path}/bare-kit-$_bareKitVersion',
    );

    await prebuildRoot.create(
      recursive: true,
    );

    final zipFile = File(
      '${prebuildRoot.path}/prebuilds.zip',
    );

    if (!await zipFile.exists()) {
      print(
        'ncm_api_enhanced: downloading $_bareKitPrebuildsUrl',
      );

      await _downloadFile(
        Uri.parse(_bareKitPrebuildsUrl),
        zipFile,
      );
    }

    final expectedSo =
        'prebuilds/android/bare-kit/jni/$abi/libbare-kit.so';
    final expectedClassesJar = 'prebuilds/android/bare-kit/classes.jar';

    final soFile = File(
      '${prebuildRoot.path}/libbare-kit.so',
    );

    //
    // Plugin module's android/libs/ directory is the canonical
    // location for local .jar files referenced by `implementation
    // files(...)` in android/build.gradle. Put the jar there once
    // so the same file is shared across every ABI build and is not
    // regenerated on each `flutter build`.
    //

    final pluginAndroidRoot = Directory(
      '${Directory.fromUri(input.packageRoot).path}/android',
    );

    final pluginLibsDir = Directory(
      '${pluginAndroidRoot.path}/libs',
    );

    final classesJarFile = File(
      '${pluginLibsDir.path}/bare-kit-classes.jar',
    );

    if (!await soFile.exists() || !await classesJarFile.exists()) {
      await _extractAndroidArtifacts(
        archivePath: zipFile.path,
        soDestination: soFile,
        classesJarDestination: classesJarFile,
        expectedSo: expectedSo,
        expectedClassesJar: expectedClassesJar,
      );
    }

    if (!await soFile.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain libbare-kit.so '
        'for $abi (expected $expectedSo in '
        '$_bareKitPrebuildsUrl)',
      );
    }

    if (!await classesJarFile.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain classes.jar '
        '(expected $expectedClassesJar in '
        '$_bareKitPrebuildsUrl)',
      );
    }

    print(
      'ncm_api_enhanced: libbare-kit.so: ${soFile.path}',
    );

    print(
      'ncm_api_enhanced: bare-kit classes.jar: ${classesJarFile.path}',
    );

    // ---------------------------------------------------------------------
    // Register libbare-kit.so as a code asset.
    //
    // Flutter's native_assets machinery copies the .so into the host
    // app's lib/<abi>/ at build time. Kotlin code in the host app
    // can then call System.loadLibrary("bare-kit") to dlopen it.
    // ---------------------------------------------------------------------

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _bridgeAssetName,
        linkMode: DynamicLoadingBundled(),
        file: soFile.uri,
      ),
    );

    print(
      'ncm_api_enhanced: registered libbare-kit.so for $abi',
    );
  });
}

// ===========================================================================
// Extract libbare-kit.so + classes.jar from prebuilds.zip
// ===========================================================================

Future<void> _extractAndroidArtifacts({
  required String archivePath,
  required File soDestination,
  required File classesJarDestination,
  required String expectedSo,
  required String expectedClassesJar,
}) async {
  print(
    'ncm_api_enhanced: extracting '
    '$expectedSo and $expectedClassesJar',
  );

  final bytes = await File(archivePath).readAsBytes();

  final archive = ZipDecoder().decodeBytes(
    bytes,
    verify: true,
  );

  ArchiveFile? soEntry;
  ArchiveFile? jarEntry;

  for (final file in archive.files) {
    final normalized = file.name.replaceAll('\\', '/');

    if (normalized == expectedSo) {
      soEntry = file;
    } else if (normalized == expectedClassesJar) {
      jarEntry = file;
    }

    if (soEntry != null && jarEntry != null) {
      break;
    }
  }

  if (soEntry == null) {
    throw StateError(
      'ncm_api_enhanced: $expectedSo was not found in '
      '$_bareKitPrebuildsUrl',
    );
  }

  if (jarEntry == null) {
    throw StateError(
      'ncm_api_enhanced: $expectedClassesJar was not found in '
      '$_bareKitPrebuildsUrl',
    );
  }

  await soDestination.parent.create(recursive: true);

  await soDestination.writeAsBytes(
    soEntry.content as List<int>,
    flush: true,
  );

  await classesJarDestination.parent.create(recursive: true);

  await classesJarDestination.writeAsBytes(
    jarEntry.content as List<int>,
    flush: true,
  );

  print(
    'ncm_api_enhanced: extracted '
    '${soDestination.path} and ${classesJarDestination.path}',
  );
}

// ===========================================================================
// Android ABI
// ===========================================================================

String? _androidAbi(
  Architecture architecture,
) {
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

Future<void> _downloadFile(
  Uri url,
  File destination,
) async {
  final temp = File(
    '${destination.path}.download',
  );

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

    await temp.rename(
      destination.path,
    );
  } finally {
    client.close(
      force: true,
    );
  }
}
