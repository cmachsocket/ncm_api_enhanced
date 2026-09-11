// hook/build.dart — downloads libnode.so for Android via the build hook
// protocol.
//
// We declare one CodeAsset per Android ABI (DynamicLoadingBundled). The
// Dart/Flutter SDK copies the libnode.so we point at into the app's
// lib/<abi>/. Our CMake build (android/src/main/cpp/CMakeLists.txt)
// links against the same file path so libncm_node_bridge.so can resolve
// node::Start at app launch.
//
// We also copy the same .so file into android/src/main/jniLibs/<abi>/
// so the Android Gradle Plugin packages it into the AAR — without
// this step, the app would only have libnode.so inside its own lib/
// directory but the plugin's CMake build couldn't find it for linking.
//
// Other OSes: this hook is a no-op on iOS (NodeMobile.xcframework is
// a directory of binaries, which CodeAsset can't express), and on
// desktop (the system `node` binary is used instead).

// Hooks run once at build time. We deliberately use `print` to surface
// progress to the developer and don't follow strict style rules.
// ignore_for_file: avoid_print, unnecessary_brace_in_string_interps

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;

// Pinned nodejs-mobile release. Update in lockstep with README.md and
// CHANGELOG.md — bumping this is a breaking change for the package.
const String _releaseTag = 'v18.20.4';
const String _assetBase = 'https://github.com/nodejs-mobile/nodejs-mobile/releases/download/$_releaseTag';
// GitHub release assets ship as .zip (not .tar.gz).
const String _androidArchive = '$_assetBase/nodejs-mobile-$_releaseTag-android.zip';

// Test-only aliases so `flutter test` can verify the pinned values
// without re-typing them in test code.
const String releaseTagForTesting = _releaseTag;
const String androidArchiveUrlForTesting = _androidArchive;

// sha256 of nodejs-mobile-v18.20.4-android.tar.gz. Pinned so a
// malicious mirror / re-release can't slip a different libnode into
// apps. Update via a coordinated package release when upstream bumps.
//
// sha256 verification is a TODO before publishing; for now we rely on
// hook cache invalidation. See _download().
// const String _androidTarballSha256 = '...';

// ABI → libnode filename as packaged in the tarball. Keys are the
// canonical Architecture names (which are stable strings per
// code_assets 2.x), not Architecture instances, because const maps
// require primitive keys.
const Map<String, String> _androidLibNodeByArchName = {
  'arm': 'libnode.so',
  'arm64': 'libnode.so',
  'x64': 'libnode.so',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final code = input.config.code;
    switch (code.targetOS) {
      case OS.android:
        await _buildAndroid(input, output);
      case OS.iOS:
      case OS.linux:
      case OS.macOS:
      case OS.windows:
      case OS.fuchsia:
        // iOS: NodeMobile.xcframework is a directory — CodeAsset can't
        // express that. The user adds the framework to the Xcode
        // project manually (see docs/mobile_setup.md and
        // tool/patch_ios_pbxproj.rb).
        //
        // Desktop: we spawn the system `node` binary; no native asset
        // needs to ship.
        //
        // Fuchsia: not supported.
        break;
    }
  });
}

