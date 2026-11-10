import 'shell_policy.dart';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'taint.dart';

/// Permission modes (AGD-03 §2).
enum PermissionMode { auto, ask, deny }

/// Matriks izin berdasarkan risiko tool + mode global.
class MatrixPermissionGate implements PermissionGate {
  MatrixPermissionGate({
    this.mode = PermissionMode.ask,
    this.shellAllowlist = const ['ls', 'cat', 'git status', 'pwd', 'echo'],
    this.requireConfirm = const [
      'write_file',
      'shell',
      'http_post',
      'http_request',
    ],
    this.taint,
    this.onConfirmRequest,
    this.riskResolver,
  });

  /// Resolves the declared risk of a tool (normally `ToolSpec.risk` from the
  /// registry). Return null when the tool is unknown. When provided, the gate
  /// uses the *stricter* of the declared risk and the built-in name table, and
  /// treats unknown tools as `high` (fail-closed, PRD §9.1).
  final String? Function(ToolCall call)? riskResolver;

  PermissionMode mode;
  final List<String> shellAllowlist;
  final List<String> requireConfirm;
  final TaintTracker? taint;

  /// Callback untuk minta konfirmasi user (CLI prompt / Telegram button).
  /// Harus mengembalikan true jika user setuju.
  final Future<bool> Function(ToolCall call, Session session)? onConfirmRequest;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    final risk = _riskOf(call);

    // C-03: after untrusted data, medium+ needs confirm even in auto
    if (taint != null && taint!.isTainted(session.id) && risk != 'low') {
      if (mode != PermissionMode.deny) {
        return await _confirmOrDeny(
          call,
          session,
          'session tainted — confirm required for ${call.name}',
        );
      }
    }

    // Critical/high never auto-run.
    if (mode == PermissionMode.deny) {
      return const PermissionResult(
        PermissionVerdict.denied,
        reason: 'mode deny',
      );
    }

    if (risk == 'critical') {
      return await _confirmOrDeny(
        call,
        session,
        'critical risk — konfirmasi dua langkah diperlukan',
      );
    }

    if (risk == 'high') {
      if (mode == PermissionMode.auto) {
        return const PermissionResult(
          PermissionVerdict.denied,
          reason: 'high risk tidak boleh auto',
        );
      }
      // Extra: shell allowlist
      if (call.name == 'shell') {
        final cmd = (call.args['cmd'] as String?)?.trim() ?? '';
        if (!_shellAllowed(call)) {
          return PermissionResult(
            PermissionVerdict.denied,
            reason: 'perintah shell di luar allowlist: $cmd',
          );
        }
      }
      return await _confirmOrDeny(call, session, 'high risk: ${call.name}');
    }

    if (risk == 'medium') {
      if (mode == PermissionMode.auto) {
        return const PermissionResult(PermissionVerdict.allowed);
      }
      if (requireConfirm.contains(call.name) || mode == PermissionMode.ask) {
        return await _confirmOrDeny(call, session, 'medium risk: ${call.name}');
      }
      return const PermissionResult(PermissionVerdict.allowed);
    }

    // low
    return const PermissionResult(PermissionVerdict.allowed);
  }

  Future<PermissionResult> _confirmOrDeny(
    ToolCall call,
    Session session,
    String reason,
  ) async {
    if (onConfirmRequest == null) {
      return PermissionResult(
        PermissionVerdict.needsConfirm,
        reason: reason,
        confirmId: _id(),
      );
    }
    final ok = await onConfirmRequest!(call, session);
    if (ok) {
      return const PermissionResult(PermissionVerdict.allowed);
    }
    return PermissionResult(
      PermissionVerdict.denied,
      reason: 'user rejected: $reason',
    );
  }

  static const _riskOrder = ['low', 'medium', 'high', 'critical'];

  static String stricterRisk(String a, String b) {
    final ia = _riskOrder.indexOf(a);
    final ib = _riskOrder.indexOf(b);
    return (ia < 0 ? 3 : ia) >= (ib < 0 ? 3 : ib) ? a : b;
  }

  String _riskOf(ToolCall call) {
    final byName = _riskByName(call);
    final resolver = riskResolver;
    if (resolver == null) return byName;
    final declared = resolver(call);
    // Unknown tool, or an unrecognised risk label, is treated as high.
    if (declared == null || !_riskOrder.contains(declared)) {
      return stricterRisk('high', byName);
    }
    return stricterRisk(declared, byName);
  }

  String _riskByName(ToolCall call) {
    const high = {'shell', 'http_request', 'http_post'};
    const medium = {
      'write_file',
      'patch_file',
      'schedule_job',
      'cancel_job',
      'memory_add',
      'plan_task',
      'spawn_subagent',
    };
    const low = {
      'datetime',
      'calc',
      'list_dir',
      'read_file',
      'web_search',
      'web_fetch',
      'memory_search',
      'list_jobs',
    };
    const Set<String> critical = {}; // reserved for explicitly classified tools
    if (critical.contains(call.name)) return 'critical';
    if (high.contains(call.name)) return 'high';
    if (medium.contains(call.name)) return 'medium';
    if (low.contains(call.name)) return 'low';
    // Unknown names are not harmless merely because their spec resolver was
    // omitted by a legacy CLI or a test harness.
    return 'high';
  }

  bool _shellAllowed(ToolCall call) {
    final cmd = '${call.args['command'] ?? call.args['cmd'] ?? ''}';
    final policy = ShellPolicy(
      allowlist: ShellPolicy.fromStringList(shellAllowlist),
    );
    return policy.check(cmd) == null;
  }

  String _id() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
