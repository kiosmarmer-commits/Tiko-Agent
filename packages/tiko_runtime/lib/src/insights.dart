// Hermes parity: `agent/insights.py` — Session Insights Engine.
//
// Agregasi ledger biaya/turn menjadi laporan insight pemakaian: overview
// (turn, token, tool calls, biaya), breakdown per model, per channel,
// sesi teratas, dan pola aktivitas (bar chart per hari/jam, streak).
//
// Deviasi sadar dari Hermes:
// - Hermes membaca state DB dengan sesi + per-model + tool/skill usage;
//   Tiko membaca [CostLedger] (per-turn, tanpa nama tool per call dan tanpa
//   skill). Bagian `tools`/`skills` dilewati secara jujur — hanya total
//   `tool_calls` yang dilaporkan di overview.
// - Hermes memakai waktu lokal; Tiko memakai UTC karena entri ledger UTC.
// - Biaya memakai `cost_usd` tersimpan per turn (estimasi rate card fase-7),
//   bukan estimasi ulang CanonicalUsage.
part of 'tiko_runtime.dart';

/// Nama hari untuk bar chart aktivitas (Senin = indeks 0), UTC.
const List<String> _insightDayNames = [
  'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min',
];

const List<String> _insightMonthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
  'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
];

/// Nama tampilan model: buang prefiks provider; kosong → "unknown"
/// (Hermes `_short_model`).
String insightsShortModel(String model) {
  final m = model.trim();
  if (m.isEmpty) return 'unknown';
  return m.split('/').last;
}

/// Bar chart teks: lebar proporsional terhadap puncak; nilai 0 → string
/// kosong (Hermes `_bar_chart`).
List<String> insightsBarChart(List<int> values, {int maxWidth = 20}) {
  if (values.isEmpty) return const [];
  final peak = values.fold<int>(values.first, (a, b) => b > a ? b : a);
  if (peak <= 0) return [for (final _ in values) ''];
  return [
    for (final v in values)
      v > 0 ? '█' * (v * maxWidth ~/ peak).clamp(1, maxWidth) : '',
  ];
}

/// Format jam 12 ("12am", "1pm") untuk peak hours (Hermes `_hour12`).
String insightsHour12(int hour) {
  final h = ((hour % 24) + 24) % 24;
  final suffix = h < 12 ? 'am' : 'pm';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12$suffix';
}

