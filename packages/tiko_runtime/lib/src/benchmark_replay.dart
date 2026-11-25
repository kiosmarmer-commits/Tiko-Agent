// R4 — benchmark harness replay: memutar ulang trajektori hasil batch run
// (JSONL di data/trajectories, hasil TrajectoryLogger) menjadi kasus eval
// (EvalTaskSpec) lalu dijalankan lewat runEvalGate sebagai gerbang
// regresi, dengan opsi baseline report dan overlay ekspektasi.

part of 'tiko_runtime.dart';

/// Overlay ekspektasi per-task untuk replay (opsional): satu objek JSON per
/// baris `{"id": "<session>", "expect_contains": [...], "expect_not_contains":
/// [...], "min_tool_calls": n, "expect_success": bool}`. Id yang tidak cocok
/// diabaikan; field kosong/null tidak menimpa derivasi otomatis.
class ReplayOverlay {
  ReplayOverlay._({
    required this.expectContains,
    required this.expectNotContains,
    required this.minToolCalls,
    required this.expectSuccess,
  });

  factory ReplayOverlay.fromJson(Map<String, dynamic> m) => ReplayOverlay._(
        expectContains: [
          for (final v in (m['expect_contains'] as List<dynamic>? ?? const <dynamic>[]))
            if (v != null) v.toString(),
        ],
        expectNotContains: [
          for (final v in (m['expect_not_contains'] as List<dynamic>? ?? const <dynamic>[]))
            if (v != null) v.toString(),
        ],
        minToolCalls: m['min_tool_calls'] is int ? m['min_tool_calls'] as int : null,
        expectSuccess: m['expect_success'] is bool ? m['expect_success'] as bool : null,
      );

  final List<String> expectContains;
  final List<String> expectNotContains;
  final int? minToolCalls;
  final bool? expectSuccess;

  EvalTaskSpec apply(EvalTaskSpec base) => EvalTaskSpec(
        id: base.id,
        prompt: base.prompt,
        expectSuccess: expectSuccess ?? base.expectSuccess,
        expectContains: expectContains.isEmpty ? base.expectContains : expectContains,
        expectNotContains:
            expectNotContains.isEmpty ? base.expectNotContains : expectNotContains,
        minToolCalls: minToolCalls ?? base.minToolCalls,
        maxTokens: base.maxTokens,
      );
}

/// Konversi JSONL trajektori (format TrajectoryLogger: session/input/output/
/// tools/latency_ms/success) menjadi daftar [EvalTaskSpec]. Semua entri
/// sesi yang sama dikelompokkan menjadi satu kasus; prompt diambil dari
/// input entri PERTAMA sesi, ekspektasi sukses dari entri terburuk (semua
/// entri harus sukses agar replay dianggap sukses), dan jumlah tool
/// tercatat jadi [EvalTaskSpec.minToolCalls] bila [requireTools] aktif.
///
/// Kebijakan fail-soft: baris JSONL korup di-skip (tidak menggagalkan
/// replay seluruhnya).
Future<List<EvalTaskSpec>> specsFromTrajectoryDir(
  String directory, {
  bool requireTools = false,
}) async {
  final dir = Directory(directory);
  if (!dir.existsSync()) return const [];
  final bySession = <String, List<Map<String, dynamic>>>{};
  final order = <String>[];

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.jsonl'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    await for (final line
        in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final session = decoded['session']?.toString() ?? '';
      if (session.isEmpty) continue;
      if (!bySession.containsKey(session)) order.add(session);
      bySession.putIfAbsent(session, () => []).add(decoded);
    }
  }

  final tasks = <EvalTaskSpec>[];
  for (final session in order) {
    final entries = bySession[session]!;
    final first = entries.first;
    final prompt = (first['input'] ?? '').toString().trim();
    if (prompt.isEmpty) continue;
    final allSuccess = entries.every((e) => e['success'] == true);
    final tools = <String>{
      for (final e in entries)
        for (final raw in (e['tools'] as List<dynamic>? ?? const <dynamic>[]))
          if (raw != null) raw.toString(),
    }.toList()
      ..sort();
    tasks.add(EvalTaskSpec(
      id: session,
      prompt: prompt,
      expectSuccess: allSuccess,
      minToolCalls: requireTools ? tools.length : 0,
    ));
  }
  return tasks;
}

