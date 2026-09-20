import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _nodeVersion = '26.9.0';

const _nodeAndroidReleaseUrl =
    'https://github.com/cmachsocket/node/releases/download/'
    'v26.9.0/libnode.so';

// libcpufeatures.so ships as a separate asset in the same release.
//
// Why we need it:
//
//   libnode.so (nodejs-mobile v26.9.0) imports `android_getCpuFeatures`.
//   On Android that symbol exists ONLY in NDK's static
//   `libcpufeatures.a` — no system .so exports it. dlopen(libnode.so)
//   therefore fails with `cannot locate symbol "android_getCpuFeatures"`
//   unless we ship a `libcpufeatures.so` providing it.
//
// The .so is a stub: it exports `android_getCpuFeatures` returning 0
// (no optional CPU features advertised), which is safe because
// nodejs-mobile only consults the value to pick V8 code paths — 0
// just causes V8 to use portable fallbacks.
//
// IMPORTANT — ABI coverage:
//
//   Each release tag carries one `libcpufeatures.so` corresponding to
//   the SAME ABI as the matching `libnode.so`. ELF .so files are NOT
//   ABI-interchangeable, so a release tagged for `arm64-v8a` only fixes
//   dlopen on arm64 devices. Other ABIs (armeabi-v7a, x86_64) need
//   their own release tag — the publish script
//   `node/tools/build_libcpufeatures.sh` exists to produce per-ABI
//   stubs but the URL below is intentionally fixed (one ABI == one tag).
const _cpuFeaturesAndroidReleaseUrl =
    'https://github.com/cmachsocket/node/releases/download/'
    'v26.9.0/libcpufeatures.so';

