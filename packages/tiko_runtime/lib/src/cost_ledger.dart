// Fase F7 (docs/15 §8) — cost/token observability per user/channel/day:
// ledger JSONL append-only durabel di dataDir; ringkasan agregat untuk
// endpoint `/v1/runs` (field `cost`) dan halaman Runs web client.

part of 'tiko_runtime.dart';

/// Satu catatan turn selesai (disanitasi: tanpa isi prompt/answer).
class CostEntry {
  CostEntry({
    required this.ts,
    required this.session,
    required this.channel,
    required this.userKey,
    required this.tokensUsed,
    required this.toolCalls,
    required this.success,
    required this.durationMs,
    this.model = '',
    this.costUsd = 0,
  });

  factory CostEntry.fromJson(Map<String, dynamic> m) {
    final ts = DateTime.tryParse(m['ts']?.toString() ?? '')?.toUtc();
    final tokens = m['tokens_used'];
    final calls = m['tool_calls'];
    final duration = m['duration_ms'];
    if (ts == null || tokens is! int || tokens < 0 || calls is! int) {
      throw const FormatException('invalid cost entry');
    }
    return CostEntry(
      ts: ts,
      session: m['session']?.toString() ?? '',
      channel: m['channel']?.toString() ?? '',
      userKey: m['user_key']?.toString() ?? '',
      tokensUsed: tokens,
      toolCalls: calls,
      success: m['success'] == true,
      durationMs: duration is int && duration >= 0 ? duration : 0,
      model: m['model']?.toString() ?? '',
      costUsd: m['cost_usd'] is num ? (m['cost_usd'] as num).toDouble() : 0,
    );
  }

  final DateTime ts;
  final String session;
  final String channel;
  final String userKey;
  final int tokensUsed;
  final int toolCalls;
  final bool success;
  final int durationMs;

  /// Hermes fase-7: model terpakai turn ini (kosong bila tak diketahui) dan
  /// estimasi biaya USD dari usage token (0 bila tak dapat diestimasi).
  final String model;
  final double costUsd;

  Map<String, dynamic> toJson() => {
        'ts': ts.toIso8601String(),
        'session': session,
        'channel': channel,
        'user_key': userKey,
        'tokens_used': tokensUsed,
        'tool_calls': toolCalls,
        'success': success,
        'duration_ms': durationMs,
        'model': model,
        'cost_usd': costUsd,
      };
}

/// Ledger biaya/token per turn — append-only JSONL dengan cap; kelas
/// ringkasan dibaca sinkron dari memori (fail-soft bila berkord korup).
class CostLedger {
  CostLedger({required this.persistPath, this.maxEntries = 5000});

  final String persistPath;
  final int maxEntries;
  final List<CostEntry> _entries = [];
  bool _loaded = false;

  int get length => _entries.length;

  /// Salinan entri (terlama → terbaru) untuk agregator laporan seperti
  /// insights; tanpa salinan dalam agar murah dan konsisten dengan JSONL.
  List<CostEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(persistPath);
    if (!await f.exists()) return;
    try {
      List<String> lines = await f.readAsLines();
      if (lines.length > maxEntries) {
        lines = lines.sublist(lines.length - maxEntries);
      }
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            _entries.add(
              CostEntry.fromJson(Map<String, dynamic>.from(decoded)),
            );
          }
        } catch (_) {
          // Baris korup dilompati — ledger bersifat observabilitas.
        }
      }
    } on Exception {
      // File tak terbaca: mulai kosong, record berikutnya menimpa.
    }
  }

  Future<void> record(CostEntry entry) async {
    await load();
    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    await save();
  }

  Future<void> save() async {
    final file = File(persistPath);
    await file.parent.create(recursive: true);
    final buffer = StringBuffer(
      _entries.map((e) => jsonEncode(e.toJson())).join('\n'),
    );
    if (buffer.isNotEmpty) buffer.write('\n');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(buffer.toString(), flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(buffer.toString(), flush: true);
      try {
        await tmp.delete();
      } on FileSystemException {
        // best-effort
      }
    }
  }

  /// Agregasi observabilitas: total + bucket per [groupBy]
  /// (`user` | `channel` | `day`) dalam jendela [days] hari UTC.
  Map<String, dynamic> summary({
    String groupBy = 'user',
    int days = 7,
  }) {
    final now = DateTime.now().toUtc();
    final windowStart = now.subtract(Duration(days: days));
    final scoped = [
      for (final e in _entries)
        if (!e.ts.isBefore(windowStart)) e,
    ];

    final buckets = <String, List<CostEntry>>{};
    for (final e in scoped) {
      final key = switch (groupBy) {
        'channel' => e.channel.isEmpty ? '(tanpa channel)' : e.channel,
        'day' => e.ts.toIso8601String().substring(0, 10),
        _ => e.userKey.isEmpty ? '(tanpa user)' : e.userKey,
      };
      (buckets[key] ??= []).add(e);
    }

    int tokensOf(List<CostEntry> list) =>
        list.fold(0, (sum, e) => sum + e.tokensUsed);
    double costOf(List<CostEntry> list) =>
        list.fold(0.0, (sum, e) => sum + e.costUsd);

    final bucketList = [
      for (final b in buckets.entries)
        {
          'key': b.key,
          'turns': b.value.length,
          'tokens_used': tokensOf(b.value),
          'tool_calls': b.value.fold(0, (s, e) => s + e.toolCalls),
          'success': [
            for (final e in b.value)
              if (e.success) 1,
          ].length,
          'cost_usd': costOf(b.value),
        }
    ]..sort((a, b) =>
        (b['tokens_used'] as int).compareTo(a['tokens_used'] as int));

    return {
      'group_by': groupBy,
      'days': days,
      'window_start': windowStart.toIso8601String(),
      'total': {
        'turns': scoped.length,
        'tokens_used': tokensOf(scoped),
        'tool_calls': scoped.fold(0, (s, e) => s + e.toolCalls),
        'success': [
          for (final e in scoped)
            if (e.success) 1,
        ].length,
        'cost_usd': costOf(scoped),
      },
      'buckets': bucketList,
    };
  }
}
