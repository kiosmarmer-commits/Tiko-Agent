import 'package:agent_core/agent_core.dart';

import 'redactor.dart';

/// Applies PRD §12 "context hygiene": redact secrets before anything reaches
/// the model, a user, memory or a log, and keep untrusted content inside its
/// `<untrusted_data>` envelope.
class SecuritySanitizer implements ContentSanitizer {
  SecuritySanitizer({SecretRedactor? redactor})
      : _redactor = redactor ?? SecretRedactor();

  final SecretRedactor _redactor;

  static const _open = '<untrusted_data';
  static const _close = '</untrusted_data>';

  /// Tools whose output may contain data not controlled by the agent.
  static bool isUntrustedTool(String name) =>
      ToolTrust.isUntrustedOutput(name);

  @override
  String output(String text) => _redactor.redact(text);

  @override
  String toolResult(ToolCall call, String content) {
    if (!isUntrustedTool(call.name)) return _redactor.redact(content);

    final trimmed = content.trim();
    if (trimmed.startsWith(_open) && trimmed.endsWith(_close)) {
      final headerEnd = trimmed.indexOf('>');
      // Only preserve a pre-existing envelope when its opening header is
      // structurally complete. Tool output is untrusted and may contain a
      // truncated or deliberately malformed opening marker.
      if (headerEnd > _open.length &&
          headerEnd < trimmed.length - _close.length) {
        final header = trimmed.substring(0, headerEnd + 1);
        final body = trimmed.substring(
          headerEnd + 1,
          trimmed.length - _close.length,
        );
        return '$header${_neutralize(_redactor.redact(body))}$_close';
      }
    }
    return _redactor.wrapUntrusted(call.name, _neutralize(content));
  }

  /// Prevents attacker-controlled text from closing or re-opening the envelope.
  String _neutralize(String s) => s
      .replaceAll('</untrusted_data', '<\\/untrusted_data')
      .replaceAll('<untrusted_data', '<\\untrusted_data');
}