/// Format tanggal "Jan 05" (Hermes `_day`).
String insightsDayLabel(DateTime utc) {
  final m = _insightMonthNames[utc.month - 1];
  return '$m ${utc.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _insightsGenerate(
  CostLedger ledger,
  int days,
  DateTime nowUtc,
) {
  final windowStart = nowUtc.subtract(Duration(days: days));
  final scoped = [
    for (final e in ledger.entries)
      if (!e.ts.isBefore(windowStart) && !e.ts.isAfter(nowUtc)) e,
  ];

  final empty = scoped.isEmpty;

  // Overview.
  final tokens = scoped.fold<int>(0, (s, e) => s + e.tokensUsed);
  final toolCalls = scoped.fold<int>(0, (s, e) => s + e.toolCalls);
  final cost = scoped.fold<double>(0.0, (s, e) => s + e.costUsd);
  final successTurns = [for (final e in scoped) if (e.success) e].length;
  final durationMs = scoped.fold<int>(0, (s, e) => s + e.durationMs);
  final n = scoped.length;
  DateTime? rangeStart;
  DateTime? rangeEnd;
  for (final e in scoped) {
    if (rangeStart == null || e.ts.isBefore(rangeStart)) rangeStart = e.ts;
    if (rangeEnd == null || e.ts.isAfter(rangeEnd)) rangeEnd = e.ts;
  }

  // Breakdown per model (Hermes `_compute_model_breakdown`, versi per-turn).
  final models = <String, Map<String, dynamic>>{};
  // Breakdown per channel (analog `_compute_platform_breakdown`).
  final channels = <String, Map<String, dynamic>>{};
  // Sesi teratas (analog `_compute_top_sessions`).
  final sessions = <String, Map<String, dynamic>>{};

  void bump(
    Map<String, Map<String, dynamic>> target,
    String key,
    CostEntry e,
  ) {
    final d = target.putIfAbsent(key, () => {
          'turns': 0,
          'tokens': 0,
          'tool_calls': 0,
          'cost_usd': 0.0,
        });
    d['turns'] = (d['turns'] as int) + 1;
    d['tokens'] = (d['tokens'] as int) + e.tokensUsed;
    d['tool_calls'] = (d['tool_calls'] as int) + e.toolCalls;
    d['cost_usd'] = (d['cost_usd'] as double) + e.costUsd;
  }

  final activityDay = List<int>.filled(7, 0);
  final activityHour = List<int>.filled(24, 0);
  final activeDates = <String>{};

  for (final e in scoped) {
    bump(models, insightsShortModel(e.model), e);
    bump(channels, e.channel.isEmpty ? '(tanpa channel)' : e.channel, e);
    bump(sessions, e.session.isEmpty ? '(tanpa sesi)' : e.session, e);
    activityDay[e.ts.weekday - 1] += 1;
    activityHour[e.ts.hour] += 1;
    activeDates.add(e.ts.toIso8601String().substring(0, 10));
  }

  final modelList = [
    for (final me in models.entries)
      {
        'model': me.key,
        ...me.value,
      }
  ]..sort((a, b) => (b['tokens'] as int).compareTo(a['tokens'] as int));

  final channelList = [
    for (final ce in channels.entries)
      {
        'channel': ce.key,
        ...ce.value,
      }
  ]..sort((a, b) => (b['turns'] as int).compareTo(a['turns'] as int));

  final sessionList = [
    for (final se in sessions.entries)
      {
        'session': se.key,
        ...se.value,
      }
  ]..sort((a, b) => (b['tokens'] as int).compareTo(a['tokens'] as int));

  // Aktivitas: hari tersibuk, jam tersibuk, hari aktif, streak terpanjang.
  var busiestDayIdx = 0;
  for (var i = 1; i < 7; i++) {
    if (activityDay[i] > activityDay[busiestDayIdx]) busiestDayIdx = i;
  }
  var busiestHour = 0;
  for (var i = 1; i < 24; i++) {
    if (activityHour[i] > activityHour[busiestHour]) busiestHour = i;
  }
  var maxStreak = 0;
  if (activeDates.isNotEmpty) {
    final dates = [
      for (final d in activeDates)
        DateTime.parse('${d}T00:00:00Z'),
    ]..sort();
    var streak = 1;
    maxStreak = 1;
    for (var i = 1; i < dates.length; i++) {
      final diff = dates[i].difference(dates[i - 1]).inDays;
      streak = diff == 1 ? streak + 1 : 1;
      if (streak > maxStreak) maxStreak = streak;
    }
  }

  return {
    'days': days,
    'empty': empty,
    'generated_at': nowUtc.toIso8601String(),
    'overview': {
      'turns': n,
      'success_turns': successTurns,
      'success_rate': n > 0 ? successTurns / n : 0.0,
      'tokens': tokens,
      'tool_calls': toolCalls,
      'cost_usd': cost,
      'avg_tokens_per_turn': n > 0 ? tokens / n : 0.0,
      'avg_duration_ms': n > 0 ? durationMs / n : 0.0,
      'date_range_start': rangeStart?.toIso8601String(),
      'date_range_end': rangeEnd?.toIso8601String(),
    },
    'models': modelList,
    'channels': channelList,
    'sessions': sessionList.take(10).toList(),
    'activity': {
      'by_day': [
        for (var i = 0; i < 7; i++) {'day': _insightDayNames[i], 'count': activityDay[i]},
      ],
      'by_hour': [
        for (var i = 0; i < 24; i++) {'hour': i, 'count': activityHour[i]},
      ],
      'busiest_day': {'day': _insightDayNames[busiestDayIdx], 'count': activityDay[busiestDayIdx]},
      'busiest_hour': {'hour': busiestHour, 'count': activityHour[busiestHour]},
      'active_days': activeDates.length,
      'max_streak': maxStreak,
    },
  };
}

