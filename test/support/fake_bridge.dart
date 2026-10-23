// SPDX-License-Identifier: MIT
//
// Hand-written test doubles for the bridge layer.
//
// The package intentionally has no mocking dependency: [NcmBridge] is a
// four-member contract, so a plain fake is cheaper and more readable than
// generated mocks.

import 'dart:async';

import 'package:ncm_api_enhanced/src/bridge.dart';

/// A programmable [NcmBridge] double.
///
/// Records every call so tests can assert what the facade forwarded, and
/// replies with canned responses (or fails with a canned error).
class FakeNcmBridge implements NcmBridge {
  FakeNcmBridge({Map<String, Map<String, dynamic>>? responses, this.error})
    : responses = responses ?? <String, Map<String, dynamic>>{};

  /// Canned reply per module name.
  final Map<String, Map<String, dynamic>> responses;

  /// When non-null every [call] fails with this error.
  final Object? error;

  /// Module names in call order.
  final List<String> methods = [];

  /// Params in call order; `null` when the caller passed no params.
  final List<Map<String, dynamic>?> paramLog = [];

  /// Number of times [start] was called.
  int startCount = 0;

  /// Number of times [shutdown] was called.
  int shutdownCount = 0;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Push a bridge event (ready/log/fatal) to [events].
  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    methods.add(method);
    paramLog.add(params);

    final failure = error;
    if (failure != null) {
      throw failure;
    }

    return responses[method] ?? <String, dynamic>{'ok': true};
  }
}