/// Bandingkan dua laporan eval (hasil [runEvalGate]: ada `entries`, `score`,
/// `passed`). Status per-task: improved (baseline fail → current pass),
/// regressed (baseline pass → current fail), selain itu same.
Map<String, dynamic> compareEvalReports({
  required Map<String, dynamic> current,
  required Map<String, dynamic> baseline,
}) {
  Map<String, Map<String, dynamic>> index(Map<String, dynamic> report) => {
        for (final e in (report['entries'] as List<dynamic>? ?? const <dynamic>[]))
          if (e is Map<String, dynamic> && e['task_id'] != null)
            e['task_id'].toString(): e,
      };

  final cur = index(current);
  final base = index(baseline);
  final ids = {...cur.keys, ...base.keys}.toList()..sort();

  final rows = <Map<String, dynamic>>[];
  final regressed = <String>[];
  final improved = <String>[];
  for (final id in ids) {
    final b = base[id];
    final c = cur[id];
    final bPassed = b == null ? null : b['passed'] == true;
    final cPassed = c == null ? false : c['passed'] == true;
    final status = bPassed == null
        ? 'new'
        : (bPassed && !cPassed
            ? 'regressed'
            : (!bPassed && cPassed ? 'improved' : 'same'));
    final bTokens = b == null ? null : (b['tokens_used'] as num?)?.toInt();
    final cTokens = c == null ? null : (c['tokens_used'] as num?)?.toInt();
    final bDur = b == null ? null : (b['duration_ms'] as num?)?.toInt();
    final cDur = c == null ? null : (c['duration_ms'] as num?)?.toInt();
    if (status == 'regressed') regressed.add(id);
    if (status == 'improved') improved.add(id);
    rows.add({
      'task_id': id,
      'status': status,
      'baseline_passed': bPassed,
      'current_passed': cPassed,
      'tokens_delta': (bTokens != null && cTokens != null) ? cTokens - bTokens : null,
      'duration_ms_delta': (bDur != null && cDur != null) ? cDur - bDur : null,
      if (c?['reasons'] is List && (c!['reasons'] as List).isNotEmpty)
        'reasons': c['reasons'],
    });
  }

  final baseScore = (baseline['score'] as num?)?.toDouble() ?? 0.0;
  final curScore = (current['score'] as num?)?.toDouble() ?? 0.0;
  return {
    'baseline_score': baseScore,
    'current_score': curScore,
    'score_delta': curScore - baseScore,
    'regressed': regressed,
    'improved': improved,
    'gate_passed': regressed.isEmpty,
    'rows': rows,
  };
}

