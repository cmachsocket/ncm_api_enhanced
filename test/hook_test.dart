// Hook tests using the official hooks+code_assets test harness.
// These tests exercise the full build() protocol that the Dart SDK
// uses at build time, without needing to actually run flutter build.
//
// Run with:
//   flutter test test/hook_test.dart --timeout=5x

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart' as hook;

void main() {
  test('hook emits ncm_node_bridge CodeAsset on Android', () async {
    // Map from code_assets Architecture → ABI substring used in the
    // CodeAsset id. The new architecture only supports arm64-v8a;
    // other ABIs still build the bridge but the Dart side will fail
    // at start() because the bundled node PIE only ships for arm64.
    final archToName = {
      Architecture.arm64: 'arm64-v8a',
    };
    for (final arch in archToName.keys) {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: arch,
        check: (input, output) {
          expect(output.assets.encodedAssets, isNotEmpty,
              reason: 'hook must emit the bridge CodeAsset for $arch');
          final assets = output.assets.code.toList();
          expect(assets.length, 1,
              reason: 'hook emits exactly one CodeAsset (the bridge)');
          final a = assets.single;
          expect(a.id, startsWith('package:ncm_api_enhanced/'));
          expect(a.linkMode, isA<DynamicLoadingBundled>());
          expect(a.file, isNotNull,
              reason: 'DynamicLoadingBundled requires a file Uri');
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