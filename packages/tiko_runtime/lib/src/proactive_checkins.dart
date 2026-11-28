import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Fase 44 — Proactive check-ins (paritas Grok Bot): bot proaktif menawarkan
/// bantuan pada sesi yang idle melewati ambang, dipicu scheduler/tick
/// deterministik (tanpa LLM), default off via config.
///
/// Konvensi repo:
/// - Pesan check-in content-free (template tetap, tanpa isi percakapan).
/// - Budget keras: maks N check-in per sesi per hari dan M sesi per tick.
/// - Never-raises: kegagalan disk/list/sender tidak pernah throw.
class ProactiveCheckinTarget {
  const ProactiveCheckinTarget({
    required this.sessionId,
    required this.channel,
    required this.userKey,
    required this.lastActivity,
    this.title,
  });

  final String sessionId;
  final String channel;
  final String userKey;
  final DateTime lastActivity;
  final String? title;
}

/// Host menyediakan daftar sesi idle (updatedAt terakhir) — sinkron dengan
/// SessionStore.list() di wiring runtime.
typedef CheckinIdleLister = Future<List<ProactiveCheckinTarget>> Function();

/// Pengirim pesan check-in (gateway/kirim langsung). False = gagal kirim.
/// Boleh null: bila host tidak menyediakan jalur kirim, check-in tetap
/// dihitung + event `checkin.proposed` diterbitkan (delivery jadi tugas host
/// yang mendengarkan event).
typedef CheckinSender = Future<bool> Function(
  ProactiveCheckinTarget target,
  String message,
)?;

class ProactiveCheckinEntry {
  ProactiveCheckinEntry({
    required this.sessionId,
    required this.lastCheckinAt,
    required this.dayKey,
    this.countToday = 0,
    this.totalCount = 0,
  });

  final String sessionId;
  DateTime lastCheckinAt;
  String dayKey;
  int countToday;
  int totalCount;

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'last_checkin_at': lastCheckinAt.toUtc().toIso8601String(),
        'day_key': dayKey,
        'count_today': countToday,
        'total_count': totalCount,
      };

  static ProactiveCheckinEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['session_id'];
    if (id is! String || id.trim().isEmpty) return null;
    final last = DateTime.tryParse('${raw['last_checkin_at'] ?? ''}');
    return ProactiveCheckinEntry(
      sessionId: id.trim(),
      lastCheckinAt: last ?? DateTime.now().toUtc(),
      dayKey: raw['day_key'] is String ? raw['day_key'] as String : '',
      countToday: raw['count_today'] is int ? raw['count_today'] as int : 0,
      totalCount: raw['total_count'] is int ? raw['total_count'] as int : 0,
    );
  }
}

class ProactiveCheckinTickReport {
  const ProactiveCheckinTickReport({
    required this.idleSessions,
    required this.proposed,
    required this.skipped,
    required this.errors,
  });

  final int idleSessions;
  final List<String> proposed;
  final int skipped;
  final int errors;

  Map<String, dynamic> toJson() => {
        'idle_sessions': idleSessions,
        'proposed': proposed,
        'skipped': skipped,
        'errors': errors,
      };
}

/// Engine check-in proaktif. Murni (callback injected) — deterministik untuk
/// test: `now` injectable, state persist `<dataDir>/proactive_checkins.json`.
class ProactiveCheckinEngine {
  ProactiveCheckinEngine({
    required this.dataDir,
    required this.listIdleSessions,
    required this.send,
    this.idleMinutes = 30,
    this.maxPerSessionPerDay = 2,
    this.maxSessionsPerTick = 10,
    this.maxStateEntries = 1000,
    this.emitEvent,
    DateTime Function()? now,
  })  : assert(idleMinutes >= 1 && idleMinutes <= 10080),
        assert(maxPerSessionPerDay >= 1 && maxPerSessionPerDay <= 20),
        assert(maxSessionsPerTick >= 1 && maxSessionsPerTick <= 100),
        assert(maxStateEntries >= 10),
        _now = now ?? (() => DateTime.now().toUtc());

  final String dataDir;
  final CheckinIdleLister listIdleSessions;
  final CheckinSender send;
  final int idleMinutes;
  final int maxPerSessionPerDay;
  final int maxSessionsPerTick;
  final int maxStateEntries;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;
  final DateTime Function() _now;

  final Map<String, ProactiveCheckinEntry> _state = {};
  bool _loaded = false;

  String get _statePath {
    final sep = dataDir.contains('\\') ? '\\' : '/';
    return '${dataDir.endsWith(sep) ? dataDir.substring(0, dataDir.length - 1) : dataDir}$sep'
        'proactive_checkins.json';
  }

