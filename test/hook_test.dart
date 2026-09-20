// Hook tests using the official hooks+code_assets test harness.
// These tests exercise the full build() protocol that the Dart SDK
// uses at build time, without needing to actually run flutter build.
//
// Run with:
//   flutter test test/hook_test.dart --timeout=5x

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart' as hook;

void main() {
  test('hook declares a single Android CodeAsset per ABI', () async {
    // Map from code_assets Architecture → expected ABI substring in
    // the generated asset id (matches hook's hard-coded name format).
    final archToName = {
      Architecture.arm: 'armeabi-v7a',
      Architecture.arm64: 'arm64-v8a',
      Architecture.x64: 'x86_64',
    };
    for (final arch in archToName.keys) {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: arch,
        check: (input, output) {
          expect(output.assets.encodedAssets, isNotEmpty,
              reason: 'hook must emit at least one CodeAsset for $arch');
          final assets = output.assets.code.toList();
          expect(assets.length, 1);
          final a = assets.single;
          // id is `package:<pkg>/<name>`. Verify the package prefix is
          // ours and the name encodes the ABI directory.
          expect(a.id, startsWith('package:ncm_api_enhanced/'));
          expect(a.id, contains(archToName[arch]!));
          expect(a.linkMode, isA<DynamicLoadingBundled>());
          expect(a.file, isNotNull,
              reason: 'DynamicLoadingBundled requires a file Uri');
          final file = File.fromUri(a.file!);
          expect(file.existsSync(), isTrue,
              reason: 'file must exist on disk: ${a.file}');
          expect(file.statSync().size, greaterThan(1024 * 1024),
              reason: 'libnode.so is ~30 MB; smaller means corrupt');
          // The same .so must also be copied into the plugin's jniLibs
          // directory so CMake can find it at link time.
          final jniPath =
              '${input.packageRoot.toFilePath()}android/src/main/jniLibs/${archToName[arch]}/libnode.so';
          expect(File(jniPath).existsSync(), isTrue,
              reason: 'libnode.so must be in plugin jniLibs for CMake');
        },
      );
    }
  });

  test('hook is a no-op on iOS (framework can\'t be a CodeAsset)', () async {
    await testCodeBuildHook(
      mainMethod: hook.main,
      targetOS: OS.iOS,
      targetArchitecture: Architecture.arm64,
      check: (input, output) {
        expect(output.assets.encodedAssets, isEmpty,
            reason: 'iOS deployment requires manual Xcode steps');
      },
    );
  });

  test('hook is a no-op on desktop (uses system node)', () async {
    for (final os in [OS.linux, OS.macOS, OS.windows]) {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: os,
        // Architecture doesn't matter for a no-op; pick the host one.
        targetArchitecture: Architecture.current,
        check: (input, output) {
          expect(output.assets.encodedAssets, isEmpty,
              reason: '$os uses the system node, no native asset needed');
        },
      );
    }
  });

  test('hook throws on unsupported Android architecture', () async {
    expect(
      () => testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.riscv64,
        check: (input, output) {},
      ),
      throwsA(anything), // hook should raise UnsupportedError
    );
  });
}