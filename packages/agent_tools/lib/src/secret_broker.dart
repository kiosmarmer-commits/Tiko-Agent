import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'sandbox.dart';

/// Command executor used by the broker; injectable for tests.
typedef BrokerCommandRunner = Future<ProcessResult> Function(
  List<String> parts,
);

/// secret_broker (NEW-06): the model only knows secret NAMES. Values
/// are substituted at execution time and redacted from stdout/stderr
/// before the result ever reaches the model, so a leaked command
/// output cannot leak the credential itself. Fails closed when a
/// secret is missing or its value could break argv tokenization.
class SecretBrokerTool implements Tool {
  SecretBrokerTool({
    required this.sandbox,
    this.secretSource,
    BrokerCommandRunner? commandRunner,
  }) : _commandRunner = commandRunner;

  final SandboxRunner sandbox;
  final Map<String, String> Function()? secretSource;
  final BrokerCommandRunner? _commandRunner;

  /// Characters a secret value must never contain: whitespace breaks
  /// argv tokenization, the rest are shell metacharacters.
  static const String _badChars = ' \t\n;&|<>`\$"'\\';

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'secret_broker',
    description:
        'Jalankan perintah dengan placeholder {{secret:NAME}}. Nilai '
        'disubstitusi saat eksekusi dan di-redact dari output; model '
        'tidak pernah melihat nilai secret.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'Perintah dengan placeholder {{secret:NAME}}.',
        },
        'secrets': {
          'type': 'array',
          'description': 'Nama secret yang dipakai di command.',
        },
      },
      'required': ['command', 'secrets'],
    },
    risk: 'high',
    timeoutSec: 30,
    maxOutputChars: 50000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final command = args['command'] as String? ?? '';
    final rawSecrets = args['secrets'];
    if (command.trim().isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'command wajib',
        isError: true,
      );
    }
    if (rawSecrets is! List || rawSecrets.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'secrets wajib array nama secret',
        isError: true,
      );
    }
    final names = rawSecrets.map((s) => s.toString()).toSet();
    final source = secretSource ?? () => Platform.environment;
    final values = <String, String>{};
    for (final name in names) {
      final value = source()[name];
      if (value == null || value.isEmpty) {
        return ToolResult(
          callId: '',
          content: 'Secret $name tidak tersedia (fail-closed)',
          isError: true,
        );
      }
      if (_badChars.split('').any(value.contains)) {
        return ToolResult(
          callId: '',
          content: 'Nilai secret $name mengandung karakter berbahaya',
          isError: true,
        );
      }
      final placeholder = '{{secret:$name}}';
      if (!command.contains(placeholder)) {
        return ToolResult(
          callId: '',
          content: 'Placeholder $placeholder tidak ada di command',
          isError: true,
        );
      }
      values[name] = value;
    }
    var substituted = command;
    values.forEach((name, value) {
      substituted = substituted.replaceAll('{{secret:$name}}', value);
    });
    final parts = substituted
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'command kosong',
        isError: true,
      );
    }
    try {
      final ProcessResult result;
      if (_commandRunner != null) {
        result = await _commandRunner!(parts);
      } else {
        result = await sandbox.run(
          parts,
          timeout: const Duration(seconds: 20),
        );
      }
      var out = (result.stdout as String?) ?? '';
      var err = (result.stderr as String?) ?? '';
      for (final e in values.entries) {
        out = out.replaceAll(e.value, '[REDACTED:${e.key}]');
        err = err.replaceAll(e.value, '[REDACTED:${e.key}]');
      }
      final buf = StringBuffer();
      if (out.isNotEmpty) buf.writeln(out);
      if (err.isNotEmpty) {
        buf.writeln('--- stderr ---');
        buf.writeln(err);
      }
      buf.write('exit: ${result.exitCode}');
      return ToolResult(
        callId: '',
        content: buf.toString(),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'secret_broker error: $e',
        isError: true,
      );
    }
  }
}