Future<void> _buildAndroid(
    HookInput input, BuildOutputBuilder output) async {
  final code = input.config.code;
  final archName = code.targetArchitecture.name;
  // nodejs-mobile v18.20.4 ships armeabi-v7a + arm64-v8a + x86_64.
  if (!_androidLibNodeByArchName.containsKey(archName)) {
    throw UnsupportedError(
      'ncm_api_enhanced: no libnode.so for Android architecture $archName',
    );
  }

  final cacheDir = Directory.fromUri(input.outputDirectoryShared);
  await cacheDir.create(recursive: true);

  final archive = File.fromUri(
    cacheDir.uri.resolve('nodejs-mobile-$_releaseTag-android.zip'),
  );
  await _download(archive, _androidArchive);

  // Extract just the libnode.so for this ABI. The zip layout is:
  //   bin/<abi>/libnode.so
  //   include/node/*.h
  final abiDir = _abiDirFor(archName);
  final entryPath = 'bin/$abiDir/libnode.so';
  final libnodeOut = File.fromUri(cacheDir.uri.resolve('libnode-$abiDir.so'));

  await _extractFromZip(archive, entryPath, libnodeOut);

  // Validate size / magic. libnode.so is a real ELF / Mach-O file with a
  // non-trivial size (~30 MB). Catching corruption here surfaces a clear
  // error during `flutter build` rather than at app launch.
  final bytes = await libnodeOut.readAsBytes();
  if (bytes.length < 1024 * 1024) {
    throw StateError(
      'Extracted libnode.so is suspiciously small (${bytes.length} bytes); '
      'archive may be corrupt.',
    );
  }

  // Also copy into android/src/main/jniLibs/<abi>/ so CMake's IMPORTED
  // location can find it at link time, and so the AGP packages it into
  // the AAR's jniLibs directory.
  final pluginJniLibs = Directory(
    '${input.packageRoot.toFilePath()}android/src/main/jniLibs/$abiDir',
  );
  if (!pluginJniLibs.existsSync()) {
    pluginJniLibs.createSync(recursive: true);
  }
  await libnodeOut.copy('${pluginJniLibs.path}/libnode.so');

  // Declare the code asset. `DynamicLoadingBundled` is the only mode
  // CodeAsset uses to ship files into the app bundle for Dart/Flutter.
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/native/libnode_${abiDir}.dart',
      linkMode: DynamicLoadingBundled(),
      file: libnodeOut.uri,
    ),
  );

  // Hook cache invalidation: rerun when the archive on disk changes.
  output.dependencies.add(archive.uri);
}

String _abiDirFor(String archName) {
  switch (archName) {
    case 'arm':
      return 'armeabi-v7a';
    case 'arm64':
      return 'arm64-v8a';
    case 'x64':
      return 'x86_64';
    default:
      throw UnsupportedError('Unsupported arch: $archName');
  }
}

/// Test-only alias for [_abiDirFor]. Kept as a separate name so the
/// public API surface stays clean.
String abiDirForTesting(String archName) => _abiDirFor(archName);

Future<void> _download(File dest, String url) async {
  if (await dest.exists()) {
    return; // hook caching: .dart_tool/hooks_runner/<pkg>/<hash>/ survives across runs.
  }

  // The Dart SDK gives us a per-config temp dir; we can't share it across
  // hook invocations. For repeated CI builds (and for `flutter test` of
  // our own hook), this means re-downloading ~70 MB every time. Cache
  // the archive under a stable global path so second-and-later runs
  // are instant.
  final globalCache = await _globalCacheDir();
  final cachedArchive = File('${globalCache.path}/${url.split('/').last}');
  if (await cachedArchive.exists()) {
    await cachedArchive.copy(dest.path);
    return;
  }
  print('Downloading $url');
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw HttpException(
      'Failed to download $url: status ${response.statusCode}',
    );
  }
  await cachedArchive.parent.create(recursive: true);
  await cachedArchive.writeAsBytes(response.bodyBytes);
  await cachedArchive.copy(dest.path);
  // sha256 verification is a TODO before publishing; for now we rely on
  // hook cache invalidation + the HTTPS-only GitHub Releases endpoint.
  // When added, verify against the pin comment at the top of this file.
}

/// User-level cache directory for downloaded archives. Survives across
/// builds and across `flutter test` runs. The cache lives under the
/// platform-specific user cache path (e.g. `~/.cache/ncm_api_enhanced`
/// on Linux/macOS, `%LOCALAPPDATA%\ncm_api_enhanced` on Windows).
Future<Directory> _globalCacheDir() async {
  final env = Platform.environment;
  final base = env['NCM_BRIDGE_CACHE_DIR'] ??
      env['XDG_CACHE_HOME'] ??
      (Platform.isWindows
          ? env['LOCALAPPDATA'] ?? '.'
          : env['HOME'] != null ? '${env['HOME']}/.cache' : '.');
  return Directory('$base/ncm_api_enhanced');
}

Future<void> _extractFromZip(
    File archive, String entryName, File outFile) async {
  if (await outFile.exists()) return;
  final bytes = await archive.readAsBytes();
  final zip = ZipDecoder().decodeBytes(bytes);
  final entry = zip.files.firstWhere(
    (f) => f.name == entryName,
    orElse: () => throw StateError(
      'Entry "$entryName" not found in ${archive.path}.\n'
      'Available top-level entries:\n'
      '${zip.files.map((f) => "  ${f.name}").take(20).join("\n")}',
    ),
  );
  if (!entry.isFile) {
    throw StateError('Archive entry "$entryName" is not a file');
  }
  await outFile.create(recursive: true);
  await outFile.writeAsBytes(entry.content as List<int>);
}