/// Laporan insight dari [ledger] dalam jendela [days] hari UTC.
/// [now] dapat diinjeksi untuk pengujian deterministik.
Map<String, dynamic> insightsGenerate(
  CostLedger ledger, {
  int days = 30,
  DateTime Function()? now,
}) {
  final nowUtc = (now ?? DateTime.now).call().toUtc();
  final safeDays = days < 1 ? 1 : (days > 365 ? 365 : days);
  return _insightsGenerate(ledger, safeDays, nowUtc);
}

List<String> _insightSection(String title) => [
      '  $title',
      '  ${'─' * 56}',
    ];

/// Format laporan untuk terminal CLI (Hermes `format_terminal`).
String insightsFormatTerminal(Map<String, dynamic> report) {
  final days = report['days'] is int ? report['days'] as int : 30;
  if (report['empty'] == true) {
    return 'Tidak ada data sesi dalam $days hari terakhir.';
  }
  final o = report['overview'] as Map<String, dynamic>? ?? const {};
  final lines = <String>[
    '',
    '  ╔${'═' * 55}╗',
    '  ║${'📊 Tiko Insights'.padLeft(38)}${''.padRight(17)}║',
    '  ║${'$days hari terakhir'.padLeft(36)}${''.padRight(19)}║',
    '  ╚${'═' * 55}╝',
    '',
  ];
  final start = report['overview'] != null
      ? DateTime.tryParse('${o['date_range_start'] ?? ''}')
      : null;
  final end = report['overview'] != null
      ? DateTime.tryParse('${o['date_range_end'] ?? ''}')
      : null;
  if (start != null && end != null) {
    lines
      ..add('  Periode: ${insightsDayLabel(start.toUtc())} — '
          '${insightsDayLabel(end.toUtc())}')
      ..add('');
  }
  final turns = o['turns'] is int ? o['turns'] as int : 0;
  final tokens = o['tokens'] is int ? o['tokens'] as int : 0;
  final toolCalls = o['tool_calls'] is int ? o['tool_calls'] as int : 0;
  final successRate = o['success_rate'] is num ? (o['success_rate'] as num).toDouble() : 0.0;
  final cost = o['cost_usd'] is num ? (o['cost_usd'] as num).toDouble() : 0.0;
  final avgTokens = o['avg_tokens_per_turn'] is num
      ? (o['avg_tokens_per_turn'] as num).toDouble()
      : 0.0;
  lines.addAll([
    ..._insightSection('📋 Overview'),
    '  Turn:              $turns',
    '  Sukses:            $successRate' '%',
    '  Token:             $tokens',
    '  Tool calls:        $toolCalls',
    if (cost > 0)
      '  Biaya (estimasi):  ${formatCostLabel(cost)}'
          ' (rata-rata/turn: ${formatCostLabel(turns > 0 ? cost / turns : 0)})',
    if (tokens > 0) '  Rata-rata token/turn: ${avgTokens.toStringAsFixed(1)}',
    '',
  ]);

  final models = [
    for (final m in report['models'] as List? ?? [])
      if (m is Map<String, dynamic>) m,
  ];
  if (models.isNotEmpty) {
    lines.addAll([
      ..._insightSection('🤖 Model Terpakai'),
      '  ${'Model'.padRight(30)}${'Turn'.padLeft(6)}${'Token'.padLeft(12)}',
      for (final m in models)
        '  ${(m['model'] ?? '').toString().padRight(30)}'
            '${(m['turns'] ?? 0).toString().padLeft(6)}'
            '${(m['tokens'] ?? 0).toString().padLeft(12)}',
      '',
    ]);
  }

  final channels = [
    for (final c in report['channels'] as List? ?? [])
      if (c is Map<String, dynamic>) c,
  ];
  if (channels.length > 1) {
    lines.addAll([
      ..._insightSection('📱 Channel'),
      '  ${'Channel'.padRight(16)}${'Turn'.padLeft(6)}${'Token'.padLeft(12)}',
      for (final c in channels)
        '  ${(c['channel'] ?? '').toString().padRight(16)}'
            '${(c['turns'] ?? 0).toString().padLeft(6)}'
            '${(c['tokens'] ?? 0).toString().padLeft(12)}',
      '',
    ]);
  }

  final act = report['activity'] as Map<String, dynamic>? ?? const {};
  final byDay = [
    for (final d in act['by_day'] as List? ?? [])
      if (d is Map<String, dynamic>) d,
  ];
  if (byDay.isNotEmpty && byDay.any((d) => (d['count'] ?? 0) > 0)) {
    final bars = insightsBarChart(
      [for (final d in byDay) (d['count'] ?? 0) as int],
      maxWidth: 15,
    );
    lines.addAll([
      ..._insightSection('📅 Pola Aktivitas'),
      for (var i = 0; i < byDay.length; i++)
        '  ${(byDay[i]['day'] ?? '').toString().padRight(4)}'
            '  ${(bars[i]).padRight(15)} ${byDay[i]['count']}',
    ]);
    final byHour = [
      for (final h in act['by_hour'] as List? ?? [])
        if (h is Map<String, dynamic>) h,
    ]..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    final busyHours = [
      for (final h in byHour)
        if ((h['count'] ?? 0) > 0) h,
    ].take(5).toList();
    if (busyHours.isNotEmpty) {
      lines.add(
        '  Jam tersibuk: ${[
          for (final h in busyHours)
            '${insightsHour12(h['hour'] as int)} (${h['count']})',
        ].join(', ')}',
      );
    }
    final activeDays = act['active_days'] is int ? act['active_days'] as int : 0;
    final maxStreak = act['max_streak'] is int ? act['max_streak'] as int : 0;
    if (activeDays > 0) lines.add('  Hari aktif: $activeDays');
    if (maxStreak > 1) lines.add('  Streak terbaik: $maxStreak hari berturut');
    lines.add('');
  }

  final topSessions = [
    for (final s in report['sessions'] as List? ?? [])
      if (s is Map<String, dynamic>) s,
  ];
  if (topSessions.isNotEmpty) {
    lines.addAll([
      ..._insightSection('🏆 Sesi Teratas'),
      for (final s in topSessions.take(5))
        '  ${(s['session'] ?? '').toString().padRight(18)}'
            'turn=${s['turns']} token=${s['tokens']}'
            '${(s['cost_usd'] as double) > 0 ? ' biaya=${formatCostLabel(s['cost_usd'] as double)}' : ''}',
      '',
    ]);
  }
  return lines.join('\n').trimRight();
}

