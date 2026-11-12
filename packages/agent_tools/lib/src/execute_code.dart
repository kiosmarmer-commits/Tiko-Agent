import 'dart:convert';

import 'package:agent_core/agent_core.dart';

/// Controlled multi-step execution (P2): runs a small JSON "program" that
/// chains several tool calls in one turn, with templated arguments fed from
/// earlier step outputs.
///
/// Safety contract:
/// - Every step passes the same [PermissionGate] as a direct tool call.
///   A `needsConfirm` or `denied` verdict fails the program (fail-closed);
///   the model is told to run that tool directly so the normal approval
///   broker flow applies.
/// - Bounded: at most [maxSteps] steps, at most [maxTotalOutputChars] of
///   captured output, wall clock bounded by the tool spec timeout.
/// - No arbitrary code execution: a "program" is a data-driven sequence of
///   registered tool calls, not a scripting language.
///
/// Program format:
/// ```json
/// {
///   "steps": [
///     {"tool": "list_dir", "args": {"path": "."}, "as": "listing"},
///     {"tool": "read_file", "args": {"path": "{{listing.files.0}}"}}
///   ]
/// }
/// ```
/// `{{name.path.to.field}}` substitutes a value from a previous step's
/// decoded JSON output; `{{name}}` substitutes the whole output.
class ExecuteCodeTool implements Tool {
  ExecuteCodeTool({
    required ToolExecutor executor,
    required PermissionGate gate,
    this.maxSteps = 8,
    this.maxTotalOutputChars = 40000,
  })  : _executor = executor,
        _gate = gate;

  final ToolExecutor _executor;
  final PermissionGate _gate;
  final int maxSteps;
  final int maxTotalOutputChars;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'execute_code',
        description:
            'Jalankan rangkaian tool call berurutan dalam satu turn. '
            'Setiap step tetap melewati permission gate; step yang butuh '
            'approval menggagalkan program (jalankan tool itu langsung). '
            'Argumen step bisa memakai template {{nama_step.field}} dari '
            'output step sebelumnya.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'description': 'Daftar step {tool, args, as?} berurutan',
              'items': {
                'type': 'object',
                'properties': {
                  'tool': {'type': 'string'},
                  'args': {'type': 'object'},
                  'as': {
                    'type': 'string',
                    'description': 'Nama variabel output (opsional)',
                  },
                },
                'required': ['tool'],
              },
            },
          },
          'required': ['steps'],
        },
        risk: 'medium',
        timeoutSec: 120,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rawSteps = args['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'steps wajib berupa array tidak kosong',
        isError: true,
      );
    }
    if (rawSteps.length > maxSteps) {
      return ToolResult(
        callId: '',
        content: 'program melebihi batas $maxSteps step (dapat ${rawSteps.length})',
        isError: true,
      );
    }

    final variables = <String, Object?>{};
    final stepReports = <Map<String, dynamic>>[];
    var totalOutput = 0;
    var aborted = false;
    String? abortReason;

    for (var i = 0; i < rawSteps.length && !aborted; i++) {
      final raw = rawSteps[i];
      if (raw is! Map) {
        aborted = true;
        abortReason = 'step $i bukan objek';
        break;
      }
      final toolName = raw['tool']?.toString() ?? '';
      final rawArgs = raw['args'];
      final stepArgs = <String, dynamic>{
        if (rawArgs is Map) ...rawArgs.cast<String, dynamic>(),
      };
      final as = raw['as']?.toString();

      // Template substitution from earlier step outputs.
      var templateError = '';
      final resolved = stepArgs.map((key, value) {
        final substituted = _substitute(value, variables, (msg) {
          templateError = msg;
        });
        return MapEntry(key, substituted);
      });
      if (templateError.isNotEmpty) {
        stepReports.add({
          'step': i,
          'tool': toolName,
          'ok': false,
          'error': templateError,
        });
        aborted = true;
        abortReason = templateError;
        break;
      }

      final call = ToolCall(id: 'exec-$i', name: toolName, args: resolved);
      final verdict = await _gate.check(call, ctx.session);
      if (verdict.verdict != PermissionVerdict.allowed) {
        final reason = verdict.verdict == PermissionVerdict.needsConfirm
            ? 'step $i ($toolName) butuh approval — jalankan tool ini '
                'langsung agar jalur approval normal berjalan'
            : 'step $i ($toolName) ditolak permission gate: '
                '${verdict.reason ?? 'denied'}';
        stepReports.add({
          'step': i,
          'tool': toolName,
          'ok': false,
          'error': reason,
        });
        aborted = true;
        abortReason = reason;
        break;
      }

      try {
        final result = await _executor.run(call, ctx);
        final output = result.content;
        totalOutput += output.length;
        if (as != null && as.isNotEmpty) {
          variables[as] = _tryDecode(output);
        }
        stepReports.add({
          'step': i,
          'tool': toolName,
          'ok': !result.isError,
          'output_chars': output.length,
          if (result.isError) 'error': _truncate(output, 500),
        });
        if (result.isError) {
          aborted = true;
          abortReason = 'step $i ($toolName) gagal: ${_truncate(output, 200)}';
        }
      } catch (e) {
        stepReports.add({
          'step': i,
          'tool': toolName,
          'ok': false,
          'error': e.toString(),
        });
        aborted = true;
        abortReason = 'step $i ($toolName) melempar: $e';
      }
      if (totalOutput > maxTotalOutputChars) {
        aborted = true;
        abortReason = 'total output melebihi $maxTotalOutputChars karakter';
      }
    }

    final summary = {
      'completed': !aborted,
      'steps_run': stepReports.length,
      if (abortReason != null) 'abort_reason': abortReason,
      'steps': stepReports,
    };
    return ToolResult(
      callId: '',
      content: const JsonEncoder.withIndent('  ').convert(summary),
      isError: aborted,
    );
  }

  Object? _substitute(
    Object? value,
    Map<String, Object?> variables,
    void Function(String) onError,
  ) {
    if (value is String) {
      final match = RegExp(r'^\{\{([a-zA-Z0-9_.]+)\}\}$').firstMatch(value);
      if (match != null) {
        final path = match.group(1)!.split('.');
        if (!variables.containsKey(path.first)) {
          onError('template "${path.first}" tidak dikenal (belum ada step '
              'dengan as="${path.first}")');
          return value;
        }
        var current = variables[path.first];
        for (final seg in path.skip(1)) {
          if (current is Map && current.containsKey(seg)) {
            current = current[seg];
          } else if (current is List) {
            final idx = int.tryParse(seg);
            if (idx != null && idx >= 0 && idx < current.length) {
              current = current[idx];
            } else {
              onError('template "$value": indeks "$seg" tidak valid');
              return value;
            }
          } else {
            onError('template "$value": path "$seg" tidak dapat diakses');
            return value;
          }
        }
        return current;
      }
      return value.replaceAllMapped(RegExp(r'\{\{([a-zA-Z0-9_.]+)\}\}'),
          (m) {
        final path = m.group(1)!.split('.');
        var current = variables[path.first];
        for (final seg in path.skip(1)) {
          if (current is Map) current = current[seg];
        }
        return current?.toString() ?? m.group(0)!;
      });
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _substitute(v, variables, onError)));
    }
    if (value is List) {
      return [for (final v in value) _substitute(v, variables, onError)];
    }
    return value;
  }

  Object? _tryDecode(String output) {
    try {
      return jsonDecode(output);
    } catch (_) {
      return output;
    }
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
