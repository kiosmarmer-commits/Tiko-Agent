// Hermes parity: `agent/activity_tracker.py` — pelacak aktivitas sesi
// (first/last turn, hitungan turn) yang durabel antar restart, memuat
// riwayat lebih panjang dari insights (yang membaca cost ledger terbatas).

part of 'tiko_runtime.dart';

/// Satu catatan aktivitas sesi (disanitasi: tanpa isi prompt/answer).
class ActivityRecord {
  ActivityRecord({
    required this.session,
    required this.channel,
    required this.firstTurnAt,
    required this.lastTurnAt,
    this.turnCount = 0,
    this.failedTurns = 0,
  });

  factory ActivityRecord.fromJson(Map<String, dynamic> m) {
    final first = DateTime.tryParse(m['first_turn_at']?.toString() ?? '');
    final last = DateTime.tryParse(m['last_turn_at']?.toString() ?? '');
    if (first == null || last == null) {
      throw const FormatException('invalid activity record');
    }
    return ActivityRecord(
      session: m['session']?.toString() ?? '',
      channel: m['channel']?.toString() ?? '',
      firstTurnAt: first.toUtc(),
      lastTurnAt: last.toUtc(),
      turnCount: m['turn_count'] is int ? m['turn_count'] as int : 0,
      failedTurns: m['failed_turns'] is int ? m['failed_turns'] as int : 0,
    );
  }

  final String session;
  final String channel;
  final DateTime firstTurnAt;
  DateTime lastTurnAt;
  int turnCount;
  int failedTurns;

  Map<String, dynamic> toJson() => {
        'session': session,
        'channel': channel,
        'first_turn_at': firstTurnAt.toIso8601String(),
        'last_turn_at': lastTurnAt.toIso8601String(),
        'turn_count': turnCount,
        'failed_turns': failedTurns,
      };
}

/// Hermes `activity_tracker`: JSONL append-merge per sesi (satu baris per
/// sesi, atomic tmp-then-rename seperti [CostLedger]). Never-raises: gagal
/// IO dibiarkan senyap — tracker murni observabilitas.
class ActivityTracker {
  ActivityTracker({required this.persistPath, this.maxSessions = 500});

  final String persistPath;
  final int maxSessions;
  final Map<String, ActivityRecord> _records = {};
  bool _loaded = false;

  /// Salinan record (urutan sesi tak dijamin) untuk command/endpoint.
  List<ActivityRecord> get records => List.unmodifiable(_records.values);

  ActivityRecord? operator [](String sessionId) => _records[sessionId];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(persistPath);
    if (!await f.exists()) return;
    try {
      final lines = await f.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            final rec = ActivityRecord.fromJson(
              Map<String, dynamic>.from(decoded),
            );
            _records[rec.session] = rec;
          }
        } catch (_) {
          // Baris korup dilompati — tracker bersifat observabilitas.
        }
      }
    } on Exception {
      // File tak terbaca: mulai kosong, record berikutnya menimpa.
    }
  }

  Future<void> recordTurn(
    String sessionId,
    String channel, {
    required bool success,
    DateTime? at,
  }) async {
    try {
      await load();
      final ts = (at ?? DateTime.now()).toUtc();
      final existing = _records[sessionId];
      if (existing != null) {
        existing.lastTurnAt = ts;
        existing.turnCount++;
        if (!success) existing.failedTurns++;
      } else {
        _evict();
        _records[sessionId] = ActivityRecord(
          session: sessionId.length > 128 ? sessionId.substring(0, 128) : sessionId,
          channel: channel,
          firstTurnAt: ts,
          lastTurnAt: ts,
          turnCount: 1,
          failedTurns: success ? 0 : 1,
        );
      }
      await save();
    } catch (_) {
      // Observabilitas murni: kegagalan tulis tidak menggagalkan turn.
    }
  }

  void _evict() {
    while (_records.length >= maxSessions) {
      _records.remove(_records.keys.first);
    }
  }

  Future<void> save() async {
    final file = File(persistPath);
    await file.parent.create(recursive: true);
    final buffer = StringBuffer(
      _records.values.map((e) => jsonEncode(e.toJson())).join('\n'),
    );
    if (buffer.isNotEmpty) buffer.write('\n');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(buffer.toString(), flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows: rename gagal bila target dibuka proses lain.
      await tmp.copy(file.path);
      try {
        await tmp.delete();
      } catch (_) {} // best-effort
    }
  }
}

/// Ringkasan `/activity`: sesi teratas + grafik harian 14 hari. Sengaja
/// dipisah dari `/insights` (agregat cost/token dari ledger 5000 entri);
/// `/activity` menjawab "kapan sesi ini aktif dan seberapa rajin".
String activityFormatTerminal(List<ActivityRecord> records, {DateTime? now}) {
  if (records.isEmpty) {
    return 'Belum ada aktivitas sesi tercatat.';
  }
  final nowUtc = (now ?? DateTime.now()).toUtc();
  final sorted = [...records]..sort((a, b) => b.turnCount.compareTo(a.turnCount));
  final totalTurns = records.fold<int>(0, (a, r) => a + r.turnCount);
  final buf = StringBuffer('Aktivitas Sesi\n');
  buf.writeln(
    '- sesi tercatat: ${records.length}, total turn: $totalTurns',
  );
  buf.writeln();
  buf.writeln('Sesi Teratas (per turn):');
  for (final r in sorted.take(5)) {
    buf.writeln(
      '- ${r.session} (${r.channel}): ${r.turnCount} turn'
      '${r.failedTurns > 0 ? ', ${r.failedTurns} gagal' : ''} — '
      'terakhir ${insightsDayLabel(r.lastTurnAt)}',
    );
  }
  buf.writeln();
  buf.writeln('Sesi Aktif per Hari (14 hari terakhir):');
  final days = List.generate(14, (i) {
    final d = nowUtc.subtract(Duration(days: 13 - i));
    return DateTime.utc(d.year, d.month, d.day);
  });
  final values = [
    for (final d in days)
      records.fold<int>(
        0,
        (a, r) =>
            a +
            (r.lastTurnAt.year == d.year &&
                    r.lastTurnAt.month == d.month &&
                    r.lastTurnAt.day == d.day
                ? 1
                : 0),
      ),
  ];
  final bars = insightsBarChart(values);
  for (var i = 0; i < days.length; i++) {
    final label = '${insightsDayLabel(days[i])} '
        '${bars[i].padRight(14)} ${values[i]}';
    buf.writeln(label);
  }
  return buf.toString().trimRight();
}