const _bridgeAssetName = 'native/node_bridge.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final config = input.config.code;

    if (config.targetOS != OS.android) {
      return;
    }

    final architecture = config.targetArchitecture;
    final abi = _androidAbi(architecture);

    if (abi == null) {
      throw UnsupportedError(
        'Unsupported Android architecture: $architecture',
      );
    }

    print(
      'ncm_api_enhanced: building Node.js Mobile $_nodeVersion '
      'for Android $abi',
    );

    // -----------------------------------------------------------------------
    // Shared output directory.
    // -----------------------------------------------------------------------

    final sharedDir = Directory.fromUri(
      input.outputDirectoryShared,
    );

    await sharedDir.create(
      recursive: true,
    );

    // -----------------------------------------------------------------------
    // Locate Dart SDK.
    //
    //   <dart-sdk>/bin/dart
    //          ^
    //          |
    //   Platform.resolvedExecutable
    //
    // Therefore:
    //
    //   parent        -> <dart-sdk>/bin
    //   parent.parent -> <dart-sdk>
    //
    // Dart API DL:
    //
    //   <dart-sdk>/include/dart_api_dl.h
    //   <dart-sdk>/include/dart_api_dl.c
    // -----------------------------------------------------------------------

    final dartExecutable = File(
      Platform.resolvedExecutable,
    );

    final dartSdkDir = dartExecutable.parent.parent;

    final dartIncludeDir = Directory(
      '${dartSdkDir.path}/include',
    );

    final dartApiDlHeader = File(
      '${dartIncludeDir.path}/dart_api_dl.h',
    );

    final dartApiDlSource = File(
      '${dartIncludeDir.path}/dart_api_dl.c',
    );

    if (!await dartApiDlHeader.exists()) {
      throw StateError(
        'ncm_api_enhanced: dart_api_dl.h not found at '
        '${dartApiDlHeader.path}',
      );
    }

    if (!await dartApiDlSource.exists()) {
      throw StateError(
        'ncm_api_enhanced: dart_api_dl.c not found at '
        '${dartApiDlSource.path}',
      );
    }

    print(
      'ncm_api_enhanced: Dart SDK: '
      '${dartSdkDir.path}',
    );

    print(
      'ncm_api_enhanced: Dart include: '
      '${dartIncludeDir.path}',
    );

    print(
      'ncm_api_enhanced: Dart API DL source: '
      '${dartApiDlSource.path}',
    );

    output.dependencies.add(
      dartApiDlHeader.uri,
    );

    output.dependencies.add(
      dartApiDlSource.uri,
    );

    // -----------------------------------------------------------------------
    // Prepare dart_api_dl.c for the C++ CBuilder.
    //
    // native_toolchain_c's CBuilder is configured as Language.cpp, and
    // RunCBuilder passes:
    //
    //     -x c++
    //
    // for ALL source files.
    //
    // Therefore passing the original dart_api_dl.c directly causes the
    // official C source to be compiled as C++, which fails on Dart 3.10's
    // DartApiEntry_function conversion.
    //
    // We create a private build copy and make the one C -> C++ conversion
    // required by clang.
    // -----------------------------------------------------------------------

    final dartApiDlCpp = File(
      '${sharedDir.path}/dart_api_dl_compat.cpp',
    );

    await _prepareDartApiDlCpp(
      source: dartApiDlSource,
      destination: dartApiDlCpp,
    );

    output.dependencies.add(
      dartApiDlCpp.uri,
    );

    print(
      'ncm_api_enhanced: prepared Dart API DL C++ source: '
      '${dartApiDlCpp.path}',
    );

    // -----------------------------------------------------------------------
    // Download libnode.so.
    // -----------------------------------------------------------------------

    final nodeDir = Directory(
      '${sharedDir.path}/nodejs-mobile-$_nodeVersion/$abi',
    );

    await nodeDir.create(
      recursive: true,
    );

    final nodeLibrary = File(
      '${nodeDir.path}/libnode.so',
    );

    if (!await nodeLibrary.exists()) {
      await _downloadNodeLibrary(
        outputDirectory: sharedDir,
        destination: nodeLibrary,
        abi: abi,
      );
    }

    if (!await nodeLibrary.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain libnode.so for $abi',
      );
    }

    print(
      'ncm_api_enhanced: libnode.so: '
      '${nodeLibrary.path}',
    );

    // -----------------------------------------------------------------------
    // Download libcpufeatures.so.
    //
    // libnode.so (nodejs-mobile v26.9.0) imports `android_getCpuFeatures`
    // but no Android system .so exports that symbol — it lives only in
    // NDK's static `libcpufeatures.a`. dlopen(libnode.so) therefore fails
    // with `cannot locate symbol "android_getCpuFeatures"` unless we ship
    // a `libcpufeatures.so` providing it. The release at
    //   _cpuFeaturesAndroidReleaseUrl
    // publishes a prebuilt per-ABI `libcpufeatures.so` next to every
    // `libnode.so`. We download it the same way we download libnode.so.
    // -----------------------------------------------------------------------

    final cpuFeaturesLib = File(
      '${nodeDir.path}/libcpufeatures.so',
    );

    if (!await cpuFeaturesLib.exists()) {
      await _downloadCpuFeaturesLibrary(
        destination: cpuFeaturesLib,
      );
    }

    if (!await cpuFeaturesLib.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain libcpufeatures.so '
        'for $abi',
      );
    }

    print(
      'ncm_api_enhanced: libcpufeatures.so: '
      '${cpuFeaturesLib.path}',
    );

    // Declare the downloaded libcpufeatures.so as a hook dependency so
    // that downstream Gradle tasks invalidate (and rebuild) when the
    // .so changes. Without this, Flutter Gradle sees an unchanged
    // output.json and may reuse a stale APK that omits libcpufeatures.
    output.dependencies.add(cpuFeaturesLib.uri);

    // -----------------------------------------------------------------------
    // node_bridge.cpp
    // -----------------------------------------------------------------------

    final bridgeSource = File.fromUri(
      input.packageRoot.resolve(
        'native/android/node_bridge.cpp',
      ),
    );

    if (!await bridgeSource.exists()) {
      throw StateError(
        'ncm_api_enhanced: missing '
        'native/android/node_bridge.cpp',
      );
    }

    // -----------------------------------------------------------------------
    // CBuilder
    //
    // The resulting shared library contains:
    //
    //     node_bridge.cpp
    //     dart_api_dl_compat.cpp
    //
    // and links:
    //
    //     libnode.so
    //     liblog.so
    //
    // dart_api_dl_compat.cpp provides:
    //
    //     Dart_InitializeApiDL
    //     Dart_PostCObject_DL
    //     ...
    //
    // so libncm_node_bridge.so no longer leaves
    // Dart_PostCObject_DL as an unresolved ELF symbol.
    // -----------------------------------------------------------------------

    final builder = CBuilder.library(
      name: 'ncm_node_bridge',
      assetName: _bridgeAssetName,

      sources: <String>[
        bridgeSource.path,
        dartApiDlCpp.path,
      ],

      // dart_api_dl.h lives here.
      includes: <String>[
        dartIncludeDir.path,
      ],

      libraries: <String>[
        'node',
        'log',
        // libcpufeatures.so is downloaded from the same GitHub release
        // as libnode.so (see _downloadCpuFeaturesLibrary). libnode.so
        // imports `android_getCpuFeatures` from it; declaring the
        // dependency here causes the linker to emit
        // `DT_NEEDED libcpufeatures.so` into libncm_node_bridge.so,
        // which lets Android's dynamic linker resolve the symbol at
        // dlopen() time.
        'cpufeatures',
      ],

      libraryDirectories: <String>[
        nodeDir.path,
      ],

      language: Language.cpp,

      cppLinkStdLib: 'c++_shared',

      linkModePreference: LinkModePreference.dynamic,

      pic: true,

      std: 'c++17',

      optimizationLevel: OptimizationLevel.o3,
    );

    await builder.run(
      input: input,
      output: output,
    );

    // -----------------------------------------------------------------------
    // Register libnode.so + libcpufeatures.so as CodeAssets.
    //
    // Both .so files MUST end up in `<apk>/lib/<abi>/` at runtime —
    // Android's dynamic linker only resolves DT_NEEDED entries by
    // searching the same directory as the library being dlopen()ed.
    //
    // The new-style Flutter hooks protocol packages a CodeAsset with
    // linkMode = DynamicLoadingBundled into the APK automatically;
    // we do NOT need (and do NOT want) any jniLibs/ copy. The
    // traditional "copy to android/src/main/jniLibs/<abi>/" approach
    // only works when the package declares itself as a Flutter plugin
    // via pubspec's `flutter.plugin.platforms.android`. ncm_api_enhanced
    // does NOT register an Android plugin — it is a pure Dart package
    // with hooks — so that copy would just land in the package's own
    // pub-cache directory and never reach the APK. The CodeAsset
    // path is the right one.
    // -----------------------------------------------------------------------

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'native/libnode.dart',
        linkMode: DynamicLoadingBundled(),
        file: nodeLibrary.uri,
      ),
    );

    print(
      'ncm_api_enhanced: registered libnode.so for $abi',
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'native/libcpufeatures.dart',
        linkMode: DynamicLoadingBundled(),
        file: cpuFeaturesLib.uri,
      ),
    );

    print(
      'ncm_api_enhanced: registered libcpufeatures.so for $abi',
    );
  });
}

