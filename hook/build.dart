import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// Node.js version used on every platform.
//
// Android: prebuilt libnode.so / libcpufeatures.so published under the
//          cmachsocket/node v$_nodeVersion release tag.
// Windows: official node.exe from nodejs.org (see _nodeWindowsSha256).
const _nodeVersion = '26.12.1';

// ---------------------------------------------------------------------------
// Windows node.exe
//
// The Windows desktop runtime is NOT committed to this repository. It is
// ~105 MB (x64) / ~87 MB (arm64), which exceeds GitHub's per-file limit and
// would bloat the pub tarball. Instead this hook downloads the official
// Node.js binary at build time and registers it as a bundled CodeAsset, so
// Flutter's installer drops it next to the application executable
// (<app>/node.exe). DesktopNcmBridge spawns that file directly.
//
// SHA-256 values are copied from
//   https://nodejs.org/dist/v26.12.1/SHASUMS256.txt
// and MUST be updated together with _nodeVersion.
// ---------------------------------------------------------------------------

const _nodeWindowsSha256 = <String, String>{
  'win-x64': '1c63f1417e2e26d83ca9a9ec1d548524ab1305bc7209d90ebca56257ff0d84ed',
  'win-arm64':
      '7384299eeb99f419acaa4142771689fbca72e1c942f8da02b7928ffe1744e3ff',
};

// Official dist first, npmmirror as a fallback for networks that cannot
// reach nodejs.org.
List<Uri> _nodeWindowsUrls(String flavor) => <Uri>[
  Uri.parse(
    'https://nodejs.org/dist/v$_nodeVersion/'
    '$flavor/node.exe',
  ),
  Uri.parse(
    'https://npmmirror.com/mirrors/node/v$_nodeVersion/'
    '$flavor/node.exe',
  ),
];

// Retry count per URL. The runtimes are large (87-155 MB), so a dropped
// connection should not fail the whole build.
const _downloadAttempts = 3;

const _nodeAndroidReleaseUrl =
    'https://github.com/cmachsocket/node/releases/download/'
    'v$_nodeVersion/libnode.so';

// libcpufeatures.so ships as a separate asset in the same release.
//
// Why we need it:
//
//   libnode.so (nodejs-mobile) imports `android_getCpuFeatures`.
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
    'v$_nodeVersion/libcpufeatures.so';

