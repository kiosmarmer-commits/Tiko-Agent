import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'cron.dart';

enum MissedPolicy { skip, runOnce, catchUp }

/// Nilai sah untuk [Job.deliveryState].
const _deliveryStates = <String>{'none', 'pending', 'delivered', 'failed'};

class Job {
  Job({
    required this.id,
    required this.cron,
    required this.prompt,
    required this.channel,
    required this.userKey,
    required this.nextRun,
    this.lastRun,
    this.enabled = true,
    this.missedPolicy = MissedPolicy.runOnce,
    this.timezone = 'UTC',
    this.pendingRunAt,
    this.scheduledAt,
    this.deliveryRunId,
    this.deliveryText,
    this.deliveryAttempts = 0,
    this.deliveryNextAt,
    this.lastDeliveryAt,
    this.deliveryError,
    this.deliveryState = 'none',
  });

  final String id;
  String cron;
  String prompt;
  String channel;
  String userKey;
  DateTime nextRun;
  DateTime? lastRun;
  bool enabled;
  MissedPolicy missedPolicy;
  String timezone;

  /// Durable at-least-once claim. Cleared only after handler success.
  DateTime? pendingRunAt;

  /// Runtime copy of the scheduled instant that the current claim represents.
  DateTime? scheduledAt;

  /// Durable outbound-delivery tracking. `deliveryRunId != null` marks an
  /// agent output that is queued and waiting for the target gateway to
  /// acknowledge delivery; the scheduled run stays claimed until then.
  String? deliveryRunId;
  String? deliveryText;
  int deliveryAttempts = 0;
  DateTime? deliveryNextAt;
  DateTime? lastDeliveryAt;
  String? deliveryError;
  String deliveryState = 'none'; // none | pending | delivered | failed

  Map<String, dynamic> toJson() => {
    'id': id,
    'cron': cron,
    'prompt': prompt,
    'channel': channel,
    'user_key': userKey,
    'next_run': nextRun.toUtc().toIso8601String(),
    'last_run': lastRun?.toUtc().toIso8601String(),
    'enabled': enabled,
    'missed_policy': missedPolicy.name,
    'timezone': timezone,
    'pending_run_at': pendingRunAt?.toUtc().toIso8601String(),
    'delivery_run_id': deliveryRunId,
    'delivery_text': deliveryText,
    'delivery_attempts': deliveryAttempts,
    'delivery_next_at': deliveryNextAt?.toUtc().toIso8601String(),
    'last_delivery_at': lastDeliveryAt?.toUtc().toIso8601String(),
    'delivery_error': deliveryError,
    'delivery_state': deliveryState,
  };

  factory Job.fromJson(Map<String, dynamic> m) {
    final policyName = m['missed_policy'] as String? ?? 'runOnce';
    MissedPolicy? policy;
    for (final candidate in MissedPolicy.values) {
      if (candidate.name == policyName ||
          candidate.name == policyName.replaceAll('_', '')) {
        policy = candidate;
        break;
      }
    }
    if (policy == null) {
      throw FormatException('invalid missed_policy: $policyName');
    }
    final rawPending = m['pending_run_at'];
    final parsedPending = rawPending == null
        ? null
        : rawPending is String ? DateTime.tryParse(rawPending)?.toUtc() : null;
    if (rawPending != null && parsedPending == null) {
      throw const FormatException('invalid pending_run_at');
    }
    final rawDeliveryNext = m['delivery_next_at'];
    final parsedDeliveryNext = rawDeliveryNext == null
        ? null
        : rawDeliveryNext is String
            ? DateTime.tryParse(rawDeliveryNext)?.toUtc()
            : null;
    if (rawDeliveryNext != null && parsedDeliveryNext == null) {
      throw const FormatException('invalid delivery_next_at');
    }
    final rawLastDelivery = m['last_delivery_at'];
    final parsedLastDelivery = rawLastDelivery == null
        ? null
        : rawLastDelivery is String
            ? DateTime.tryParse(rawLastDelivery)?.toUtc()
            : null;
    if (rawLastDelivery != null && parsedLastDelivery == null) {
      throw const FormatException('invalid last_delivery_at');
    }
    final rawDeliveryAttempts = m['delivery_attempts'];
    if (rawDeliveryAttempts != null && rawDeliveryAttempts is! int) {
      throw const FormatException('invalid delivery_attempts');
    }
    final rawDeliveryText = m['delivery_text'];
    if (rawDeliveryText != null && rawDeliveryText is! String) {
      throw const FormatException('invalid delivery_text');
    }
    final rawDeliveryError = m['delivery_error'];
    if (rawDeliveryError != null && rawDeliveryError is! String) {
      throw const FormatException('invalid delivery_error');
    }
    final deliveryState = m['delivery_state'] as String? ?? 'none';
    if (!_deliveryStates.contains(deliveryState)) {
      throw FormatException('invalid delivery_state: $deliveryState');
    }
    final rawDeliveryRunId = m['delivery_run_id'] as String?;
    if (deliveryState == 'pending' &&
        (rawDeliveryRunId == null || rawDeliveryRunId.isEmpty)) {
      throw const FormatException('pending delivery requires delivery_run_id');
    }
    return Job(
      id: m['id'] as String,
      cron: m['cron'] as String,
      prompt: m['prompt'] as String,
      channel: m['channel'] as String? ?? 'cli',
      userKey: m['user_key'] as String? ?? 'local',
      nextRun: DateTime.parse(m['next_run'] as String).toUtc(),
      lastRun: m['last_run'] != null
          ? DateTime.parse(m['last_run'] as String).toUtc()
          : null,
      enabled: m['enabled'] as bool? ?? true,
      missedPolicy: policy,
      timezone: m['timezone'] as String? ?? 'UTC',
      pendingRunAt: parsedPending,
      deliveryRunId: rawDeliveryRunId,
      deliveryText: rawDeliveryText as String?,
      deliveryAttempts: rawDeliveryAttempts as int? ?? 0,
      deliveryNextAt: parsedDeliveryNext,
      lastDeliveryAt: parsedLastDelivery,
      deliveryError: rawDeliveryError as String?,
      deliveryState: deliveryState,
    );
  }
}