  static String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = File(_statePath).readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final entries = decoded['entries'];
      if (entries is! List) return;
      for (final e in entries) {
        final entry = ProactiveCheckinEntry.fromJson(e);
        if (entry != null) _state[entry.sessionId] = entry;
      }
    } catch (_) {
      _state.clear();
    }
  }

  Future<void> save() async {
    try {
      final entries = _state.values.toList()
        ..sort((a, b) => a.lastCheckinAt.compareTo(b.lastCheckinAt));
      while (entries.length > maxStateEntries) {
        final evict = entries.removeAt(0);
        _state.remove(evict.sessionId);
      }
      final f = File(_statePath);
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'saved_at': _now().toIso8601String(),
        'entries': [for (final e in entries) e.toJson()],
      }));
      await tmp.rename(f.path);
    } catch (_) {
      // fail-open: kegagalan persist tidak menggagalkan check-in.
    }
  }

  /// Satu tick scheduler: cari sesi idle, kirim check-in sesuai budget,
  /// catat state. Tidak pernah throw.
  Future<ProactiveCheckinTickReport> tick() async {
    await load();
    var idle = 0;
    var skipped = 0;
    var errors = 0;
    final proposed = <String>[];
    List<ProactiveCheckinTarget> targets;
    try {
      targets = await listIdleSessions();
    } catch (_) {
      return ProactiveCheckinTickReport(
        idleSessions: 0,
        proposed: const [],
        skipped: 0,
        errors: 1,
      );
    }
    final now = _now();
    final today = _dayKey(now);
    for (final t in targets) {
      final idleFor = now.difference(t.lastActivity.toUtc()).inMinutes;
      if (idleFor < idleMinutes) continue;
      idle++;
      if (proposed.length >= maxSessionsPerTick) {
        skipped++;
        continue;
      }
      final entry = _state[t.sessionId] ??
          (ProactiveCheckinEntry(
            sessionId: t.sessionId,
            lastCheckinAt: DateTime.fromMillisecondsSinceEpoch(0),
            dayKey: '',
          ));
      if (entry.dayKey == today && entry.countToday >= maxPerSessionPerDay) {
        skipped++;
        continue;
      }
      if (entry.lastCheckinAt.isAfter(now)) {
        entry.lastCheckinAt = now;
      }
      final minutesSinceCheckin =
          now.difference(entry.lastCheckinAt).inMinutes;
      if (entry.totalCount > 0 && minutesSinceCheckin < idleMinutes) {
        skipped++;
        continue;
      }
      final message =
          'Check-in otomatis: ada yang bisa saya bantu lanjutkan? '
          '(check-in proaktif; terakhir aktif $idleFor menit lalu)';
      var sent = true;
      final sendFn = send;
      if (sendFn != null) {
        try {
          sent = await sendFn(t, message);
        } catch (_) {
          sent = false;
        }
        if (!sent) {
          errors++;
          continue;
        }
      }
      entry.lastCheckinAt = now;
      entry.countToday = entry.dayKey == today ? entry.countToday + 1 : 1;
      entry.dayKey = today;
      entry.totalCount += 1;
      _state[t.sessionId] = entry;
      proposed.add(t.sessionId);
      emitEvent?.call('checkin.proposed', {
        'session_id': t.sessionId,
        'channel': t.channel,
        'user_key': t.userKey,
        'idle_minutes': idleFor,
        'message': message,
        'delivered': sendFn != null,
      });
    }
    await save();
    return ProactiveCheckinTickReport(
      idleSessions: idle,
      proposed: proposed,
      skipped: skipped,
      errors: errors,
    );
  }

  /// Snapshot state bebas-konten (id + counter saja).
  Map<String, dynamic> statusSnapshot() {
    final sessions = _state.keys.toList()..sort();
    return {
      'enabled_sessions': sessions.length,
      'entries': [
        for (final id in sessions)
          {
            'session_id': id,
            'count_today': _state[id]!.countToday,
            'total_count': _state[id]!.totalCount,
            'last_checkin_at': _state[id]!.lastCheckinAt.toIso8601String(),
          },
      ],
    };
  }
}

/// Tool `checkins` — status engine dan trigger tick manual (scheduler
/// eksternal bisa memanggil tick secara berkala; tool untuk operator).
class ProactiveCheckinTool implements Tool {
  ProactiveCheckinTool({required this.engine});

  final ProactiveCheckinEngine engine;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'checkins',
        description:
            'Check-in proaktif: lihat status check-in sesi idle atau picu '
            'tick check-in sekarang (deterministik, tanpa LLM).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['status', 'tick'],
              'description': 'Aksi: status (default) atau tick.',
            },
          },
        },
        risk: 'medium',
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = '${args['action'] ?? 'status'}'.trim();
    if (action == 'tick') {
      final report = await engine.tick();
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
    }
    return ToolResult(
      callId: '',
      content:
          const JsonEncoder.withIndent('  ').convert(engine.statusSnapshot()),
    );
  }
}