const _bridgeAssetName = 'native/node_bridge.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final config = input.config.code;

    if (config.targetOS == OS.windows) {
      await _buildWindowsRuntime(
        input: input,
        output: output,
        architecture: config.targetArchitecture,
      );

      return;
    }

    if (config.targetOS != OS.android) {
      return;
    }

    final architecture = config.targetArchitecture;
    final abi = _androidAbi(architecture);

    stdout.writeln(
      'ncm_api_enhanced: building Node.js Mobile $_nodeVersion '
      'for Android $abi',
    );

    // -----------------------------------------------------------------------
    // Shared output directory.
    // -----------------------------------------------------------------------

    final sharedDir = Directory.fromUri(input.outputDirectoryShared);

    await sharedDir.create(recursive: true);

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
    //
    // Under `flutter test` the hook runs inside flutter_tester, so
    // Platform.resolvedExecutable is NOT <dart-sdk>/bin/dart. Fall back
    // to <FLUTTER_ROOT>/bin/cache/dart-sdk in that case.
    // -----------------------------------------------------------------------

    final dartSdkDir = _findDartSdkDir();

    if (dartSdkDir == null) {
      throw StateError(
        'ncm_api_enhanced: could not locate the Dart SDK '
        '(dart_api_dl.h). Tried:\n'
        '  - ${File(Platform.resolvedExecutable).parent.parent.path}\n'
        '  - \$FLUTTER_ROOT/bin/cache/dart-sdk',
      );
    }

    final dartIncludeDir = Directory('${dartSdkDir.path}/include');

    final dartApiDlHeader = File('${dartIncludeDir.path}/dart_api_dl.h');

    final dartApiDlSource = File('${dartIncludeDir.path}/dart_api_dl.c');

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

    stdout.writeln(
      'ncm_api_enhanced: Dart SDK: '
      '${dartSdkDir.path}',
    );

    stdout.writeln(
      'ncm_api_enhanced: Dart include: '
      '${dartIncludeDir.path}',
    );

    stdout.writeln(
      'ncm_api_enhanced: Dart API DL source: '
      '${dartApiDlSource.path}',
    );

    output.dependencies.add(dartApiDlHeader.uri);

    output.dependencies.add(dartApiDlSource.uri);

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

    final dartApiDlCpp = File('${sharedDir.path}/dart_api_dl_compat.cpp');

    await _prepareDartApiDlCpp(
      source: dartApiDlSource,
      destination: dartApiDlCpp,
    );

    output.dependencies.add(dartApiDlCpp.uri);

    stdout.writeln(
      'ncm_api_enhanced: prepared Dart API DL C++ source: '
      '${dartApiDlCpp.path}',
    );

    // -----------------------------------------------------------------------
    // Download libnode.so.
    // -----------------------------------------------------------------------

    final nodeDir = Directory(
      '${sharedDir.path}/nodejs-mobile-$_nodeVersion/$abi',
    );

    await nodeDir.create(recursive: true);

    final nodeLibrary = File('${nodeDir.path}/libnode.so');

    if (!await nodeLibrary.exists()) {
      await _downloadNodeLibrary(
        sharedRoot: sharedDir,
        destination: nodeLibrary,
      );
    }

    if (!await nodeLibrary.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain libnode.so for $abi',
      );
    }

    stdout.writeln(
      'ncm_api_enhanced: libnode.so: '
      '${nodeLibrary.path}',
    );

    // -----------------------------------------------------------------------
    // Download libcpufeatures.so.
    //
    // libnode.so (nodejs-mobile) imports `android_getCpuFeatures`
    // but no Android system .so exports that symbol — it lives only in
    // NDK's static `libcpufeatures.a`. dlopen(libnode.so) therefore fails
    // with `cannot locate symbol "android_getCpuFeatures"` unless we ship
    // a `libcpufeatures.so` providing it. The release at
    //   _cpuFeaturesAndroidReleaseUrl
    // publishes a prebuilt per-ABI `libcpufeatures.so` next to every
    // `libnode.so`. We download it the same way we download libnode.so.
    // -----------------------------------------------------------------------

    final cpuFeaturesLib = File('${nodeDir.path}/libcpufeatures.so');

    if (!await cpuFeaturesLib.exists()) {
      await _downloadCpuFeaturesLibrary(
        sharedRoot: sharedDir,
        destination: cpuFeaturesLib,
      );
    }

    if (!await cpuFeaturesLib.exists()) {
      throw StateError(
        'ncm_api_enhanced: failed to obtain libcpufeatures.so '
        'for $abi',
      );
    }

    stdout.writeln(
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
      input.packageRoot.resolve('native/android/node_bridge.cpp'),
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

      sources: <String>[bridgeSource.path, dartApiDlCpp.path],

      // dart_api_dl.h lives here.
      includes: <String>[dartIncludeDir.path],

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

      libraryDirectories: <String>[nodeDir.path],

      language: Language.cpp,

      cppLinkStdLib: 'c++_shared',

      linkModePreference: LinkModePreference.dynamic,

      pic: true,

      std: 'c++17',

      optimizationLevel: OptimizationLevel.o3,
    );

    await builder.run(input: input, output: output);

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

    stdout.writeln('ncm_api_enhanced: registered libnode.so for $abi');

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'native/libcpufeatures.dart',
        linkMode: DynamicLoadingBundled(),
        file: cpuFeaturesLib.uri,
      ),
    );

    stdout.writeln('ncm_api_enhanced: registered libcpufeatures.so for $abi');
  });
}

// ===========================================================================
// Locate the Dart SDK
// ===========================================================================
//
// Prefers the SDK that owns the running executable; falls back to the
// Flutter SDK's bundled Dart SDK, which is the one visible under
// `flutter test` (the hook then runs inside flutter_tester, so
// Platform.resolvedExecutable is not <dart-sdk>/bin/dart).
Directory? _findDartSdkDir() {
  final candidates = <Directory>[
    File(Platform.resolvedExecutable).parent.parent,
  ];

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];

  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    candidates.add(Directory('$flutterRoot/bin/cache/dart-sdk'));
  }

  for (final dir in candidates) {
    final header = File('${dir.path}/include/dart_api_dl.h');

    final source = File('${dir.path}/include/dart_api_dl.c');

    if (header.existsSync() && source.existsSync()) {
      return dir;
    }
  }

  return null;
}