/// Format laporan singkat untuk gateway/messaging, markdown
/// (Hermes `format_gateway`).
String insightsFormatGateway(Map<String, dynamic> report) {
  final days = report['days'] is int ? report['days'] as int : 30;
  if (report['empty'] == true) {
    return 'Tidak ada data sesi dalam $days hari terakhir.';
  }
  final o = report['overview'] as Map<String, dynamic>? ?? const {};
  final lines = <String>[
    '📊 **Tiko Insights** — $days hari terakhir',
    'Turn: ${o['turns'] ?? 0} | Token: ${o['tokens'] ?? 0} | '
        'Tool calls: ${o['tool_calls'] ?? 0}',
  ];
  final cost = o['cost_usd'];
  if (cost is num && cost > 0) {
    lines.add('Biaya (estimasi): ${formatCostLabel(cost.toDouble())}');
  }
  final models = [
    for (final m in report['models'] as List? ?? [])
      if (m is Map<String, dynamic>) m,
  ];
  if (models.isNotEmpty) {
    lines.add('**🤖 Model:**');
    for (final m in models.take(5)) {
      lines.add(
        '  ${m['model']} — ${m['turns']} turn, '
        '${m['tokens']} token',
      );
    }
  }
  final act = report['activity'] as Map<String, dynamic>? ?? const {};
  final busiestDay = act['busiest_day'] as Map<String, dynamic>?;
  final busiestHour = act['busiest_hour'] as Map<String, dynamic>?;
  if (busiestDay != null && busiestHour != null) {
    lines.add(
      '**📅 Tersibuk:** ${busiestDay['day']} '
      '(${busiestDay['count']} turn), '
      '${insightsHour12(busiestHour['hour'] as int)} '
      '(${busiestHour['count']} turn)',
    );
    if (act['active_days'] is int && (act['active_days'] as int) > 0) {
      lines.add('**Hari aktif:** ${act['active_days']}');
    }
    if (act['max_streak'] is int && (act['max_streak'] as int) > 1) {
      lines.add('**Streak terbaik:** ${act['max_streak']} hari berturut');
    }
  }
  return lines.join('\n');
}
