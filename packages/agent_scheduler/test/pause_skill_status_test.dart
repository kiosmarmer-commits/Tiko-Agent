import 'dart:convert';
import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('pause/resume: setPaused + claim melewati job paused', () {
    final store = JobStore();
    final job = store.add(
      cron: '* * * * *',
      prompt: 'p',
      channel: 'cli',
      userKey: 'u',
    );

    final paused = store.setPaused(job.id, true);
    expect(paused!.paused, isTrue);
    final due = store.claimDue(DateTime.now().toUtc().add(const Duration(minutes: 2)));
    expect(due.where((j) => j.id == job.id), isEmpty);

    final resumed = store.setPaused(job.id, false);
    expect(resumed!.paused, isFalse);
    final due2 = store.claimDue(DateTime.now().toUtc().add(const Duration(minutes: 2)));
    expect(due2.where((j) => j.id == job.id), hasLength(1));
  });

  test('setPaused: null untuk id tidak dikenal', () {
    final store = JobStore();
    expect(store.setPaused('tidak-ada', true), isNull);
  });

  test('pause + skill + status persist roundtrip', () async {
    final dir = Directory.systemTemp.createTempSync('tiko_p2_');
    try {
      final path = '${dir.path}/jobs_p2.json';
      final store = JobStore(persistPath: path);
      final job = store.add(
        cron: '0 * * * *',
        prompt: 'ringkasan',
        channel: 'cli',
        userKey: 'u1',
        skill: 'ringkas-berita',
      );
      store.setPaused(job.id, true);
      store.recordFailure(job.id, 'gagal menjalankanTurn');
      store.recordFailure(job.id, 'gagal lagi');
      await store.save();

      final loaded = JobStore(persistPath: path);
      await loaded.load();
      final job2 = loaded.get(job.id)!;
      expect(job2.paused, isTrue);
      expect(job2.skill, 'ringkas-berita');
      expect(job2.lastStatus, 'failed');
      expect(job2.lastError, contains('[CRON_FAILURE]'));
      expect(job2.lastError, contains('gagal lagi'));
      expect(job2.failureStreak, 2);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('recordSuccess: status ok + streak direset; last_error null', () {
    final store = JobStore();
    final job = store.add(cron: '0 * * * *', prompt: 'p', channel: 'cli', userKey: 'u');
    expect(store.recordSuccess(job.id), isTrue);
    expect(job.lastStatus, 'ok');
    expect(job.failureStreak, 0);
    expect(job.lastError, isNull);
    store.recordFailure(job.id, 'x');
    expect(store.recordSuccess(job.id), isTrue);
    expect(job.failureStreak, 0);
    expect(job.lastStatus, 'ok');
  });

  test('update: skill `all` menghapus lampiran; invalid dilempar', () {
    final store = JobStore();
    expect(
      () => store.add(
        cron: '0 * * * *',
        prompt: 'p',
        channel: 'cli',
        userKey: 'u',
        skill: 'dua-kata dalam',
      ),
      throwsArgumentError,
    );
    final job2 = store.add(cron: '0 * * * *', prompt: 'p', channel: 'cli', userKey: 'u', skill: 'ringkas');
    expect(store.get(job2.id)!.skill, 'ringkas');
    expect(store.update(job2.id, skill: 'all')!.skill, isNull);
    expect(
      () => store.update(job2.id, skill: ''),
      throwsArgumentError,
    );
    expect(
      () => store.update(job2.id, skill: 'dua kata'),
      throwsArgumentError,
    );
  });

  test('job.paused tidak diklaim walpo pendingRunAt null dan nextRun lewat', () async {
    final dir = Directory.systemTemp.createTempSync('tiko_p2_c_');
    try {
      final path = '${dir.path}/jobs.json';
      final raw = [
        {
          'id': 'p-j',
          'cron': '* * * * *',
          'prompt': 'p',
          'channel': 'cli',
          'user_key': 'u',
          'next_run': DateTime.now().toUtc()
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
          'paused': true,
        },
      ];
      File(path).writeAsStringSync(jsonEncode(raw));
      final store = JobStore(persistPath: path);
      await store.load();
      expect(store.loadError, isNull);
      final due = store.claimDue(DateTime.now().toUtc());
      expect(due, isEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
