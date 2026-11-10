import 'dart:async';

import 'package:agent_core/agent_core.dart';

import 'job_store.dart';

typedef JobHandler = Future<void> Function(InboundMessage message, Job job);

/// Mengirim satu output job yang diantre ke channel tujuannya. Melempar
/// (atau melewati batas delivery timeout) berarti gateway menolak atau
/// tidak pernah meng-ack pesan; scheduler me-retry dengan backoff.
typedef DeliveryHandler = Future<void> Function(
  Job job,
  String runId,
  String sessionKey,
  String text,
);

/// Tick-loop scheduler (TASK-05-03). Source of truth = JobStore.
///
/// Tanpa [deliver] kontrak tidak berubah: run selesai begitu giliran agent
/// sukses. Dengan [deliver], runtime mengantre output lewat
/// [JobStore.awaitDelivery] setelah giliran sukses, dan run hanya di-ack
/// setelah sink mengonfirmasi delivery. Kegagalan delivery di-retry dengan
/// backoff sampai [maxDeliveryAttempts]; setelah itu delivery ditandai
/// gagal permanen dan giliran agent tidak pernah di-replay.
class Scheduler {
  Scheduler({
    required this.store,
    required this.onJob,
    this.tickInterval = const Duration(seconds: 20),
    this.onError,
    this.deliver,
    this.maxDeliveryAttempts = 5,
    this.deliveryBackoff = const [
      Duration(seconds: 20),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(hours: 1),
    ],
    this.deliveryTimeout = const Duration(seconds: 30),
    this.onDelivered,
    this.onDeliveryRetry,
    this.onDeliveryFailed,
  });

  final JobStore store;
  final JobHandler onJob;
  final Duration tickInterval;
  final void Function(Job job, Object error)? onError;

  /// Sink delivery outbound; null mempertahankan kontrak ack lama.
  final DeliveryHandler? deliver;
  final int maxDeliveryAttempts;
  final List<Duration> deliveryBackoff;
  final Duration deliveryTimeout;
  final void Function(Job job, String runId, int attempts)? onDelivered;
  final void Function(Job job, String runId, int attempt, Object error)?
      onDeliveryRetry;
  final void Function(Job job, String runId, int attempts, Object error)?
      onDeliveryFailed;

  Timer? _timer;
  final _runningIds = <String>{};
  final _runIds = <String>{};
  bool _tickInFlight = false;
  bool _stopped = false;
  Future<void>? _activeTick;

  void start() {
    if (_timer != null) return;
    _stopped = false;
    _timer = Timer.periodic(tickInterval, (_) {
      unawaited(tick().catchError((Object _) {
        // Timer callback must not leak an unhandled asynchronous error.
      }));
    });
    unawaited(tick().catchError((Object _) {}));
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick() {
    if (_stopped || _tickInFlight) return Future<void>.value();
    _tickInFlight = true;
    final work = _runTick();
    _activeTick = work;
    return work.whenComplete(() {
      if (identical(_activeTick, work)) _activeTick = null;
      _tickInFlight = false;
    });
  }

  Future<void> shutdown({Duration timeout = const Duration(seconds: 30)}) async {
    stop();
    final active = _activeTick;
    if (active == null) return;
    try {
      await active.timeout(timeout);
    } on TimeoutException {
      // Runtime shutdown remains bounded; durable pending_run_at and the
      // queued delivery are replayed by the next daemon.
    }
  }

  Future<void> _runTick() async {
    final due = await store.claimDuePersisted(DateTime.now().toUtc());
    for (final job in due) {
      if (_stopped) break;
      if (!_runningIds.add(job.id)) continue;
      if (store.deliveryPending(job.id)) {
        // Output sudah digenerate di tick sebelumnya; loop delivery di bawah
        // yang memegang run ini sampai gateway meng-ack.
        _runningIds.remove(job.id);
        continue;
      }
      final scheduled = job.scheduledAt ?? job.pendingRunAt ?? job.nextRun;
      final runId = '${job.id}@${scheduled.toUtc().toIso8601String()}';
      if (_runIds.contains(runId)) {
        _runningIds.remove(job.id);
        continue;
      }
      try {
        final msg = InboundMessage(
          channel: 'scheduler',
          userKey: job.userKey,
          sessionKey: _sessionKey(job),
          text: job.prompt,
          meta: {
            'job_id': job.id,
            'run_id': runId,
            'scheduled_at': scheduled.toUtc().toIso8601String(),
            'target_channel': job.channel,
          },
        );
        await onJob(msg, job);
        if (!store.deliveryPending(job.id)) {
          await store.completeRun(job.id, scheduled);
          _runIds.add(runId);
        }
        // else: runtime sudah mengantre output secara durabel; loop delivery
        // di bawah menuntaskan run saat gateway meng-ack.
      } catch (error) {
        try { await store.releaseRun(job.id); } catch (_) {}
        try { onError?.call(job, error); } catch (_) {}
      } finally {
        _runningIds.remove(job.id);
      }
    }
    await _runDeliveries();
    if (_runIds.length > 500) {
      final recent = _runIds.toList();
      _runIds
        ..clear()
        ..addAll(recent.sublist(recent.length - 200));
    }
  }

  String _sessionKey(Job job) =>
      '${job.channel}:${job.userKey}:job:${job.id}';

  Future<void> _runDeliveries() async {
    final sink = deliver;
    if (sink == null) return;
    final due = await store.claimDueDeliveries(DateTime.now().toUtc());
    for (final job in due) {
      if (_stopped) break;
      if (!_runningIds.add('delivery:${job.id}')) continue;
      final runId = job.deliveryRunId!;
      final text = job.deliveryText ?? '';
      final attempt = job.deliveryAttempts;
      try {
        await sink(job, runId, _sessionKey(job), text).timeout(deliveryTimeout);
        await store.completeDelivery(job.id, runId);
        try { onDelivered?.call(job, runId, attempt); } catch (_) {}
      } catch (error) {
        if (attempt >= maxDeliveryAttempts) {
          try {
            await store.failDeliveryPermanently(job.id, runId, '$error');
          } catch (_) {}
          try {
            onDeliveryFailed?.call(job, runId, attempt, error);
          } catch (_) {}
        } else {
          final delay =
              deliveryBackoff[attempt.clamp(1, deliveryBackoff.length) - 1];
          try {
            await store.scheduleDeliveryRetry(
              job.id,
              runId,
              delay,
              error: '$error',
            );
          } catch (_) {}
          try {
            onDeliveryRetry?.call(job, runId, attempt, error);
          } catch (_) {}
        }
      } finally {
        _runningIds.remove('delivery:${job.id}');
      }
    }
  }
}
