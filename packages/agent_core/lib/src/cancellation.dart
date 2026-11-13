import 'dart:async';

/// Cooperative cancellation (P1-11): a token shared between the host, the
/// agent loop, team orchestrator and long-running tools. Cancellation is
/// cooperative — tools that receive the token poll [isCancelled] or await
/// [whenCancelled]; the loop checks it at iteration and tool boundaries.
///
/// The token is single-use: one turn/subagent/team run creates its own token.
class CancellationToken {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  /// True once [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Completes when the token is cancelled. Safe to await multiple times.
  Future<void> get whenCancelled => _completer.future;

  /// Marks the token cancelled. Idempotent.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }

  /// Throws [OperationCancelledException] when already cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelledException();
  }

  /// Returns a future that completes with [action]'s result, or throws
  /// [OperationCancelledException] as soon as the token is cancelled. The
  /// underlying work keeps running in the background (cooperative — it
  /// should observe [isCancelled]/[whenCancelled] and stop on its own); its
  /// eventual result or error is ignored after cancellation.
  Future<T> guard<T>(Future<T> action) {
    if (_cancelled) {
      return Future<T>.error(const OperationCancelledException());
    }
    return _guarded<T>(action);
  }

  Future<T> _guarded<T>(Future<T> action) async {
    final done = Completer<T>();
    unawaited(() async {
      try {
        done.complete(await action);
      } catch (e, s) {
        if (!done.isCompleted) done.completeError(e, s);
      }
    }());
    unawaited(() async {
      try {
        await whenCancelled;
      } catch (_) {}
      if (!done.isCompleted) {
        done.completeError(const OperationCancelledException());
      }
    }());
    return done.future;
  }
}

/// Thrown when work is abandoned because its [CancellationToken] was
/// cancelled. Hosts treat it as a normal, non-retryable turn outcome.
class OperationCancelledException implements Exception {
  const OperationCancelledException();

  @override
  String toString() => 'Operation cancelled';
}

/// Registry of per-scope tokens (session id, subagent id, team node id) so a
/// host can cancel one scope without touching others.
class CancellationRegistry {
  final Map<String, CancellationToken> _tokens = {};

  /// Begins a new turn for [key]: a fresh token replaces any previous one.
  CancellationToken begin(String key) {
    final t = CancellationToken();
    _tokens[key] = t;
    return t;
  }

  /// The live token for [key], or null when no turn is registered.
  CancellationToken? tokenOf(String key) => _tokens[key];

  /// Cancels the scope's token if present. Returns true when a live token
  /// was cancelled.
  bool cancel(String key) {
    final t = _tokens[key];
    if (t == null || t.isCancelled) return false;
    t.cancel();
    return true;
  }

  /// Cancels every live token (e.g. runtime shutdown) and clears the registry.
  void cancelAll() {
    for (final t in _tokens.values) {
      t.cancel();
    }
    _tokens.clear();
  }
}
