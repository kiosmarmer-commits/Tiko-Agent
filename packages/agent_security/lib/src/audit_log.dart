import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'redactor.dart';

/// JSONL daily audit log + optional SQLite-style in-memory buffer (AGD-07 §4).
class AuditLog {
  AuditLog({this.directory = 'logs', SecretRedactor? redactor})
    : redactor = redactor ?? SecretRedactor();

  final String directory;
  final SecretRedactor redactor;
  final List<Map<String, dynamic>> recent = [];

  Future<void> log({
    required String sessionId,
    required String tool,
    required Map<String, dynamic> args,
    required String risk,
    required String verdict,
    String? resultSummary,
    int? durationMs,
    String? error,
    bool taint = false,
  }) async {
    final entry = {
      'ts': DateTime.now().toUtc().toIso8601String(),
      'session': sessionId,
      'tool': tool,
      'args': redactor.redactMap(args),
      'risk': risk,
      'verdict': verdict,
      'result': resultSummary == null
          ? null
          : redactor.redact(
              resultSummary.length > 500
                  ? '${resultSummary.substring(0, 500)}…'
                  : resultSummary,
            ),
      'duration_ms': durationMs,
      'error': error,
      'taint': taint,
    };
    recent.add(entry);
    if (recent.length > 1000) recent.removeAt(0);

    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final day = DateTime.now()
        .toUtc()
        .toIso8601String()
        .substring(0, 10)
        .replaceAll('-', '');
    final file = File(p.join(directory, 'audit-$day.jsonl'));
    await file.writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append);
  }

  Future<void> rotate({int keepDays = 30}) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: keepDays));
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = p.basename(f.path);
      if (!name.startsWith('audit-') || !name.endsWith('.jsonl')) continue;
      final stamp = name.substring(6, 14); // YYYYMMDD
      try {
        final dt = DateTime.utc(
          int.parse(stamp.substring(0, 4)),
          int.parse(stamp.substring(4, 6)),
          int.parse(stamp.substring(6, 8)),
        );
        if (dt.isBefore(cutoff)) await f.delete();
      } catch (_) {}
    }
  }
}
