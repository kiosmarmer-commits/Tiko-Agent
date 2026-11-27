// Hermes fase-21: activity tracker (`agent/activity_tracker.py`) — first/
// last turn + hitungan turn per sesi, durabel antar restart, + `/activity`.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase21_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('recordTurn: first/last/count/failed tercatat dan persist atomic',
      () async {
    final tracker = ActivityTracker(
      persistPath: p.join(temp.path, 'activity.jsonl'),
    );
    final t1 = DateTime.utc(2026, 1, 1, 10);
    final t2 = DateTime.utc(2026, 1, 2, 11);
    await tracker.recordTurn('s1', 'cli', success: true, at: t1);
    await tracker.recordTurn('s1', 'cli', success: false, at: t2);
    expect(tracker['s1'], isNotNull);
    expect(tracker['s1']!.turnCount, 2);
    expect(tracker['s1']!.failedTurns, 1);
    expect(tracker['s1']!.firstTurnAt, t1);
    expect(tracker['s1']!.lastTurnAt, t2);

    // Roundtrip restart: load dari disk memulihkan record.
    final tracker2 = ActivityTracker(
      persistPath: p.join(temp.path, 'activity.jsonl'),
    );
    await tracker2.load();
    expect(tracker2['s1'], isNotNull);
    expect(tracker2['s1']!.turnCount, 2);
    expect(tracker2['s1']!.failedTurns, 1);
  });

  test('evict: melebihi maxSessions membuang sesi terlama masuk', () async {
    final tracker = ActivityTracker(
      persistPath: p.join(temp.path, 'activity.jsonl'),
      maxSessions: 2,
    );
    await tracker.recordTurn('a', 'cli', success: true);
    await tracker.recordTurn('b', 'cli', success: true);
    await tracker.recordTurn('c', 'cli', success: true);
    expect(tracker.records, hasLength(2));
    expect(tracker['a'], isNull);
    expect(tracker['c'], isNotNull);
  });

  test('recordTurn gagal IO tidak pernah melempar', () async {
    final tracker = ActivityTracker(
      persistPath: '/proc/tidak-ada/activity.jsonl',
    );
    await tracker.recordTurn('s1', 'cli', success: true);
    expect(tracker.records, hasLength(1));
  });

  test('activityFormatTerminal: kosong jujur; terisi menampilkan top sesi',
      () {
    expect(activityFormatTerminal(const []), contains('Belum ada'));

    final rec = ActivityRecord(
      session: 'cli:default',
      channel: 'cli',
      firstTurnAt: DateTime.utc(2026, 1, 1, 10),
      lastTurnAt: DateTime.utc(2026, 1, 3, 11),
      turnCount: 7,
      failedTurns: 2,
    );
    final out = activityFormatTerminal([rec], now: DateTime.utc(2026, 1, 3));
    expect(out, contains('cli:default'));
    expect(out, contains('7 turn'));
    expect(out, contains('2 gagal'));
    expect(out, contains('Sesi Aktif per Hari'));
  });
}
