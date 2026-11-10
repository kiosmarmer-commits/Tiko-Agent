import 'package:agent_core/agent_core.dart';

/// Global safety controls (AGD-07 §3).
class SafetyState {
  bool safeMode = false; // safe allowlist runs directly; other tools require explicit approval
  bool panic = false; // reject medium+ until cleared
  bool stopRequested = false; // cancel active task

  void requestStop() => stopRequested = true;
  void clearStop() => stopRequested = false;

  void enableSafeMode() => safeMode = true;
  void disableSafeMode() => safeMode = false;

  void triggerPanic() => panic = true;
  void clearPanic() => panic = false;
}

/// Gate wrapper that applies safe-mode / panic on top of an inner gate.
class SafetyPermissionGate implements PermissionGate {
  SafetyPermissionGate(this.inner, this.state);

  final PermissionGate inner;
  final SafetyState state;

  /// These read-only/deterministic tools are available without approval in
  /// safe mode. Every other tool must pass the regular policy and receive a
  /// one-shot capability after explicit approval.
  static const Set<String> safeModeTools = {
    'datetime',
    'calc',
    'list_dir',
    'read_file',
    'web_search',
    'web_fetch',
    'memory_search',
    'list_jobs',
  };

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (state.panic && !safeModeTools.contains(call.name)) {
      // Panic blocks every side-effecting/dynamic tool, including newly added
      // MCP and script tools. A hard-coded deny list becomes stale as plugins
      // are registered, so only the explicit read-only allowlist survives.
      return const PermissionResult(
        PermissionVerdict.denied,
        reason: 'panic flag active',
      );
    }

    final result = await inner.check(call, session);
    if (result.verdict == PermissionVerdict.denied) return result;

    if (state.safeMode &&
        !safeModeTools.contains(call.name) &&
        result.verdict == PermissionVerdict.needsConfirm) {
      // Do not silently block useful actions: route them through the normal
      // approval workflow. The capability gate returns `allowed` on the
      // second check only after validating the broker-minted one-shot permit.
      return PermissionResult(
        PermissionVerdict.needsConfirm,
        reason: result.reason ?? 'safe-mode requires explicit approval',
      );
    }
    return result;
  }
}
