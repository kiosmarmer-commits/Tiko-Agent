import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('cron parse and match', () {
    final c = CronExpression.parse('*/5 * * * *');
    final t = DateTime.utc(2026, 11, 4, 10, 10);
    expect(c.matches(t), isTrue);
    final t2 = DateTime.utc(2026, 11, 4, 10, 11);
    expect(c.matches(t2), isFalse);
  });

  test('nextAfter advances', () {
    final c = CronExpression.parse('0 * * * *');
    final from = DateTime.utc(2026, 11, 4, 10, 15);
    final next = c.nextAfter(from);
    expect(next.minute, 0);
    expect(next.isAfter(from), isTrue);
  });

  test('claimDue run_once', () {
    final store = JobStore();
    final job = store.add(
      cron: '* * * * *',
      prompt: 'ping',
      channel: 'cli',
      userKey: 'u',
    );
    // force due
    job.nextRun = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final due = store.claimDue(DateTime.now().toUtc());
    expect(due, hasLength(1));
    expect(
      job.nextRun.isAfter(
        DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
      isTrue,
    );
  });


  test('cron rejects invalid values, zero steps and malformed ranges', () {
    expect(() => CronExpression.parse('60 * * * *'), throwsFormatException);
    expect(() => CronExpression.parse('*/0 * * * *'), throwsFormatException);
    expect(() => CronExpression.parse('10-2 * * * *'), throwsFormatException);
    expect(() => CronExpression.parse('1,,2 * * * *'), throwsFormatException);
  });

  test('nextAfter uses Asia/Jakarta wall clock and returns UTC instant', () {
    final cron = CronExpression.parse('0 7 * * *');
    final from = DateTime.utc(2026, 11, 7, 0, 30); // 07:30 WIB
    final next = cron.nextAfter(from, timezone: 'Asia/Jakarta');
    expect(next.isUtc, isTrue);
    expect(next, DateTime.utc(2026, 11, 8, 0));
    expect(
      () => cron.nextAfter(from, timezone: 'America/New_York'),
      throwsFormatException,
    );
  });

  test('durable claim replays pending run until acknowledged', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_jobs_');
    final path = '${dir.path}/jobs.json';
    try {
      final store = JobStore(persistPath: path);
      await store.load();
      final job = await store.addAndSave(
        cron: '* * * * *',
        prompt: 'durable',
        channel: 'cli',
        userKey: 'u',
      );
      job.nextRun = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await store.save();
      final due = await store.claimDuePersisted(DateTime.now().toUtc());
      expect(due, hasLength(1));
      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      final replay = await reloaded.claimDuePersisted(DateTime.now().toUtc());
      expect(replay, hasLength(1));
      expect(replay.single.id, job.id);
      await reloaded.completeRun(job.id, replay.single.scheduledAt!);
      expect((await reloaded.claimDuePersisted(DateTime.now().toUtc())), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('invalid cron throws', () {
    expect(() => CronExpression.parse('bad'), throwsFormatException);
  });
  test('cron uses standard OR semantics when both day fields are restricted', () {
    final cron = CronExpression.parse('0 9 13 * 1');
    // Monday Jan 12 matches weekday; Tuesday Jan 13 matches day-of-month.
    expect(cron.matches(DateTime.utc(2026, 1, 12, 9)), isTrue);
    expect(cron.matches(DateTime.utc(2026, 1, 13, 9)), isTrue);
    // Wednesday Jan 14 matches neither field.
    expect(cron.matches(DateTime.utc(2026, 1, 14, 9)), isFalse);
  });

}
