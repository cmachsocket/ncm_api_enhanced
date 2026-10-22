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
  test(
    'hook declares CodeAssets for libnode + libcpufeatures on arm64-v8a',
    () async {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.arm64,
        check: (input, output) {
          final assets = output.assets.code.toList();
          expect(
            assets.length,
            3,
            reason:
                'hook must emit 3 CodeAssets: libnode, libcpufeatures '
                'and the compiled node bridge',
          );

          // libnode.so, libcpufeatures.so and libncm_node_bridge.so.
          final ids = assets.map((a) => a.id).toList();
          expect(
            ids,
            containsAll(<String>[
              'package:ncm_api_enhanced/native/libnode.dart',
              'package:ncm_api_enhanced/native/libcpufeatures.dart',
              'package:ncm_api_enhanced/native/node_bridge.dart',
            ]),
          );

          for (final a in assets) {
            expect(a.id, startsWith('package:ncm_api_enhanced/'));
            expect(a.linkMode, isA<DynamicLoadingBundled>());
            expect(
              a.file,
              isNotNull,
              reason: 'DynamicLoadingBundled requires a file Uri',
            );
            final file = File.fromUri(a.file!);
            expect(
              file.existsSync(),
              isTrue,
              reason: 'file must exist on disk: ${a.file}',
            );
            if (a.id.endsWith('libnode.dart')) {
              expect(
                file.statSync().size,
                greaterThan(1024 * 1024),
                reason: 'libnode.so is ~30 MB; smaller means corrupt',
              );
            } else if (a.id.endsWith('libcpufeatures.dart')) {
              // Stub: tiny.
              expect(
                file.statSync().size,
                lessThan(64 * 1024),
                reason:
                    'libcpufeatures.so stub is <64 KB; larger means '
                    'we accidentally shipped a full NDK cpufeatures.a',
              );
            }
          }
        },
      );
      // First run downloads libnode.so (~155 MB) and compiles the bridge
      // with the NDK. Subsequent runs reuse the download cache.
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test('hook is a no-op on iOS (framework can\'t be a CodeAsset)', () async {
    await testCodeBuildHook(
      mainMethod: hook.main,
      targetOS: OS.iOS,
      targetArchitecture: Architecture.arm64,
      check: (input, output) {
        expect(
          output.assets.encodedAssets,
          isEmpty,
          reason: 'iOS deployment requires manual Xcode steps',
        );
      },
    );
  });

  test('hook downloads node.exe for Windows builds', () async {
    await testCodeBuildHook(
      mainMethod: hook.main,
      targetOS: OS.windows,
      // Windows assets are architecture specific; use the host one so the
      // hook test downloads the matching binary.
      targetArchitecture: Architecture.current,
      check: (input, output) {
        final assets = output.assets.code.toList();

        expect(
          assets.length,
          1,
          reason: 'hook must emit exactly one CodeAsset: node.exe',
        );

        final asset = assets.single;

        expect(asset.id, 'package:ncm_api_enhanced/native/node.exe');
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        expect(asset.file, isNotNull);

        final file = File.fromUri(asset.file!);

        expect(file.existsSync(), isTrue);
        expect(file.path, endsWith('node.exe'));
        expect(
          file.statSync().size,
          greaterThan(50 * 1024 * 1024),
          reason: 'official node.exe is ~87-105 MB; smaller means corrupt',
        );
      },
    );
    // First run downloads ~105 MB; later runs reuse the download cache.
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('hook is a no-op on Linux/macOS (use system node)', () async {
    for (final os in [OS.linux, OS.macOS]) {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: os,
        // Architecture doesn't matter for a no-op; pick the host one.
        targetArchitecture: Architecture.current,
        check: (input, output) {
          expect(
            output.assets.encodedAssets,
            isEmpty,
            reason: '$os uses the system node, no native asset needed',
          );
        },
      );
    }
  });

  test('hook rejects Android ABIs other than arm64-v8a', () async {
    for (final arch in [
      Architecture.arm,
      Architecture.x64,
      Architecture.riscv64,
    ]) {
      await expectLater(
        () => testCodeBuildHook(
          mainMethod: hook.main,
          targetOS: OS.android,
          targetArchitecture: arch,
          check: (input, output) {},
        ),
        throwsA(isA<UnsupportedError>()),
        reason:
            '$arch must be rejected: the prebuilt libnode.so is '
            'arm64-v8a only',
      );
    }
  });
}