// ===========================================================================
// Prepare Dart API DL C++ compatibility source
// ===========================================================================

Future<void> _prepareDartApiDlCpp({
  required File source,
  required File destination,
}) async {
  var content = await source.readAsString();

  // Dart SDK's dart_api_dl.c contains a C-compatible conversion:
  //
  //     return entries->function;
  //
  // When the file is compiled as C++, the type is:
  //
  //     DartApiEntry_function == void*
  //
  // while entries->function is a function pointer.
  //
  // C accepts this conversion, but C++ does not.
  //
  // Explicitly cast it to the API's declared return type.
  const original =
      'if (strcmp(entries->name, name) == 0) return entries->function;';

  const replacement =
      'if (strcmp(entries->name, name) == 0) '
      'return reinterpret_cast<DartApiEntry_function>('
      'entries->function);';

  if (!content.contains(original)) {
    throw StateError(
      'ncm_api_enhanced: unexpected dart_api_dl.c layout. '
      'Could not find the expected DartApiEntry lookup expression.',
    );
  }

  content = content.replaceFirst(
    original,
    replacement,
  );

  await destination.parent.create(
    recursive: true,
  );

  await destination.writeAsString(
    content,
    flush: true,
  );
}

// ===========================================================================
// Download libcpufeatures.so
// ===========================================================================
//
// Mirrors _downloadNodeLibrary. Pulls the prebuilt per-ABI
// `libcpufeatures.so` stub from the same GitHub release as `libnode.so`
// and drops it next to it.
//
// Why we ship libcpufeatures.so at all:
//
//   libnode.so (nodejs-mobile v26.9.0) imports `android_getCpuFeatures`.
//   On Android that symbol exists ONLY in NDK's static
//   `libcpufeatures.a` — no system .so exports it. dlopen(libnode.so)
//   therefore fails with `cannot locate symbol "android_getCpuFeatures"`
//   unless we provide a `libcpufeatures.so` exporting it. The stub is
//   safe because nodejs-mobile only consults the value to pick V8 code
//   paths — a 0 return triggers portable fallbacks.
// ===========================================================================

Future<void> _downloadCpuFeaturesLibrary({
  required File destination,
}) async {
  print(
    'ncm_api_enhanced: downloading '
    '$_cpuFeaturesAndroidReleaseUrl',
  );

  await _downloadFile(
    Uri.parse(_cpuFeaturesAndroidReleaseUrl),
    destination,
  );

  // Match libnode.so: ensure executable permission.
  await Process.run('chmod', ['755', destination.path]);

  print(
    'ncm_api_enhanced: copied '
    '${destination.path}',
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
// Download libnode.so
// ===========================================================================

Future<void> _downloadNodeLibrary({
  required Directory outputDirectory,
  required File destination,
  required String abi,
}) async {
  final nodeDir = Directory(
    '${outputDirectory.path}/nodejs-mobile-$_nodeVersion',
  );

  await nodeDir.create(
    recursive: true,
  );

  final soFile = File(
    '${nodeDir.path}/libnode.so',
  );

  // -------------------------------------------------------------------------
  // Download .so directly if necessary.
  // -------------------------------------------------------------------------

  if (!await soFile.exists()) {
    print(
      'ncm_api_enhanced: downloading '
      '$_nodeAndroidReleaseUrl',
    );

    await _downloadFile(
      Uri.parse(_nodeAndroidReleaseUrl),
      soFile,
    );
  }

  // -------------------------------------------------------------------------
  // Ensure executable permission.
  // -------------------------------------------------------------------------

  await Process.run('chmod', ['755', soFile.path]);

  // -------------------------------------------------------------------------
  // Copy to final destination.
  // -------------------------------------------------------------------------

  print(
    'ncm_api_enhanced: using '
    '${soFile.path}',
  );

  await destination.parent.create(
    recursive: true,
  );

  await soFile.copy(
    destination.path,
  );

  print(
    'ncm_api_enhanced: copied '
    '${destination.path}',
  );
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
        'ncm_api_enhanced/$_nodeVersion '
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