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
}
