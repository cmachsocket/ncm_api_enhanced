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
  test('hook declares CodeAssets for libnode + libcpufeatures per ABI',
      () async {
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
          final assets = output.assets.code.toList();
          expect(assets.length, 2,
              reason:
                  'hook must emit exactly 2 CodeAssets per ABI: '
                  'libnode + libcpufeatures');

          // Both must be libnode.so and libcpufeatures.so, in some order.
          final ids = assets.map((a) => a.id).toList();
          expect(
              ids,
              containsAll(<String>[
                'package:ncm_api_enhanced/native/libnode.dart',
                'package:ncm_api_enhanced/native/libcpufeatures.dart',
              ]));

          for (final a in assets) {
            expect(a.id, startsWith('package:ncm_api_enhanced/'));
            expect(a.linkMode, isA<DynamicLoadingBundled>());
            expect(a.file, isNotNull,
                reason: 'DynamicLoadingBundled requires a file Uri');
            final file = File.fromUri(a.file!);
            expect(file.existsSync(), isTrue,
                reason: 'file must exist on disk: ${a.file}');
            if (a.id.endsWith('libnode.dart')) {
              expect(file.statSync().size, greaterThan(1024 * 1024),
                  reason: 'libnode.so is ~30 MB; smaller means corrupt');
            } else if (a.id.endsWith('libcpufeatures.dart')) {
              // Stub: tiny.
              expect(file.statSync().size, lessThan(64 * 1024),
                  reason:
                      'libcpufeatures.so stub is <64 KB; larger means '
                      'we accidentally shipped a full NDK cpufeatures.a');
            }
          }
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