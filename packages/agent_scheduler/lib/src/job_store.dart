import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'cron.dart';

enum MissedPolicy { skip, runOnce, catchUp }

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
    );
  }
}

/// Job store with atomic JSON persistence and restart-safe execution claims.
class JobStore {
  JobStore({this.persistPath});

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
}
