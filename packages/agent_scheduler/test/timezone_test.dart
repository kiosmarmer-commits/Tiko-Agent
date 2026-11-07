import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('matchesAt evaluates an instant on the zone wall clock', () {
    final cron = CronExpression.parse('30 8 * * *');
    // 01:30 UTC == 08:30 WIB (Asia/Jakarta, UTC+7).
    expect(
      cron.matchesAt(DateTime.utc(2026, 11, 7, 1, 30),
          timezone: 'Asia/Jakarta'),
      isTrue,
    );
    // 01:30 UTC == 09:30 WITA (Asia/Makassar, UTC+8) - no match.
    expect(
      cron.matchesAt(DateTime.utc(2026, 11, 7, 1, 30),
          timezone: 'Asia/Makassar'),
      isFalse,
    );
  });

  test('matchesAt rejects unsupported zones (fail closed)', () {
    final cron = CronExpression.parse('* * * * *');
    expect(
      () => cron.matchesAt(DateTime.utc(2026), timezone: 'Mars/Olympus'),
      throwsFormatException,
    );
  });

  test('job keeps its timezone and computes nextRun on its wall clock', () {
    final store = JobStore();
    final job = store.add(
      cron: '0 7 * * *',
      prompt: 'pagi',
      channel: 'cli',
      userKey: 'u',
      timezone: 'Asia/Makassar',
    );
    expect(job.timezone, 'Asia/Makassar');
    expect(job.nextRun.isUtc, isTrue);
    final wall = job.nextRun.toUtc().add(const Duration(hours: 8));
    expect(wall.hour, 7);
    expect(wall.minute, 0);
    expect(
      () => store.add(
        cron: '0 7 * * *',
        prompt: 'x',
        channel: 'cli',
        userKey: 'u',
        timezone: 'America/New_York',
      ),
      throwsFormatException,
    );
  });

  test('timezone survives persistence roundtrip', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_tz_');
    final path = '${dir.path}/jobs.json';
    try {
      final store = JobStore(persistPath: path);
      await store.load();
      await store.addAndSave(
        cron: '0 7 * * *',
        prompt: 'roundtrip',
        channel: 'cli',
        userKey: 'u',
        timezone: 'Asia/Jayapura',
      );
      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      final job = reloaded.all.single;
      expect(job.timezone, 'Asia/Jayapura');
      final wall = job.nextRun.toUtc().add(const Duration(hours: 9));
      expect(wall.hour, 7);
      expect(wall.minute, 0);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('schedule_job tool stores timezone and lists it', () async {
    final store = JobStore();
    final session = Session(id: 's1', channel: 'cli', userKey: 'u1');
    final ctx = ToolContext(session: session, workspacePath: '.');
    final result = await ScheduleJobTool(store).run({
      'cron': '0 7 * * 1-5',
      'prompt': 'standup',
      'timezone': 'Asia/Jakarta',
    }, ctx);
    expect(result.isError, isFalse);
    final job = store.all.single;
    expect(job.timezone, 'Asia/Jakarta');
    final wall = job.nextRun.toUtc().add(const Duration(hours: 7));
    expect(wall.hour, 7);
    final listing = await ListJobsTool(store).run(const {}, ctx);
    expect(listing.content, contains('tz=Asia/Jakarta'));

    final bad = await ScheduleJobTool(store).run({
      'cron': '0 7 * * *',
      'prompt': 'x',
      'timezone': 'Europe/Berlin',
    }, ctx);
    expect(bad.isError, isTrue);
    expect(store.all, hasLength(1));
  });
}
