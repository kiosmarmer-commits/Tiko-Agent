/// Automatic secret redaction (AGD-07 C-05, PRD §12).
class SecretRedactor {
  /// Token-shaped secrets (no Luhn check needed).
  static final patterns = <RegExp>[
    // OpenAI legacy/project keys and Anthropic keys (contain '-' and '_').
    RegExp(r'sk-(?:ant-|proj-|svcacct-)?[A-Za-z0-9_\-]{20,}'),
    RegExp(r'ghp_[a-zA-Z0-9]{20,}'),
    RegExp(r'github_pat_[A-Za-z0-9_]{20,}'),
    RegExp(r'xox[baprs]-[a-zA-Z0-9-]{10,}'),
    RegExp(r'AKIA[0-9A-Z]{16}'),
    RegExp(r'AIza[0-9A-Za-z_\-]{35}'),
    // Telegram bot token: <bot id>:<35 chars>.
    RegExp(r'\b\d{8,10}:[A-Za-z0-9_\-]{35}\b'),
    RegExp(
      r'''(api[_-]?key|token|secret|password)\s*[:=]\s*["']?([^\s"']+)''',
      caseSensitive: false,
    ),
    RegExp(r'Bearer\s+[a-zA-Z0-9\-._~+/]+=*'),
  ];

  /// Candidate card numbers; only redacted when the Luhn checksum passes so
  /// that epoch-millisecond timestamps and other long ids are left intact.
  static final _pan = RegExp(r'\b\d{13,19}\b');

  static bool luhnValid(String digits) {
    var sum = 0;
    var alt = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var d = digits.codeUnitAt(i) - 48;
      if (d < 0 || d > 9) return false;
      if (alt) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
      alt = !alt;
    }
    return sum % 10 == 0;
  }

  String redact(String input) {
    var s = input;
    for (final p in patterns) {
      s = s.replaceAllMapped(p, (m) {
        if (m.groupCount >= 2 && m.group(1) != null) {
          return '${m.group(1)}=***REDACTED***';
        }
        return '***REDACTED***';
      });
    }
    s = s.replaceAllMapped(
      _pan,
      (m) => luhnValid(m.group(0)!) ? '***REDACTED***' : m.group(0)!,
    );
    return s;
  }

  Object? _redactValue(Object? v) {
    if (v is String) return redact(v);
    if (v is Map) return redactMap(Map<String, dynamic>.from(v));
    if (v is List) return v.map(_redactValue).toList();
    return v;
  }

  Map<String, dynamic> redactMap(Map<String, dynamic> m) {
    return {for (final e in m.entries) e.key: _redactValue(e.value)};
  }

  /// Wrap untrusted content for prompts (C-01).
  String wrapUntrusted(String source, String content) =>
      '<untrusted_data source="$source">\n${redact(content)}\n</untrusted_data>';
}
