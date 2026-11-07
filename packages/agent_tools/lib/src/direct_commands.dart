import 'package:agent_core/agent_core.dart';

import 'registry.dart';

/// Outcome of a direct (non-LLM) command.
class DirectResult {
  const DirectResult(this.exitCode, this.output, {this.handled = true});

  /// 0 = ok, 2 = invalid usage/arguments, 3 = denied by policy, 1 = tool error.
  final int exitCode;
  final String output;

  /// False when the command name is not a direct command (fall through to chat).
  final bool handled;

  static const notHandled = DirectResult(0, '', handled: false);
}

/// Deterministic command path (PRD §6 "Direct command versus chat"):
/// `tiko calc 5+1` -> tool `calc` -> `6`, never routed through an LLM, but
/// still subject to schema validation and the permission gate.
class DirectCommandDispatcher {
  DirectCommandDispatcher({
    required this.registry,
    required this.gate,
    this.confirm,
    this.workspacePath = '.',
  });

  final ToolRegistry registry;
  final PermissionGate gate;
  final Future<bool> Function(ToolCall call, Session session)? confirm;
  final String workspacePath;

  /// Command name -> (tool name, builder of tool args from CLI args).
  static final Map<String, _Direct> _commands = {
    'calc': _Direct('calc', (a) => a.isEmpty ? null : {'expression': a.join(' ')}),
    'datetime': _Direct('datetime', (a) => const <String, dynamic>{}),
  };

  static Iterable<String> get commandNames => _commands.keys;

  bool handles(String command) => _commands.containsKey(command);

  Future<DirectResult> run(
    String command,
    List<String> args, {
    Session? session,
  }) async {
    final spec = _commands[command];
    if (spec == null) return DirectResult.notHandled;

    final toolArgs = spec.build(args);
    if (toolArgs == null) {
      return DirectResult(2, 'Penggunaan: tiko $command <argumen>');
    }

    final tool = registry.get(spec.tool);
    if (tool == null) {
      return DirectResult(1, 'Tool tidak tersedia: ${spec.tool}');
    }
    final invalid = registry.validateArgs(spec.tool, toolArgs);
    if (invalid != null) return DirectResult(2, 'Argumen tidak valid: $invalid');

    final sess = session ??
        Session(id: 'direct', channel: 'cli', userKey: 'local');
    final call = ToolCall(
      id: 'direct_${DateTime.now().microsecondsSinceEpoch}',
      name: spec.tool,
      args: toolArgs,
    );

    // Direct invocation does NOT bypass the policy gate (PRD §6).
    var verdict = await gate.check(call, sess);
    if (verdict.verdict == PermissionVerdict.needsConfirm) {
      final ok = confirm != null ? await confirm!(call, sess) : false;
      verdict = ok
          ? const PermissionResult(PermissionVerdict.allowed)
          : const PermissionResult(PermissionVerdict.denied, reason: 'tidak disetujui');
    }
    if (verdict.verdict != PermissionVerdict.allowed) {
      return DirectResult(3, 'Ditolak: ${verdict.reason ?? verdict.verdict.name}');
    }

    final result = await RegistryToolExecutor(registry).run(
      call,
      ToolContext(session: sess, workspacePath: workspacePath),
    );
    return DirectResult(result.isError ? 1 : 0, result.content);
  }
}

class _Direct {
  const _Direct(this.tool, this.build);
  final String tool;
  final Map<String, dynamic>? Function(List<String> args) build;
}
