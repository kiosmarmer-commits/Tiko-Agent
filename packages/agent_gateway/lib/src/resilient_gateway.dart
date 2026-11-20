import 'dart:async';

import 'package:agent_core/agent_core.dart';

/// Uniform delivery policy for every messaging gateway.
///
/// The wrapped gateway remains the source of truth for channel formatting and
/// authentication. This layer only adds bounded retry/backoff and operation
/// timeouts, while preserving the normalized message contract.
class ResilientGateway implements Gateway {
  ResilientGateway(
    this.inner, {
    this.maxAttempts = 3,
    this.operationTimeout = const Duration(seconds: 30),
    this.initialBackoff = const Duration(milliseconds: 250),
  }) : assert(maxAttempts > 0),
       assert(!operationTimeout.isNegative),
       assert(!initialBackoff.isNegative);

  final Gateway inner;
  final int maxAttempts;
  final Duration operationTimeout;
  final Duration initialBackoff;

  @override
  String get channel => inner.channel;

  @override
  Stream<InboundMessage> get inbound => inner.inbound;

  @override
  Future<void> send(OutboundMessage message) =>
      _retry(() => inner.send(message), operationName: 'send');

  @override
  Future<void> sendTyping(String sessionKey) =>
      _retry(() => inner.sendTyping(sessionKey), operationName: 'sendTyping');

  @override
  Future<void> close() => inner.close().timeout(operationTimeout);

  Future<void> _retry(
    Future<void> Function() operation, {
    required String operationName,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await operation().timeout(operationTimeout);
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt == maxAttempts) break;
        final delay = initialBackoff * (1 << (attempt - 1));
        await Future<void>.delayed(delay);
      }
    }
    Error.throwWithStackTrace(
      StateError(
        '$channel $operationName gagal setelah $maxAttempts percobaan: $lastError',
      ),
      lastStack ?? StackTrace.current,
    );
  }
}
