import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tiko_dup_policy_');
    path = '${dir.path}/jobs.json';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Simulasi crash di tengah pengiriman: output diantre, diklaim
  /// (attempts 1, next_at null), lalu store ditutup tanpa ack.
  Future<Job> crashMidSend(JobStore store) async {
    final job = await store.addAndSave(
      cron: '* * * * *',
      prompt: 'laporan',
      channel: 'cli',
      userKey: 'u',
    );
    job.nextRun = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await store.save();
    await store.claimDuePersisted(DateTime.now().toUtc());
    await store.awaitDelivery(job.id, 'run-1', 'hasil');
    final claimed = await store.claimDueDeliveries(DateTime.now().toUtc());
    expect(claimed, hasLength(1));
    expect(claimed.single.deliveryAttempts, 1);
    expect(claimed.single.deliveryNextAt, isNull);
    return job;
  }

  test('inFlightDeliveries mendeteksi delivery yang mati di tengah kirim',
      () async {
    final store = JobStore(persistPath: path);
    await store.load();
    await crashMidSend(store);

    final reloaded = JobStore(persistPath: path);
    await reloaded.load();
    final inflight = reloaded.inFlightDeliveries();
    expect(inflight, hasLength(1));
    expect(inflight.single.deliveryRunId, 'run-1');
  });

  test('policy resend (default): delivery dikirim ulang di tick berikutnya',
      () async {
    final store = JobStore(persistPath: path);
    await store.load();
    await crashMidSend(store);

    var sends = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (_, __) async {},
      tickInterval: const Duration(milliseconds: 50),
      deliver: (_, __, ___, ____) async {
        sends++;
      },
      deliveryBackoff: const [Duration(milliseconds: 10)],
    );
    scheduler.start();
    addTearDown(scheduler.shutdown);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sends, 1);
  });

  test('policy review: tidak dikirim ulang, ditandai gagal permanen',
      () async {
    final store = JobStore(persistPath: path);
    await store.load();
    final job = await crashMidSend(store);

    final failures = <String>[];
    var sends = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (_, __) async {},
      tickInterval: const Duration(milliseconds: 50),
      deliver: (_, __, ___, ____) async {
        sends++;
      },
      duplicatePolicy: DeliveryDuplicatePolicy.review,
      onDeliveryFailed: (job, runId, attempt, error) =>
          failures.add('$job:${job.id}:$runId'),
    );
    scheduler.start();
    addTearDown(scheduler.shutdown);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sends, 0);
    expect(failures, hasLength(1));
    expect(job.deliveryState, 'failed');
    expect(job.deliveryError, contains('duplicate_policy=review'));
    expect(job.deliveryError, contains('mungkin sudah terkirim'));
    expect(store.deliveryPending(job.id), isFalse);
  });

  test('policy review: delivery baru (belum diklaim) tidak terdampak',
      () async {
    final store = JobStore(persistPath: path);
    await store.load();
    final job = await store.addAndSave(
      cron: '* * * * *',
      prompt: 'baru',
      channel: 'cli',
      userKey: 'u',
    );
    job.nextRun = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await store.save();
    await store.claimDuePersisted(DateTime.now().toUtc());
    await store.awaitDelivery(job.id, 'run-2', 'payload');
    expect(store.inFlightDeliveries(), isEmpty);

    var sends = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (_, __) async {},
      tickInterval: const Duration(milliseconds: 50),
      deliver: (_, __, ___, ____) async {
        sends++;
      },
      duplicatePolicy: DeliveryDuplicatePolicy.review,
    );
    scheduler.start();
    addTearDown(scheduler.shutdown);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sends, 1);
    expect(job.deliveryState, 'delivered');
  });

  test('deliveryIdempotencyKey deterministik: run sama → key sama, run '
      'beda → key beda', () {
    expect(deliveryIdempotencyKey('job-1', 'run-9'), 'tik-job-1_run-9');
    expect(
      deliveryIdempotencyKey('job-1', 'run-9'),
      deliveryIdempotencyKey('job-1', 'run-9'),
      reason: 'retry/crash recovery dari run yang sama harus menghasilkan '
          'kunci identik agar dedup server-side bekerja',
    );
    expect(
      deliveryIdempotencyKey('job-1', 'run-9'),
      isNot(deliveryIdempotencyKey('job-1', 'run-10')),
    );
    expect(
      deliveryIdempotencyKey('job-1', 'run-9'),
      isNot(deliveryIdempotencyKey('job-2', 'run-9')),
    );
  });
}
