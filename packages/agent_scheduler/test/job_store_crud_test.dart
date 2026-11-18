import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('update: mutasi parsial dan persist ke disk', () async {
    final path =
        '${Directory.systemTemp.createTempSync().path}/jobs_crud.json';
    final store = JobStore(persistPath: path);
    final job = store.add(
      cron: '0 * * * *',
      prompt: 'ping',
      channel: 'cli',
      userKey: 'u1',
    );

    final before = job.nextRun;
    final updated = store.update(
      job.id,
      prompt: 'pong',
      channel: 'http',
      enabled: false,
      missedPolicy: 'run_once',
    );
    expect(updated, isNotNull);
    expect(updated!.prompt, 'pong');
    expect(updated.channel, 'http');
    expect(updated.enabled, isFalse);
    expect(updated.missedPolicy, MissedPolicy.runOnce);
    expect(updated.cron, '0 * * * *');
    expect(updated.nextRun, before);

    await store.save();
    final loaded = JobStore(persistPath: path);
    await loaded.load();
    final job2 = loaded.get(job.id);
    expect(job2!.prompt, 'pong');
    expect(job2.channel, 'http');
    expect(job2.enabled, isFalse);
    expect(job2.missedPolicy, MissedPolicy.runOnce);
  });

  test('update: cron dan timezone menurunkan ulang nextRun', () {
    final store = JobStore();
    final job = store.add(
      cron: '0 5 * * *',
      prompt: 'p',
      channel: 'cli',
      userKey: 'u',
    );
    final updated = store.update(job.id, cron: '* * * * *', timezone: 'UTC');
    expect(updated!.cron, '* * * * *');
    expect(updated.timezone, 'UTC');
    final now = DateTime.now().toUtc();
    expect(updated.nextRun.isBefore(now.add(const Duration(minutes: 2))), isTrue);
  });

  test('update: null untuk id tidak dikenal, throw untuk nilai invalid', () {
    final store = JobStore();
    final job = store.add(
      cron: '* * * * *',
      prompt: 'p',
      channel: 'cli',
      userKey: 'u',
    );
    expect(store.update('tidak-ada', prompt: 'x'), isNull);
    expect(
      () => store.update(job.id, cron: 'tidak-valid'),
      throwsFormatException,
    );
    expect(
      () => store.update(job.id, prompt: '   '),
      throwsArgumentError,
    );
    expect(
      () => store.update(job.id, prompt: 'x' * 10001),
      throwsArgumentError,
    );
    expect(
      () => store.update(job.id, channel: ''),
      throwsArgumentError,
    );
    expect(
      () => store.update(job.id, missedPolicy: 'selalu'),
      throwsArgumentError,
    );
  });

  test('runNow: majukan nextRun, blok saat delivery-pending', () async {
    final store = JobStore();
    final job = store.add(
      cron: '0 12 * * *',
      prompt: 'p',
      channel: 'cli',
      userKey: 'u',
    );
    final before = job.nextRun;
    final run = store.runNow(job.id);
    expect(run, isNotNull);
    expect(
      run!.nextRun.isBefore(before),
      isTrue,
      reason: 'nextRun harus maju ke sekarang',
    );
    // job terklaim: seolah delivery sedang berjalan
    job.pendingRunAt = DateTime.now().toUtc();
    expect(store.runNow(job.id), isNull);
    job.pendingRunAt = null;
    job.deliveryRunId = 'run-1';
    expect(store.runNow(job.id), isNull);
    expect(store.runNow('tidak-ada'), isNull);
  });
}
