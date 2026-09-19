import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

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
      'ncm_api_enhanced: building ncm_node_bridge '
      'for Android $abi (spawning bundled node PIE)',
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
    // Verify the upstream Node binary is in the Flutter asset bundle.
    //
    // We do NOT compile or download anything for the Node runtime
    // itself anymore. The Dart side extracts the binary from the
    // Flutter asset bundle (declared in pubspec.yaml) at runtime and
    // hands the absolute path to the native bridge, which spawns it
    // via fork()+execvp().
    //
    // We only check the asset file exists so the user gets a clear
    // error early if they forgot to populate it.
    // -----------------------------------------------------------------------

    const packageAssetRoot =
        'packages/ncm_api_enhanced/assets/runtime';

    final nodeBinaryAsset =
        '$packageAssetRoot/android-arm64/node';


    //
    // `rootBundle` is not available inside a build hook, but the
    // asset path resolves to a real file on disk under
    // input.packageRoot. Probe that file directly so we can fail
    // fast with a useful message.
    //
    final nodeBinaryFile = File.fromUri(
      input.packageRoot.resolve(
        'assets/runtime/android-arm64/node',
      ),
    );


    if (!await nodeBinaryFile.exists()) {

      throw StateError(
        'ncm_api_enhanced: missing the Android node binary.\n'
        '\n'
        'Expected at:\n'
        '  ${nodeBinaryFile.path}\n'
        '\n'
        'This package now spawns a prebuilt `node` PIE binary '
        'instead of linking libnode.so. Populate that file by '
        'copying your aarch64-android24 build:\n'
        '\n'
        '  cp <PROJECT>/node/out/Release/node '
        '<THIS_PKG>/assets/runtime/android-arm64/node\n'
        '\n'
        'Only arm64-v8a is supported today. The Dart side will '
        'fail at start() on other ABIs.',
      );
    }


    final nodeSize =
        await nodeBinaryFile.length();


    print(
      'ncm_api_enhanced: using bundled node binary '
      '(${(nodeSize / (1024 * 1024)).toStringAsFixed(1)} MB) '
      'at asset path $nodeBinaryAsset',
    );

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
    //     liblog.so
    //
    // We intentionally do NOT link libnode.so — Node is now an
    // external child process, not an in-process V8 instance.
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
        'log',
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

    print(
      'ncm_api_enhanced: registered libncm_node_bridge.so '
      'for $abi (no in-process libnode)',
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

