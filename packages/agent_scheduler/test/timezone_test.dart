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

  test('matchesAt rejects unknown zones (fail closed)', () {
    final cron = CronExpression.parse('* * * * *');
    expect(
      () => cron.matchesAt(DateTime.utc(2026), timezone: 'Mars/Olympus'),
      throwsFormatException,
    );
  });

  test('matchesAt follows US DST transitions (America/New_York)', () {
    final cron = CronExpression.parse('0 3 * * *');
    // Spring-forward: Minggu kedua Maret (8 Mar 2026) jam 02:00 lokal
    // menjadi 03:00 EDT == 07:00 UTC.
    expect(
      cron.matchesAt(DateTime.utc(2026, 3, 8, 7),
          timezone: 'America/New_York'),
      isTrue,
    );
    // Sehari sebelum transisi: 03:00 EST == 08:00 UTC.
    expect(
      cron.matchesAt(DateTime.utc(2026, 3, 7, 8),
          timezone: 'America/New_York'),
      isTrue,
    );
    // Musim dingin: 07:00 UTC = 02:00 EST, bukan 03:00.
    expect(
      cron.matchesAt(DateTime.utc(2026, 2, 8, 7),
          timezone: 'America/New_York'),
      isFalse,
    );
  });

  test('matchesAt follows EU DST transitions (Europe/Berlin)', () {
    final cron = CronExpression.parse('0 3 * * *');
    // CET -> CEST pada Minggu terakhir Maret (29 Mar 2026) 01:00 UTC:
    // 03:00 CEST == 01:00 UTC.
    expect(
      cron.matchesAt(DateTime.utc(2026, 3, 29, 1), timezone: 'Europe/Berlin'),
      isTrue,
    );
    // Sehari sebelumnya 03:00 CET == 02:00 UTC.
    expect(
      cron.matchesAt(DateTime.utc(2026, 3, 28, 2), timezone: 'Europe/Berlin'),
      isTrue,
    );
    // Setelah transisi 02:00 UTC = 04:00 CEST, bukan 03:00.
    expect(
      cron.matchesAt(DateTime.utc(2026, 3, 29, 2), timezone: 'Europe/Berlin'),
      isFalse,
    );
  });

  test('nextAfter shifts one hour across the US spring-forward', () {
    final cron = CronExpression.parse('0 9 * * *');
    // Sabtu 7 Mar 2026 12:00 UTC = 07:00 EST: berikutnya 09:00 EST.
    final before = cron.nextAfter(
      DateTime.utc(2026, 3, 7, 12),
      timezone: 'America/New_York',
    );
    expect(before, DateTime.utc(2026, 3, 7, 14));
    // Minggu 8 Mar 2026 11:00 UTC = 07:00 EDT (setelah transisi):
    // 09:00 EDT == 13:00 UTC, satu jam lebih awal dari musim dingin.
    final after = cron.nextAfter(
      DateTime.utc(2026, 3, 8, 11),
      timezone: 'America/New_York',
    );
    expect(after, DateTime.utc(2026, 3, 8, 13));
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

    // Zona IANA dengan DST kini diterima; jam dinding tetap 07:00 lokal.
    final nyJob = store.add(
      cron: '0 7 * * *',
      prompt: 'morning',
      channel: 'cli',
      userKey: 'u',
      timezone: 'America/New_York',
    );
    expect(nyJob.timezone, 'America/New_York');
    expect(Tz.wallFromUtc(nyJob.nextRun, 'America/New_York').hour, 7);
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

  test('IANA zone with DST survives persistence roundtrip', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_tz_dst_');
    final path = '${dir.path}/jobs.json';
    try {
      final store = JobStore(persistPath: path);
      await store.load();
      await store.addAndSave(
        cron: '0 7 * * *',
        prompt: 'berlin',
        channel: 'cli',
        userKey: 'u',
        timezone: 'Europe/Berlin',
      );
      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      final job = reloaded.all.single;
      expect(job.timezone, 'Europe/Berlin');
      expect(Tz.wallFromUtc(job.nextRun, 'Europe/Berlin').hour, 7);
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

    // Zona IANA dengan DST kini valid.
    final eu = await ScheduleJobTool(store).run({
      'cron': '0 7 * * *',
      'prompt': 'x',
      'timezone': 'Europe/Berlin',
    }, ctx);
    expect(eu.isError, isFalse);
    expect(store.all, hasLength(2));

    // Zona tak dikenal tetap gagal dan tidak menulis job.
    final bad = await ScheduleJobTool(store).run({
      'cron': '0 7 * * *',
      'prompt': 'x',
      'timezone': 'Mars/Olympus',
    }, ctx);
    expect(bad.isError, isTrue);
    expect(store.all, hasLength(2));
  });
}
