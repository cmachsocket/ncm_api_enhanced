import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _nodeVersion = '18.20.4';

const _nodeAndroidZipUrl =
    'https://github.com/nodejs-mobile/nodejs-mobile/releases/download/'
    'v18.20.4/nodejs-mobile-v18.20.4-android.zip';

const _bridgeAssetName = 'native/node_bridge.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final config = input.config.code;

    // -----------------------------------------------------------------------
    // This package's native bridge is Android-only.
    // -----------------------------------------------------------------------

    if (config.targetOS != OS.android) {
      return;
    }

    // -----------------------------------------------------------------------
    // Native assets can be disabled by the build configuration.
    // -----------------------------------------------------------------------

    if (!input.config.buildCodeAssets) {
      return;
    }

    final architecture = config.targetArchitecture;

    final abi = _androidAbi(architecture);

    if (abi == null) {
      throw UnsupportedError(
        'ncm_api_enhanced: unsupported Android architecture: '
        '${architecture.name}',
      );
    }

    print(
      'ncm_api_enhanced: building Node.js Mobile $_nodeVersion '
      'for Android $abi',
    );

    // -----------------------------------------------------------------------
    // Shared output directory.
    //
    // Build hooks are expected to place generated/downloaded artifacts here.
    // -----------------------------------------------------------------------

    final sharedDir = Directory.fromUri(input.outputDirectoryShared);

    await sharedDir.create(recursive: true);

    // -----------------------------------------------------------------------
    // Download + extract libnode.so.
    // -----------------------------------------------------------------------

    final nodeDir = Directory(
      '${sharedDir.path}/nodejs-mobile-$_nodeVersion/$abi',
    );

    await nodeDir.create(recursive: true);

    final nodeLibrary = File('${nodeDir.path}/libnode.so');

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

    print('ncm_api_enhanced: libnode.so: ${nodeLibrary.path}');

    // -----------------------------------------------------------------------
    // Make sure node_bridge.cpp exists.
    // -----------------------------------------------------------------------

    final bridgeSource = File.fromUri(
      input.packageRoot.resolve('native/android/node_bridge.cpp'),
    );

    if (!await bridgeSource.exists()) {
      throw StateError(
        'ncm_api_enhanced: missing native/android/node_bridge.cpp',
      );
    }

    // -----------------------------------------------------------------------
    // CBuilder
    //
    // node_bridge.cpp contains:
    //
    //     namespace node {
    //       int Start(int argc, char** argv);
    //     }
    //
    // so no node.h is required.
    //
    // The linker resolves:
    //
    //     _ZN4node5StartEiPPc
    //
    // from libnode.so.
    // -----------------------------------------------------------------------

    final builder = CBuilder.library(
      name: 'ncm_node_bridge',
      assetName: _bridgeAssetName,

      sources: <String>[bridgeSource.path],

      libraries: <String>['node', 'log'],

      libraryDirectories: <String>[nodeDir.path],

      language: Language.cpp,

      // node_bridge.cpp uses C++.
      cppLinkStdLib: 'c++_shared',

      // Build as a dynamic library.
      linkModePreference: LinkModePreference.dynamic,

      // Position-independent shared library.
      pic: true,

      // C++17 is more than enough for this bridge.
      std: 'c++17',

      optimizationLevel: OptimizationLevel.o3,
    );

    await builder.run(input: input, output: output);

    // -----------------------------------------------------------------------
    // Register libnode.so itself.
    //
    // CBuilder registers libncm_node_bridge.so.
    //
    // libnode.so is a separate prebuilt dynamic library and must also be
    // exposed to the application bundle.
    // -----------------------------------------------------------------------

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'native/libnode.dart',
        linkMode: DynamicLoadingBundled(),
        file: nodeLibrary.uri,
      ),
    );

    print('ncm_api_enhanced: registered libnode.so for $abi');
  });
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
// Download + extract libnode.so
// ===========================================================================

Future<void> _downloadNodeLibrary({
  required Directory outputDirectory,
  required File destination,
  required String abi,
}) async {
  final archiveDir = Directory(
    '${outputDirectory.path}/nodejs-mobile-$_nodeVersion',
  );

  await archiveDir.create(recursive: true);

  final zipFile = File(
    '${archiveDir.path}/'
    'nodejs-mobile-v$_nodeVersion-android.zip',
  );

  // -------------------------------------------------------------------------
  // Download ZIP if necessary.
  // -------------------------------------------------------------------------

  if (!await zipFile.exists()) {
    print('ncm_api_enhanced: downloading $_nodeAndroidZipUrl');

    await _downloadFile(Uri.parse(_nodeAndroidZipUrl), zipFile);
  }

  // -------------------------------------------------------------------------
  // Read ZIP.
  // -------------------------------------------------------------------------

  print('ncm_api_enhanced: extracting $abi/libnode.so');

  final bytes = await zipFile.readAsBytes();

  final archive = ZipDecoder().decodeBytes(bytes, verify: true);

  // Official nodejs-mobile Android release layout:
  //
  //   bin/
  //     arm64-v8a/
  //       libnode.so
  //     armeabi-v7a/
  //       libnode.so
  //     x86_64/
  //       libnode.so
  //
  // See nodejs-mobile Android samples.
  // -------------------------------------------------------------------------

  final expectedPath = 'bin/$abi/libnode.so';

  ArchiveFile? nodeFile;

  for (final file in archive.files) {
    final normalized = file.name.replaceAll('\\', '/');

    if (normalized == expectedPath) {
      nodeFile = file;
      break;
    }
  }

  if (nodeFile == null) {
    throw StateError(
      'ncm_api_enhanced: $expectedPath was not found in '
      '$_nodeAndroidZipUrl',
    );
  }

  final content = nodeFile.content;

  await destination.parent.create(recursive: true);

  await destination.writeAsBytes(content, flush: true);

  print('ncm_api_enhanced: extracted ${destination.path}');
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
