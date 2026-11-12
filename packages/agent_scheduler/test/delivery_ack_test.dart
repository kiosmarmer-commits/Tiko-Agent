import 'dart:async';
import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  Job forceDue(JobStore store, {String prompt = 'ping'}) {
    final job = store.add(
      cron: '* * * * *',
      prompt: prompt,
      channel: 'cli',
      userKey: 'u',
    );
    job.nextRun = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    return job;
  }

  test('awaitDelivery mengantre; completeDelivery meng-ack run', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_delivery_');
    try {
      final store = JobStore(persistPath: '${dir.path}/jobs.json');
      await store.load();
      final job = await store.addAndSave(
        cron: '* * * * *',
        prompt: 'out',
        channel: 'cli',
        userKey: 'u',
      );
      job.nextRun =
          DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await store.save();
      final due = await store.claimDuePersisted(DateTime.now().toUtc());
      final scheduled = due.single.scheduledAt!;
      await expectLater(
        () => store.awaitDelivery(job.id, '', 'x'),
        throwsArgumentError,
      );
      await store.awaitDelivery(job.id, 'run-1', 'hasil');
      expect(store.deliveryPending(job.id), isTrue);
      // Re-queue runId yang sama idempoten.
      await store.awaitDelivery(job.id, 'run-1', 'duplikat diabaikan');
      final claimed = await store.claimDueDeliveries(DateTime.now().toUtc());
      expect(claimed, hasLength(1));
      expect(claimed.single.deliveryAttempts, 1);
      await store.completeDelivery(job.id, 'run-1');
      expect(store.deliveryPending(job.id), isFalse);
      expect(job.pendingRunAt, isNull);
      expect(job.lastRun, scheduled);
      expect(job.deliveryState, 'delivered');
      expect(job.lastDeliveryAt, isNotNull);
      expect(
        await store.claimDueDeliveries(DateTime.now().toUtc()),
        isEmpty,
      );
      expect(await store.claimDuePersisted(DateTime.now().toUtc()), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('delivery pending tahan restart; agent tidak dijalankan ulang', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_delivery_rp_');
    try {
      final path = '${dir.path}/jobs.json';
      final store = JobStore(persistPath: path);
      await store.load();
      final job = await store.addAndSave(
        cron: '* * * * *',
        prompt: 'replay',
        channel: 'cli',
        userKey: 'u',
      );
      job.nextRun =
          DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await store.save();
      await store.claimDuePersisted(DateTime.now().toUtc());
      await store.awaitDelivery(job.id, 'run-replay', 'payload');

      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      var agentRuns = 0;
      var delivered = 0;
      final scheduler = Scheduler(
        store: reloaded,
        onJob: (message, job) async => agentRuns += 1,
        deliver: (job, runId, sessionKey, text) async => delivered += 1,
      );
      await scheduler.tick();
      expect(agentRuns, 0); // output sudah digenerate pra-restart
      expect(delivered, 1);
      final restored = reloaded.get(job.id)!;
      expect(restored.deliveryState, 'delivered');
      expect(restored.pendingRunAt, isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('scheduler dengan deliver: run di-ack hanya setelah gateway ack', () async {
    final store = JobStore();
    final job = forceDue(store);
    var agentRuns = 0;
    var delivered = 0;
    String? deliveredText;
    String? deliveredSession;
    final acked = <String>[];
    final scheduler = Scheduler(
      store: store,
      onJob: (message, job) async {
        agentRuns += 1;
        await store.awaitDelivery(
          job.id,
          message.meta['run_id'] as String,
          'hasil agent',
        );
      },
      deliver: (job, runId, sessionKey, text) async {
        delivered += 1;
        deliveredText = text;
        deliveredSession = sessionKey;
      },
      onDelivered: (job, runId, attempts) => acked.add(runId),
    );
    await scheduler.tick();
    expect(agentRuns, 1);
    expect(delivered, 1);
    expect(deliveredText, 'hasil agent');
    expect(deliveredSession, 'cli:u:job:${job.id}');
    expect(job.deliveryState, 'delivered');
    expect(job.pendingRunAt, isNull);
    await scheduler.tick();
    await scheduler.tick();
    expect(agentRuns, 1);
    expect(delivered, 1);
    expect(acked, hasLength(1));
  });

  test('delivery gagal di-retry dengan backoff lalu sukses', () async {
    final store = JobStore();
    final job = forceDue(store);
    var agentRuns = 0;
    var tries = 0;
    var retries = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (message, job) async {
        agentRuns += 1;
        await store.awaitDelivery(
          job.id,
          message.meta['run_id'] as String,
          'out',
        );
      },
      deliver: (job, runId, sessionKey, text) async {
        tries += 1;
        if (tries == 1) throw StateError('gateway 503');
      },
      deliveryBackoff: const [Duration.zero],
      maxDeliveryAttempts: 3,
      onDeliveryRetry: (job, runId, attempt, error) => retries += 1,
    );
    await scheduler.tick();
    expect(agentRuns, 1);
    expect(tries, 1);
    expect(retries, 1);
    expect(job.deliveryState, 'pending');
    expect(job.deliveryNextAt, isNotNull);
    expect(store.deliveryPending(job.id), isTrue);
    await scheduler.tick();
    expect(tries, 2);
    expect(retries, 1);
    expect(agentRuns, 1);
    expect(job.deliveryState, 'delivered');
    expect(job.deliveryAttempts, 2);
    expect(store.deliveryPending(job.id), isFalse);
  });

  test('retry habis: delivery failed tanpa replay agent', () async {
    final store = JobStore();
    final job = forceDue(store);
    var agentRuns = 0;
    var tries = 0;
    var failures = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (message, job) async {
        agentRuns += 1;
        await store.awaitDelivery(
          job.id,
          message.meta['run_id'] as String,
          'out',
        );
      },
      deliver: (job, runId, sessionKey, text) async {
        tries += 1;
        throw StateError('gateway down');
      },
      deliveryBackoff: const [Duration.zero],
      maxDeliveryAttempts: 2,
      onDeliveryFailed: (job, runId, attempts, error) => failures += 1,
    );
    await scheduler.tick();
    expect(tries, 1);
    expect(failures, 0);
    await scheduler.tick();
    expect(tries, 2);
    expect(failures, 1);
    expect(agentRuns, 1);
    expect(job.deliveryState, 'failed');
    expect(job.pendingRunAt, isNull);
    expect(job.lastRun, isNotNull);
    expect(job.deliveryError, contains('gateway down'));
    await scheduler.tick();
    expect(tries, 2);
    expect(agentRuns, 1);
    expect(store.deliveryPending(job.id), isFalse);
  });

  test('timeout gateway hang dihitung sebagai upaya gagal', () async {
    final store = JobStore();
    final job = forceDue(store);
    var tries = 0;
    var hang = true;
    final scheduler = Scheduler(
      store: store,
      onJob: (message, job) async {
        await store.awaitDelivery(
          job.id,
          message.meta['run_id'] as String,
          'out',
        );
      },
      deliver: (job, runId, sessionKey, text) async {
        tries += 1;
        if (hang) {
          await Completer<void>().future; // gateway tidak pernah ack
        }
      },
      deliveryTimeout: const Duration(milliseconds: 50),
      deliveryBackoff: const [Duration.zero],
      maxDeliveryAttempts: 5,
    );
    await scheduler.tick();
    expect(tries, 1);
    expect(job.deliveryState, 'pending');
    expect(job.deliveryError, contains('TimeoutException'));
    hang = false;
    await scheduler.tick();
    expect(tries, 2);
    expect(job.deliveryState, 'delivered');
  });

  test('mode legacy tanpa deliver menuntaskan run langsung', () async {
    final store = JobStore();
    final job = forceDue(store);
    var agentRuns = 0;
    final scheduler = Scheduler(
      store: store,
      onJob: (message, job) async => agentRuns += 1,
    );
    await scheduler.tick();
    expect(agentRuns, 1);
    expect(job.lastRun, isNotNull);
    expect(job.pendingRunAt, isNull);
    expect(job.deliveryState, 'none');
    expect(store.deliveryPending(job.id), isFalse);
  });

  test('field delivery round-trip JSON; file lama tetap termuat', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_delivery_json_');
    try {
      final path = '${dir.path}/jobs.json';
      final store = JobStore(persistPath: path);
      await store.load();
      final job = await store.addAndSave(
        cron: '* * * * *',
        prompt: 'rt',
        channel: 'cli',
        userKey: 'u',
      );
      job.nextRun =
          DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await store.save();
      await store.claimDuePersisted(DateTime.now().toUtc());
      await store.awaitDelivery(job.id, 'run-rt', 'payload');

      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      final restored = reloaded.get(job.id)!;
      expect(restored.deliveryRunId, 'run-rt');
      expect(restored.deliveryText, 'payload');
      expect(restored.deliveryState, 'pending');
      expect(restored.deliveryAttempts, 0);
      final due = await reloaded.claimDueDeliveries(DateTime.now().toUtc());
      expect(due, hasLength(1));
      expect(due.single.deliveryAttempts, 1);

      // File lama tanpa key delivery tetap termuat.
      await File(path).writeAsString(
        '[{"id":"legacy","cron":"* * * * *","prompt":"p","channel":"cli",'
        '"user_key":"u","next_run":"2026-11-09T00:00:00.000Z","enabled":true}]',
      );
      final legacy = JobStore(persistPath: path);
      await legacy.load();
      expect(legacy.get('legacy')!.deliveryState, 'none');

      // delivery_next_at invalid ditolak per entri.
      await File(path).writeAsString(
        '[{"id":"bad","cron":"* * * * *","prompt":"p","channel":"cli",'
        '"user_key":"u","next_run":"2026-11-09T00:00:00.000Z",'
        '"delivery_state":"pending","delivery_run_id":"r1",'
        '"delivery_next_at":"not-a-date"}]',
      );
      final broken = JobStore(persistPath: path);
      await broken.load();
      expect(broken.loadError, isNotNull);

      // Status pending tanpa delivery_run_id ditolak.
      await File(path).writeAsString(
        '[{"id":"bad2","cron":"* * * * *","prompt":"p","channel":"cli",'
        '"user_key":"u","next_run":"2026-11-09T00:00:00.000Z",'
        '"delivery_state":"pending"}]',
      );
      final broken2 = JobStore(persistPath: path);
      await broken2.load();
      expect(broken2.loadError, isNotNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('P0-4: crash di tengah pengiriman — upaya ter-persist sebelum kirim, '
      'delivery di-replay setelah restart tanpa menjalankan ulang agent', () async {
    final dir = await Directory.systemTemp.createTemp('tiko_delivery_crash_');
    try {
      final path = '${dir.path}/jobs.json';
      final store = JobStore(persistPath: path);
      await store.load();
      final job = await store.addAndSave(
        cron: '* * * * *',
        prompt: 'crash mid delivery',
        channel: 'cli',
        userKey: 'u',
      );
      job.nextRun =
          DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await store.save();
      await store.claimDuePersisted(DateTime.now().toUtc());
      await store.awaitDelivery(job.id, 'run-crash', 'output penting');

      // Pengiriman diklaim (upaya dihitung + dipersist), lalu proses mati
      // sebelum deliver() selesai.
      final claimed = await store.claimDueDeliveries(DateTime.now().toUtc());
      expect(claimed.single.deliveryAttempts, 1);

      final reloaded = JobStore(persistPath: path);
      await reloaded.load();
      var agentRuns = 0;
      final deliveries = <int>[];
      final scheduler = Scheduler(
        store: reloaded,
        onJob: (message, job) async => agentRuns += 1,
        deliver: (job, runId, sessionKey, text) async {
          deliveries.add(job.deliveryAttempts);
        },
      );
      await scheduler.tick();
      expect(agentRuns, 0); // agent tidak dijalankan ulang
      // Upaya pra-crash (1) tetap terhitung: pengiriman ulang adalah upaya
      // ke-2, membuktikan penghitung at-least-once bertahan lintas crash.
      expect(deliveries, [2]);
      final restored = reloaded.get(job.id)!;
      expect(restored.deliveryState, 'delivered');
      expect(restored.pendingRunAt, isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