/// Jalankan pipeline lengkap replay benchmark:
/// 1. Konversi trajektori JSONL di [trajectoryDir] jadi kasus eval.
/// 2. Terapkan overlay (`overlayPath`, opsional).
/// 3. Jalankan [runEvalGate] dengan [rt].
/// 4. Bila `baselinePath` diberi, bandingkan dengan laporan sebelumnya.
/// 5. Tulis laporan ke `outPath` bila diberi; selalu dikembalikan.
Future<Map<String, dynamic>> runBenchmarkReplay(
  TikoRuntime rt, {
  required String trajectoryDir,
  String? overlayPath,
  String? baselinePath,
  String? outPath,
  bool requireTools = false,
  String channel = 'eval-replay',
}) async {
  var tasks = await specsFromTrajectoryDir(trajectoryDir, requireTools: requireTools);

  var overlayApplied = 0;
  if (overlayPath != null && overlayPath.trim().isNotEmpty) {
    final overlayFile = File(overlayPath);
    if (!overlayFile.existsSync()) {
      throw ArgumentError('overlay tidak ditemukan: $overlayPath');
    }
    final overlays = <String, ReplayOverlay>{};
    for (final line
        in overlayFile.readAsStringSync().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final id = decoded['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      overlays[id] = ReplayOverlay.fromJson(decoded);
    }
    final merged = <EvalTaskSpec>[];
    for (final t in tasks) {
      if (overlays.containsKey(t.id)) {
        merged.add(overlays[t.id]!.apply(t));
        overlayApplied++;
      } else {
        merged.add(t);
      }
    }
    tasks = merged;
  }

  final gate = await runEvalGate(rt, tasks, channel: channel);

  Map<String, dynamic>? comparison;
  if (baselinePath != null && baselinePath.trim().isNotEmpty) {
    final baselineFile = File(baselinePath);
    if (!baselineFile.existsSync()) {
      throw ArgumentError('baseline tidak ditemukan: $baselinePath');
    }
    final baseline = jsonDecode(baselineFile.readAsStringSync())
        as Map<String, dynamic>;
    comparison = compareEvalReports(current: gate, baseline: baseline);
  }

  final report = <String, dynamic>{
    'scenario': 'trajectory-replay',
    'at': DateTime.now().toUtc().toIso8601String(),
    'trajectory_dir': trajectoryDir,
    'overlay_applied': overlayApplied,
    ...gate,
    if (comparison != null) 'comparison': comparison,
  };

  if (outPath != null && outPath.trim().isNotEmpty) {
    final out = File(outPath);
    await out.create(recursive: false);
    await out.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    report['report_path'] = outPath;
  }
  return report;
}

/// S19-D — self-improvement loop: panen golden eval dari trajektori sukses.
/// Trajektori hasil batch/chat (TrajectoryLogger) difilter hanya sesi yang
/// SELURUH turn-nya sukses, prompt non-internal (bukan `/…`), dedupe prompt,
/// lalu ditulis sebagai kasus eval JSONL (`EvalTaskSpec.fromJson`) yang bisa
/// langsung diputar `tiko eval <file>` atau di-overlay via `eval replay`.
/// Fail-closed: file output yang sudah ada ditolak (anti-timpa).
Future<Map<String, dynamic>> harvestGoldenEvals({
  required String trajectoryDir,
  required String outPath,
  bool requireTools = false,
  int limit = 100,
}) async {
  final target = File(outPath);
  if (target.existsSync()) {
    throw ArgumentError('file output sudah ada, tolak timpa: $outPath');
  }
  final specs = await specsFromTrajectoryDir(trajectoryDir, requireTools: requireTools);
  final seen = <String>{};
  final harvested = <EvalTaskSpec>[];
  var skippedFailed = 0;
  var skippedInternal = 0;
  var duplicates = 0;
  for (final spec in specs) {
    if (!spec.expectSuccess) {
      skippedFailed++;
      continue;
    }
    if (spec.prompt.startsWith('/')) {
      skippedInternal++;
      continue;
    }
    final key = spec.prompt.trim().toLowerCase();
    if (!seen.add(key)) {
      duplicates++;
      continue;
    }
    if (harvested.length >= limit) continue;
    harvested.add(EvalTaskSpec(
      id: spec.id,
      prompt: spec.prompt,
      expectSuccess: true,
      minToolCalls: spec.minToolCalls,
    ));
  }

  final buffer = StringBuffer();
  for (final spec in harvested) {
    buffer.writeln(jsonEncode({
      'id': spec.id,
      'prompt': spec.prompt,
      'expect_success': spec.expectSuccess,
      'min_tool_calls': spec.minToolCalls,
    }));
  }
  if (buffer.isNotEmpty) {
    final dir = Directory(p.dirname(outPath));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    await target.writeAsString(buffer.toString());
  }
  return {
    'trajectory_dir': trajectoryDir,
    'out_path': outPath,
    'total_sessions': specs.length,
    'harvested': harvested.length,
    'skipped_failed': skippedFailed,
    'skipped_internal': skippedInternal,
    'duplicates': duplicates,
    'limit': limit,
    'wrote_file': buffer.isNotEmpty,
  };
}