// ===========================================================================
// Windows: fetch node.exe and bundle it next to the app executable
// ===========================================================================
//
// `flutter build windows` installs every DynamicLoadingBundled CodeAsset
// into the application directory next to the runner executable. That is
// exactly where DesktopNcmBridge looks for node.exe, so no Windows plugin
// or CMake logic is required.
//
// This is the only place the Windows runtime comes from: it is neither
// committed to git nor declared in pubspec's `flutter: assets:` section.
Future<void> _buildWindowsRuntime({
  required BuildInput input,
  required BuildOutputBuilder output,
  required Architecture architecture,
}) async {
  final flavor = _windowsFlavor(architecture);

  final sharedDir = Directory.fromUri(input.outputDirectoryShared);

  final nodeExe = File(
    '${sharedDir.path}/nodejs-win-$_nodeVersion/'
    '$flavor/node.exe',
  );

  if (!await _hasValidNodeWindowsBinary(nodeExe, flavor)) {
    final cached = await _cachedDownload(
      fallbackDir: sharedDir,
      relativePath: 'nodejs-win-$_nodeVersion/$flavor/node.exe',
      urls: _nodeWindowsUrls(flavor),
      minSize: 50 * 1024 * 1024,
      sha256: _nodeWindowsSha256[flavor],
    );

    if (cached.path != nodeExe.path) {
      await nodeExe.parent.create(recursive: true);

      await cached.copy(nodeExe.path);
    }
  }

  stdout.writeln(
    'ncm_api_enhanced: node.exe ($flavor): '
    '${nodeExe.path} '
    '(${await nodeExe.length() ~/ 1024 ~/ 1024} MB)',
  );

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'native/node.exe',
      linkMode: DynamicLoadingBundled(),
      file: nodeExe.uri,
    ),
  );

  stdout.writeln('ncm_api_enhanced: registered node.exe for Windows $flavor');
}

// Maps a Flutter Windows target architecture to the Node.js dist flavor.
String _windowsFlavor(Architecture architecture) {
  switch (architecture) {
    case Architecture.x64:
      return 'win-x64';

    case Architecture.arm64:
      return 'win-arm64';

    default:
      throw UnsupportedError('Unsupported Windows architecture: $architecture');
  }
}

// True when the file already exists with the expected checksum.
Future<bool> _hasValidNodeWindowsBinary(File file, String flavor) {
  final expected = _nodeWindowsSha256[flavor];

  if (expected == null) {
    throw UnsupportedError('No node.exe checksum for $flavor');
  }

  return _isValidDownload(
    file,
    // The smallest official binary is ~87 MB; anything smaller is a
    // truncated download.
    minSize: 50 * 1024 * 1024,
    sha256: expected,
  );
}

// ===========================================================================
// Download cache
// ===========================================================================
//
// Downloaded runtimes are stored in a per-user cache, so repeated builds
// (and repeated `flutter test` runs) never hit the network again. Falls
// back to the hook's shared output directory when the environment has no
// usable home directory.
Directory? _cacheDir() {
  final env = Platform.environment;

  final String? base;

  if (Platform.isWindows) {
    base = env['LOCALAPPDATA'] ?? env['APPDATA'];
  } else {
    base = env['XDG_CACHE_HOME'] ?? _homeSubdir('.cache');
  }

  if (base == null || base.isEmpty) {
    return null;
  }

  return Directory('$base/ncm_api_enhanced');
}

String? _homeSubdir(String name) {
  final home = Platform.environment['HOME'];

  if (home == null || home.isEmpty) {
    return null;
  }

  return '$home/$name';
}

// Returns a cached download, fetching it only when missing or invalid.
//
// relativePath is resolved under the cache directory (or fallbackDir
// when there is none). urls are tried in order.
Future<File> _cachedDownload({
  required Directory fallbackDir,
  required String relativePath,
  required List<Uri> urls,
  int? minSize,
  String? sha256,
}) async {
  final cache = _cacheDir();

  final file = File('${(cache ?? fallbackDir).path}/$relativePath');

  if (await _isValidDownload(file, minSize: minSize, sha256: sha256)) {
    return file;
  }

  await file.parent.create(recursive: true);

  Object? lastError;

  for (final url in urls) {
    // Transient network failures are common for these large binaries, so
    // retry a few times before falling back to the next mirror.
    for (var attempt = 1; attempt <= _downloadAttempts; attempt++) {
      try {
        stdout.writeln(
          'ncm_api_enhanced: downloading $url'
          '${attempt == 1 ? '' : ' (attempt $attempt/$_downloadAttempts)'}',
        );

        await _downloadFile(url, file);

        if (!await _isValidDownload(file, minSize: minSize, sha256: sha256)) {
          await file.delete();

          throw StateError('downloaded file failed validation: ${file.path}');
        }

        return file;
      } catch (error) {
        lastError = error;

        final temp = File('${file.path}.download');

        if (await temp.exists()) {
          await temp.delete();
        }

        stdout.writeln('ncm_api_enhanced: download failed ($url): $error');
      }
    }
  }

  throw StateError(
    'ncm_api_enhanced: could not download $relativePath.\n'
    'Tried:\n'
    '${urls.map((u) => '  - $u').join('\n')}\n'
    'Last error: $lastError',
  );
}

