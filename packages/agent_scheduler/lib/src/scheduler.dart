import 'dart:async';

import 'package:agent_core/agent_core.dart';

import 'job_store.dart';

typedef JobHandler = Future<void> Function(InboundMessage message, Job job);

/// Tick-loop scheduler (TASK-05-03). Source of truth = JobStore.
class Scheduler {
  Scheduler({
    required this.store,
    required this.onJob,
    this.tickInterval = const Duration(seconds: 20),
    this.onError,
  });

  final JobStore store;
  final JobHandler onJob;
  final Duration tickInterval;
  final void Function(Job job, Object error)? onError;

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
      // Runtime shutdown remains bounded; durable pending_run_at is replayed
      // by the next daemon if a handler did not complete before the deadline.
    }
  }

  Future<void> _runTick() async {
    try {
      final due = await store.claimDuePersisted(DateTime.now().toUtc());
      for (final job in due) {
        if (_stopped) break;
        if (!_runningIds.add(job.id)) continue;
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
            sessionKey: '${job.channel}:${job.userKey}:job:${job.id}',
            text: job.prompt,
            meta: {
              'job_id': job.id,
              'run_id': runId,
              'scheduled_at': scheduled.toUtc().toIso8601String(),
              'target_channel': job.channel,
            },
          );
          await onJob(msg, job);
          await store.completeRun(job.id, scheduled);
          _runIds.add(runId);
        } catch (error) {
          try { await store.releaseRun(job.id); } catch (_) {}
          try { onError?.call(job, error); } catch (_) {}
        } finally {
          _runningIds.remove(job.id);
        }
      }
      if (_runIds.length > 500) {
        final recent = _runIds.toList();
        _runIds
          ..clear()
          ..addAll(recent.sublist(recent.length - 200));
      }
    }
  }
}
