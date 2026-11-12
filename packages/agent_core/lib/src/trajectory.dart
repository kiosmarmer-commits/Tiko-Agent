import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Append-only trajectory JSONL for self-learning datasets (AGD-06 SL-08).
class TrajectoryLogger {
  TrajectoryLogger({this.directory = 'data/trajectories'});

  final String directory;

  Future<void> logTurn({
    required String sessionId,
    required String input,
    required String output,
    required List<String> tools,
    int? latencyMs,
    bool success = true,
  }) async {
    await Directory(directory).create(recursive: true);
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final file = File(p.join(directory, 'traj-$day.jsonl'));
    final entry = {
      'ts': DateTime.now().toUtc().toIso8601String(),
      'session': sessionId,
      'input': input,
      'output': output.length > 4000 ? '${output.substring(0, 4000)}…' : output,
      'tools': tools,
      'latency_ms': latencyMs,
      'success': success,
    };
    await file.writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append);
  }

  /// Exports stored trajectories with a privacy guard (P2): secrets are
  /// redacted by default patterns, sessions can be excluded, and content is
  /// capped. Returns the number of exported entries.
  ///
  /// The export is a new standalone JSONL file; the source logs are never
  /// modified. [excludeSessions] drops entire sessions (e.g. opt-out ids),
  /// [customRedactor] applies an additional caller-provided pass.
  Future<int> exportForTraining({
    required String outputPath,
    Set<String> excludeSessions = const {},
    int maxFieldChars = 2000,
    bool redactSecrets = true,
    Object? Function(String)? customRedactor,
  }) async {
    final dir = Directory(directory);
    if (!dir.existsSync()) return 0;
    await Directory(p.dirname(outputPath)).create(recursive: true);
    final out = File(outputPath);
    final sink = out.openWrite(mode: FileMode.writeOnly);
    var exported = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        await for (final line in entity
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          Map<String, dynamic> entry;
          try {
            entry = jsonDecode(trimmed) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          final session = entry['session']?.toString() ?? '';
          if (excludeSessions.contains(session)) continue;
          if (redactSecrets) {
            entry['input'] = redactSecretText(
                _cap(entry['input']?.toString() ?? '', maxFieldChars));
            entry['output'] = redactSecretText(
                _cap(entry['output']?.toString() ?? '', maxFieldChars));
          } else {
            entry['input'] = _cap(entry['input']?.toString() ?? '', maxFieldChars);
            entry['output'] = _cap(entry['output']?.toString() ?? '', maxFieldChars);
          }
          if (customRedactor != null) {
            final redacted = customRedactor(jsonEncode(entry));
            sink.write('$redacted\n');
          } else {
            sink.write('${jsonEncode(entry)}\n');
          }
          exported++;
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return exported;
  }

  String _cap(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
}

/// Default secret patterns redacted before any trajectory leaves the process:
/// OpenAI-style keys, GitHub tokens, AWS keys, bearer headers, private key
/// blocks, and generic `KEY=value` assignments with long values.
final _secretPatterns = <(RegExp, String)>[
  (RegExp(r'sk-[A-Za-z0-9_-]{8,}'), 'sk-<REDACTED>'),
  (RegExp(r'gh[pousr]_[A-Za-z0-9]{20,}'), 'gh_<REDACTED>'),
  (RegExp(r'AKIA[0-9A-Z]{16}'), 'AKIA<REDACTED>'),
  (
    RegExp(r'bearer\s+[A-Za-z0-9._-]{8,}', caseSensitive: false),
    'Bearer <REDACTED>',
  ),
  (
    RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
    '<REDACTED PRIVATE KEY>',
  ),
  (
    RegExp(
      r'(api[_-]?key|token|secret|password)(["\x27]?\s*[:=]\s*["\x27]?)([^\s"\x27]{8,})',
      caseSensitive: false,
    ),
    r'$1$2<REDACTED>',
  ),
];

/// Redacts known secret shapes from [text]. Used by trajectory export and
/// available to any export path that must be privacy-safe.
String redactSecretText(String text) {
  var result = text;
  for (final (pattern, replacement) in _secretPatterns) {
    result = result.replaceAllMapped(
      pattern,
      (m) => replacement.replaceAllMapped(
            RegExp(r'\$(\d)'),
            (t) => m.group(int.parse(t.group(1)!)) ?? '',
          ),
    );
  }
  return result;
}