Future<bool> _isValidDownload(File file, {int? minSize, String? sha256}) async {
  if (!await file.exists()) {
    return false;
  }

  if (minSize != null && await file.length() < minSize) {
    await file.delete();

    return false;
  }

  if (sha256 != null && await _sha256Of(file) != sha256) {
    await file.delete();

    return false;
  }

  return true;
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;

  return digest.toString();
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

  content = content.replaceFirst(original, replacement);

  await destination.parent.create(recursive: true);

  await destination.writeAsString(content, flush: true);
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
//   libnode.so (nodejs-mobile) imports `android_getCpuFeatures`.
//   On Android that symbol exists ONLY in NDK's static
//   `libcpufeatures.a` — no system .so exports it. dlopen(libnode.so)
//   therefore fails with `cannot locate symbol "android_getCpuFeatures"`
//   unless we provide a `libcpufeatures.so` exporting it. The stub is
//   safe because nodejs-mobile only consults the value to pick V8 code
//   paths — a 0 return triggers portable fallbacks.
// ===========================================================================

Future<void> _downloadCpuFeaturesLibrary({
  required Directory sharedRoot,
  required File destination,
}) async {
  final source = await _cachedDownload(
    fallbackDir: sharedRoot,
    relativePath: 'nodejs-mobile-$_nodeVersion/libcpufeatures.so',
    urls: <Uri>[Uri.parse(_cpuFeaturesAndroidReleaseUrl)],
    minSize: 1024,
  );

  // Match libnode.so: ensure executable permission.
  if (!Platform.isWindows) {
    await Process.run('chmod', ['755', source.path]);
  }

  await destination.parent.create(recursive: true);

  await source.copy(destination.path);

  stdout.writeln(
    'ncm_api_enhanced: copied '
    '${destination.path}',
  );
}

// ===========================================================================
// Android ABI
// ===========================================================================
//
// Only arm64-v8a is supported. The prebuilt release at
// _nodeAndroidReleaseUrl carries a single arm64 libnode.so (and the
// matching libcpufeatures.so); linking it into an armeabi-v7a or x86_64
// build fails in the NDK linker anyway. Reject other ABIs up front with
// a clear message instead of producing a broken APK.
String _androidAbi(Architecture architecture) {
  if (architecture == Architecture.arm64) {
    return 'arm64-v8a';
  }

  throw UnsupportedError(
    'ncm_api_enhanced: Android ${architecture.name} is not supported. '
    'The prebuilt libnode.so / libcpufeatures.so release only ships '
    'arm64-v8a binaries. Build with --target-platform android-arm64.',
  );
}

// ===========================================================================
// Download libnode.so
// ===========================================================================

Future<void> _downloadNodeLibrary({
  required Directory sharedRoot,
  required File destination,
}) async {
  final source = await _cachedDownload(
    fallbackDir: sharedRoot,
    relativePath: 'nodejs-mobile-$_nodeVersion/libnode.so',
    urls: <Uri>[Uri.parse(_nodeAndroidReleaseUrl)],
    minSize: 1024 * 1024,
  );

  // -------------------------------------------------------------------------
  // Ensure executable permission.
  // -------------------------------------------------------------------------

  if (!Platform.isWindows) {
    await Process.run('chmod', ['755', source.path]);
  }

  // -------------------------------------------------------------------------
  // Copy to final destination.
  // -------------------------------------------------------------------------

  stdout.writeln(
    'ncm_api_enhanced: using '
    '${source.path}',
  );

  await destination.parent.create(recursive: true);

  await source.copy(destination.path);

  stdout.writeln(
    'ncm_api_enhanced: copied '
    '${destination.path}',
  );
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
        'ncm_api_enhanced/$_nodeVersion '
        '(Dart build hook)';

    final request = await client.getUrl(url);

    request.followRedirects = true;
    request.maxRedirects = 8;

    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      await response.drain();

      throw HttpException('HTTP ${response.statusCode} while downloading $url');
    }

    final sink = temp.openWrite();

    try {
      await sink.addStream(response);
      await sink.flush();
    } finally {
      await sink.close();
    }

    await temp.rename(destination.path);
  } finally {
    client.close(force: true);
  }
}