/// Job store with atomic JSON persistence and restart-safe execution claims.
class JobStore {
  JobStore({this.persistPath});

  /// Cap untuk teks delivery yang diantre agar satu output tidak
  /// mendominasi jobs.json.
  static const maxDeliveryTextLength = 20000;

  final String? persistPath;
  final Map<String, Job> _jobs = {};
  final _uuid = const Uuid();
  Future<void> _saveTail = Future<void>.value();
  String? loadError;

  List<Job> get all => _jobs.values.toList();
  Job? get(String id) => _jobs[id];

  Future<void> load() async {
    if (persistPath == null) return;
    final f = File(persistPath!);
    if (!await f.exists()) return;
    try {
      if (await f.length() > 4 * 1024 * 1024) {
        throw const FormatException('jobs file exceeds 4 MiB');
      }
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List || decoded.length > 1000) {
        throw const FormatException('jobs root must be a list of at most 1000 entries');
      }
      final loaded = <String, Job>{};
      final rejected = <String>[];
      for (var index = 0; index < decoded.length; index++) {
        final raw = decoded[index];
        try {
          if (raw is! Map) throw const FormatException('job entry must be an object');
          final job = Job.fromJson(Map<String, dynamic>.from(raw));
          final cron = CronExpression.parse(job.cron);
          // Validate timezone and next-run calculation before exposing the job.
          cron.nextAfter(DateTime.now().toUtc(), timezone: job.timezone);
          if (job.id.trim().isEmpty || job.prompt.trim().isEmpty) {
            throw const FormatException('job id/prompt cannot be empty');
          }
          if (loaded.containsKey(job.id)) {
            throw FormatException('duplicate job id: ${job.id}');
          }
          loaded[job.id] = job;
        } catch (error) {
          rejected.add('entry[$index]: $error');
        }
      }
      _jobs
        ..clear()
        ..addAll(loaded);
      loadError = rejected.isEmpty ? null : rejected.join(' | ');
    } catch (error) {
      loadError = '$error';
      // Keep the invalid file intact for diagnosis. Do not silently overwrite.
    }
  }

  Future<void> save() async {
    final previous = _saveTail;
    final gate = Completer<void>();
    _saveTail = gate.future;
    try {
      // A previous failed write must not permanently poison the save queue.
      try { await previous; } catch (_) {}
      if (persistPath != null) {
        final file = File(persistPath!);
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.${_uuid.v4()}.tmp');
        final body = const JsonEncoder.withIndent('  ').convert(
          _jobs.values.map((job) => job.toJson()).toList(),
        );
        await temp.writeAsString(body, flush: true);
        try {
          await temp.rename(file.path);
        } on FileSystemException {
          final backup = File('${file.path}.bak');
          var movedOld = false;
          try {
            if (await file.exists()) {
              if (await backup.exists()) await backup.delete();
              await file.rename(backup.path);
              movedOld = true;
            }
            await temp.rename(file.path);
            if (movedOld && await backup.exists()) await backup.delete();
          } catch (_) {
            if (movedOld && !await file.exists() && await backup.exists()) {
              await backup.rename(file.path);
            }
            rethrow;
          }
        }
      }
    } finally {
      // The queue gate never completes with an error; individual callers still
      // receive write errors through the Future returned by this method.
      gate.complete();
    }
  }

  Job add({
    required String cron,
    required String prompt,
    required String channel,
    required String userKey,
    MissedPolicy missedPolicy = MissedPolicy.runOnce,
    String timezone = 'UTC',
    String? id,
  }) {
    final expr = CronExpression.parse(cron);
    if (prompt.trim().isEmpty || prompt.length > 10000) {
      throw ArgumentError.value(prompt, 'prompt', 'must contain 1..10000 characters');
    }
    if (channel.trim().isEmpty || channel.length > 64 ||
        userKey.trim().isEmpty || userKey.length > 256) {
      throw ArgumentError('invalid channel or userKey');
    }
    final now = DateTime.now().toUtc();
    final jobId = id ?? _uuid.v4();
    if (_jobs.containsKey(jobId)) throw StateError('duplicate job id: $jobId');
    final job = Job(
      id: jobId,
      cron: cron,
      prompt: prompt.trim(),
      channel: channel,
      userKey: userKey,
      nextRun: expr.nextAfter(now, timezone: timezone),
      missedPolicy: missedPolicy,
      timezone: timezone,
    );
    _jobs[job.id] = job;
    unawaitedSave();
    return job;
  }

  Future<Job> addAndSave({
    required String cron,
    required String prompt,
    required String channel,
    required String userKey,
    MissedPolicy missedPolicy = MissedPolicy.runOnce,
    String timezone = 'UTC',
    String? id,
  }) async {
    final job = add(
      cron: cron,
      prompt: prompt,
      channel: channel,
      userKey: userKey,
      missedPolicy: missedPolicy,
      timezone: timezone,
      id: id,
    );
    try {
      await save();
      return job;
    } catch (_) {
      _jobs.remove(job.id);
      rethrow;
    }
  }

  void unawaitedSave() {
    // ignore: discarded_futures
    save().catchError((Object error) {
      loadError = 'save failed: $error';
    });
  }

  bool remove(String id) {
    final ok = _jobs.remove(id) != null;
    if (ok) unawaitedSave();
    return ok;
  }

  /// Synchronous compatibility API for unit tests and in-memory use.
  List<Job> claimDue(DateTime now) {
    final due = <Job>[];
    _claim(now.toUtc(), due);
    if (due.isNotEmpty) unawaitedSave();
    return due;
  }

  /// Persist the claim before returning jobs to the scheduler. A crash after
  /// claim but before successful completion leaves pending_run_at to replay.
  Future<List<Job>> claimDuePersisted(DateTime now) async {
    final due = <Job>[];
    final changed = _claim(now.toUtc(), due);
    if (changed) await save();
    return due;
  }

  bool _claim(DateTime now, List<Job> due) {
    var changed = false;
    for (final job in _jobs.values) {
      if (!job.enabled) continue;
      if (job.pendingRunAt != null) {
        job.scheduledAt = job.pendingRunAt;
        due.add(job);
        continue;
      }
      if (job.nextRun.isAfter(now)) continue;

      final expr = CronExpression.parse(job.cron);
      final scheduled = job.nextRun.toUtc();
      job.scheduledAt = scheduled;
      switch (job.missedPolicy) {
        case MissedPolicy.skip:
          job.nextRun = expr.nextAfter(now, timezone: job.timezone);
          job.lastRun = scheduled;
          changed = true;
          continue;
        case MissedPolicy.runOnce:
          job.nextRun = expr.nextAfter(now, timezone: job.timezone);
          break;
        case MissedPolicy.catchUp:
          job.nextRun = expr.nextAfter(scheduled, timezone: job.timezone);
          break;
      }
      job.pendingRunAt = scheduled;
      due.add(job);
      changed = true;
    }
    return changed;
  }

  Future<void> completeRun(String id, DateTime scheduledAt) async {
    final job = _jobs[id];
    if (job == null) return;
    if (job.pendingRunAt != null &&
        job.pendingRunAt!.toUtc() != scheduledAt.toUtc()) {
      throw StateError('scheduled run mismatch for job $id');
    }
    job.lastRun = scheduledAt.toUtc();
    job.pendingRunAt = null;
    job.scheduledAt = null;
    await save();
  }

  Future<void> releaseRun(String id) async {
    // Keep pendingRunAt so the same scheduled job is retried after a failure
    // or process restart. This is at-least-once; handlers should be idempotent.
    final job = _jobs[id];
    if (job == null) return;
    job.scheduledAt = job.pendingRunAt;
    await save();
  }

  /// Antre output agent untuk dikirim ke gateway. Run terjadwal tetap
  /// diklaim (pending_run_at) sampai delivery di-ack, sehingga crash antara
  /// generate dan kirim me-replay delivery, bukan kehilangan output.
  Future<void> awaitDelivery(String id, String runId, String text) async {
    final job = _jobs[id];
    if (job == null) throw StateError('unknown job $id');
    if (runId.isEmpty) {
      throw ArgumentError.value(runId, 'runId', 'must not be empty');
    }
    if (job.pendingRunAt == null) {
      throw StateError('job $id has no claimed run awaiting delivery');
    }
    if (job.deliveryRunId != null) {
      if (job.deliveryRunId == runId) return; // idempotent re-queue
      throw StateError(
        'job $id already has a pending delivery for ${job.deliveryRunId}',
      );
    }
    job
      ..deliveryRunId = runId
      ..deliveryText = text.length > maxDeliveryTextLength
          ? text.substring(0, maxDeliveryTextLength)
          : text
      ..deliveryAttempts = 0
      ..deliveryNextAt = DateTime.now().toUtc()
      ..deliveryState = 'pending'
      ..deliveryError = null;
    await save();
  }

  bool deliveryPending(String id) => _jobs[id]?.deliveryRunId != null;

  /// Klaim output yang retry-nya sudah jatuh tempo. Penghitung upaya
  /// dipersist SEBELUM pengiriman dilakukan, sehingga crash di tengah
  /// pengiriman tetap dihitung sebagai satu upaya (at-least-once).
  Future<List<Job>> claimDueDeliveries(DateTime now) async {
    final n = now.toUtc();
    final due = <Job>[];
    var changed = false;
    for (final job in _jobs.values) {
      if (job.deliveryRunId == null) continue;
      final next = job.deliveryNextAt;
      if (next != null && next.isAfter(n)) continue;
      job.deliveryAttempts += 1;
      job.deliveryNextAt = null;
      due.add(job);
      changed = true;
    }
    if (changed) await save();
    return due;
  }

  /// Ack delivery sukses sekaligus menuntaskan run terjadwal.
  Future<void> completeDelivery(String id, String runId) async {
    final job = _jobs[id];
    if (job == null) return;
    if (job.deliveryRunId != runId) {
      throw StateError('delivery mismatch for job $id: $runId');
    }
    job.lastRun = job.pendingRunAt?.toUtc() ?? job.lastRun;
    job
      ..pendingRunAt = null
      ..scheduledAt = null
      ..deliveryRunId = null
      ..deliveryText = null
      ..deliveryNextAt = null
      ..deliveryError = null
      ..deliveryState = 'delivered'
      ..lastDeliveryAt = DateTime.now().toUtc();
    await save();
  }

  /// Catat upaya delivery gagal dan jadwalkan retry berikutnya.
  Future<void> scheduleDeliveryRetry(
    String id,
    String runId,
    Duration delay, {
    required String error,
  }) async {
    final job = _jobs[id];
    if (job == null) return;
    if (job.deliveryRunId != runId) {
      throw StateError('delivery mismatch for job $id: $runId');
    }
    if (delay < Duration.zero) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    job
      ..deliveryNextAt = DateTime.now().toUtc().add(delay)
      ..deliveryState = 'pending'
      ..deliveryError = _capDeliveryError(error);
    await save();
  }

  /// Menyerah setelah retry habis. Giliran agent sendiri sudah sukses, jadi
  /// run dituntaskan dengan catatan delivery gagal yang durabel, bukan
  /// di-replay (yang akan menduplikasi giliran agent).
  Future<void> failDeliveryPermanently(
    String id,
    String runId,
    String error,
  ) async {
    final job = _jobs[id];
    if (job == null) return;
    if (job.deliveryRunId != runId) {
      throw StateError('delivery mismatch for job $id: $runId');
    }
    job.lastRun = job.pendingRunAt?.toUtc() ?? job.lastRun;
    job
      ..pendingRunAt = null
      ..scheduledAt = null
      ..deliveryRunId = null
      ..deliveryText = null
      ..deliveryNextAt = null
      ..deliveryState = 'failed'
      ..deliveryError = _capDeliveryError(error);
    await save();
  }

  String _capDeliveryError(String error) {
    final clean = error.replaceAll('\n', ' ').trim();
    return clean.length > 500 ? clean.substring(0, 500) : clean;
  }
}
