// Fase D — riset otomatis terjadwal x Kanban.
part of 'tiko_runtime.dart';

//
// Referensi (2026-11):
// - Hermes Agent: cron job menempel di runtime (bukan polling platform),
//   tiap job jalan di sesi agent terisolasi, output dikirim via gateway,
//   dipakai untuk riset digest harian (web search -> sintesis -> kirim).
// - ChatGPT Tasks / Pulse: tugas terjadwal berbasis prompt + digest riset
//   proaktif harian — user tidak memilih model, hanya pertanyaan + jadwal.
// - GPT-Researcher / OpenAI Deep Research: pipeline multi-tahap
//   plan -> gather (sub-riset paralel) -> synthesize (laporan bersumber) ->
//   review (kritik), dengan sumber eksplisit.
// Perbedaan kunci yang wajib dirawat Tiko: riset adalah JOB scheduler
// (durable, retry, delivery-ack), bukan loop in-process — dan setiap state
// riset dicerminkan ke papan Kanban (`data/kanban.json`) supaya GUI/TUI
// menampilkan card riset yang bergerak backlog -> doing -> done/failed.

/// Awalan prompt job scheduler yang menandai run riset. Job yang dibuat
/// `schedule_research` / `tiko research schedule` menyimpan
/// `<prefix> <pertanyaan>`; handler scheduler runtime mendeteksinya dan
/// menjalankan pipeline riset alih-alih turn chat biasa.
const String researchPromptPrefix = '[RISET]';

bool isResearchJobPrompt(String prompt) {
  final t = prompt.trimLeft();
  if (!t.startsWith(researchPromptPrefix)) return false;
  final rest = t.substring(researchPromptPrefix.length);
  return rest.isEmpty || rest.startsWith(' ') || rest.startsWith('\t');
}

String researchQuestionFromPrompt(String prompt) {
  final t = prompt.trimLeft();
  if (!t.startsWith(researchPromptPrefix)) return '';
  return t.substring(researchPromptPrefix.length).trim();
}

/// Satu run riset — tersimpan di `<dataDir>/research/index.json`.
class ResearchRunRecord {
  ResearchRunRecord({
    required this.runId,
    required this.question,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.summary,
    required this.reportName,
    required this.kanbanTaskId,
    this.jobId,
    this.queries = const [],
    this.tokensUsed = 0,
    this.toolCallCount = 0,
    this.error,
  });

  final String runId;
  final String question;

  /// `ok` | `failed`. Run sebelum selesai tidak tersimpan (durabel lewat
  /// JobStore, bukan daftar run).
  final String status;

  final DateTime startedAt;
  final DateTime finishedAt;

  /// Ringkasan (digest) — inilah yang dikirim ke channel & jadi note kanban.
  final String summary;

  /// Nama file laporan di `<dataDir>/research/reports/` (bukan path penuh).
  final String reportName;
  final String kanbanTaskId;
  final String? jobId;
  final List<String> queries;
  final int tokensUsed;
  final int toolCallCount;
  final String? error;

  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'question': question,
    'status': status,
    'started_at': startedAt.toUtc().toIso8601String(),
    'finished_at': finishedAt.toUtc().toIso8601String(),
    'summary': summary,
    'report': reportName,
    'kanban_task': kanbanTaskId,
    if (jobId != null) 'job_id': jobId,
    'queries': queries,
    'tokens_used': tokensUsed,
    'tool_call_count': toolCallCount,
    if (error != null) 'error': error,
  };

  static ResearchRunRecord fromJson(Map<String, dynamic> j) =>
      ResearchRunRecord(
        runId: j['run_id']?.toString() ?? '',
        question: j['question']?.toString() ?? '',
        status: j['status']?.toString() == 'ok' ? 'ok' : 'failed',
        startedAt:
            DateTime.tryParse(j['started_at']?.toString() ?? '') ??
            DateTime.now().toUtc(),
        finishedAt:
            DateTime.tryParse(j['finished_at']?.toString() ?? '') ??
            DateTime.now().toUtc(),
        summary: j['summary']?.toString() ?? '',
        reportName: j['report']?.toString() ?? '',
        kanbanTaskId: j['kanban_task']?.toString() ?? '',
        jobId: j['job_id']?.toString(),
        queries: [
          for (final q in (j['queries'] as List? ?? const [])) q.toString(),
        ],
        tokensUsed: (j['tokens_used'] as num?)?.toInt() ?? 0,
        toolCallCount: (j['tool_call_count'] as num?)?.toInt() ?? 0,
        error: j['error']?.toString(),
      );
}

/// Store run riset: indeks JSON atomik + laporan markdown per run. Korup
/// atau traversal dilompati (fail-closed), mengikuti pola [BotTeamStore].
class ResearchRunStore {
  ResearchRunStore({required this.dataDir}) {
    reportsDir = p.join(dataDir, 'research', 'reports');
    indexPath = p.join(dataDir, 'research', 'index.json');
  }

  final String dataDir;
  late final String reportsDir;
  late final String indexPath;

  final List<ResearchRunRecord> _runs = [];
  bool _loaded = false;

  List<ResearchRunRecord> get runs {
    _ensureLoadedSync();
    return List.unmodifiable(_runs);
  }

  ResearchRunRecord? get(String runId) {
    _ensureLoadedSync();
    for (final r in _runs) {
      if (r.runId == runId) return r;
    }
    return null;
  }

  void _ensureLoadedSync() {
    if (_loaded) return;
    _loaded = true;
    final f = File(indexPath);
    if (!f.existsSync()) return;
    List<dynamic> list;
    try {
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      list = decoded;
    } on FormatException {
      return;
    }
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        try {
          _runs.add(ResearchRunRecord.fromJson(item));
        } on Exception {
          // record korup dilompati — jangan biarkan satu baris buruk
          // menggagalkan seluruh indeks.
        }
      }
    }
  }

  Future<void> _saveIndex() async {
    final dir = Directory(p.dirname(indexPath));
    await dir.create(recursive: true);
    final tmp = '$indexPath.tmp';
    await File(tmp).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final r in _runs) r.toJson()]),
    );
    await File(tmp).rename(indexPath);
  }

  Future<ResearchRunRecord> append(ResearchRunRecord record) async {
    _ensureLoadedSync();
    _runs.removeWhere((r) => r.runId == record.runId);
    _runs.insert(0, record);
    if (_runs.length > 200) {
      _runs.removeRange(200, _runs.length);
    }
    await _saveIndex();
    return record;
  }

  Future<String> saveReport(
    String runId,
    String question,
    String report,
  ) async {
    await Directory(reportsDir).create(recursive: true);
    final name = 'riset-$runId.md';
    final file = File(p.join(reportsDir, name));
    await file.writeAsString(
      '# Riset: $question\n\nRun: `$runId`\nTanggal: '
      '${DateTime.now().toUtc().toIso8601String()}\n\n$report\n',
      flush: true,
    );
    return name;
  }

  Future<String?> readReport(String name) async {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$').hasMatch(name) ||
        name.contains('..')) {
      return null;
    }
    final file = File(p.join(reportsDir, name));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  String reportPath(String name) => p.join(reportsDir, name);
}

/// Rencana riset hasil dekomposisi planner (atau fallback satu pertanyaan).
class ResearchPlan {
  const ResearchPlan({required this.source, required this.queries});
  final String source; // 'planner' | 'fallback'
  final List<String> queries;
}

/// Parse keluaran planner riset: JSON `{"queries":["...","..."]}` — item
/// boleh string atau objek `{"query": "..."}`. Menerima code fence & prose.
/// Fail-closed: null bila tidak ada pertanyaan valid; panggilan wajib pakai
/// fallback (pertanyaan user apa adanya). Maksimal [maxQueries] 1..6.
ResearchPlan? parseResearchPlan(String raw, {int maxQueries = 6}) {
  var text = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*(.*?)```', dotAll: true);
  final m = fence.firstMatch(text);
  if (m != null) text = m.group(1)!.trim();
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  text = text.substring(start, end + 1);

  final Map<String, dynamic> decoded;
  try {
    decoded = jsonDecode(text) as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
  final rawQueries = decoded['queries'];
  if (rawQueries is! List || rawQueries.isEmpty) return null;
  final limit = maxQueries.clamp(1, 6).toInt();
  final out = <String>[];
  for (final item in rawQueries) {
    String? q;
    if (item is String) {
      q = item;
    } else if (item is Map) {
      final map = Map<String, dynamic>.from(item);
      q = (map['query'] ?? map['question'] ?? map['prompt'])?.toString();
    }
    final trimmed = q?.trim() ?? '';
    if (trimmed.isEmpty || out.contains(trimmed)) continue;
    out.add(trimmed);
    if (out.length >= limit) break;
  }
  if (out.isEmpty) return null;
  return ResearchPlan(source: 'planner', queries: out);
}

/// Hasil pipeline [ResearchRunner].
class ResearchRunnerResult {
  const ResearchRunnerResult({
    required this.runId,
    required this.question,
    required this.success,
    required this.report,
    required this.summary,
    required this.queries,
    required this.tokensUsed,
    required this.toolCallCount,
    this.error,
  });

  final String runId;
  final String question;
  final bool success;

  /// Laporan markdown penuh (dengan bagian sumber).
  final String report;

  /// Ringkasan pendek (ulang dari laporan; fallback potongan laporan).
  final String summary;
  final List<String> queries;
  final int tokensUsed;
  final int toolCallCount;
  final String? error;
}

/// Callback turn sub-riset/sintesis/review — closure ke
/// `TikoRuntime.chatWithStatus`. [slot] adalah id sub-riset (`q<i>`) atau
/// label `__synthesis` / `__review`.
typedef ResearchTurn =
    Future<ChatRunResult> Function(String slot, String prompt);

/// Callback turn planner — tanpa tool (teks JSON rencana).
typedef ResearchPlannerTurn = Future<ChatRunResult> Function(String prompt);

/// Cerminkan state run riset ke papan [KanbanBoard]: card dibuat di
/// backlog, langsung di-claim (doing), lalu complete/fail dengan
/// ringkasan. Semua operasi best-effort — kegagalan papan tidak boleh
/// menggagalkan pipeline riset.
class ResearchKanbanTracker {
  ResearchKanbanTracker(this.board);

  final KanbanBoard board;

  static String title(String question) {
    final t = 'Riset: ${question.trim()}';
    return t.length <= 80 ? t : '${t.substring(0, 79)}…';
  }

  Future<String> start(String question, {String createdBy = 'riset'}) async {
    final card = await board.add(title(question), createdBy: createdBy);
    await board.claim(card.id, claimer: 'riset');
    return card.id;
  }

  Future<void> complete(String taskId, String summary, String reportName) =>
      board.complete(
        taskId,
        result: summary.trim().isEmpty
            ? 'laporan: data/research/reports/$reportName'
            : summary,
      );

  Future<void> fail(String taskId, String error) =>
      board.fail(taskId, result: 'riset gagal: $error');
}

/// Runner pipeline riset (Fase D). Murni (injected callbacks) — tanpa
/// mengenal router/registry host, deterministik di test.
///
/// Tahapan (GPT-Researcher shape):
/// 1. plan    — planner tanpa tool: dekomposisi pertanyaan -> 1..6 query.
/// 2. gather  — sub-riset paralel (clamp [maxConcurrency]) dengan tool
///              riset (web_search/web_fetch/http/file).
/// 3. synthesize — tulis laporan bersumber dari temuan.
/// 4. review  — critic memberi catatan yang ditempel di laporan.
class ResearchRunner {
  ResearchRunner({
    required this.plannerTurn,
    required this.researcherTurn,
    this.maxConcurrency = 3,
    this.emitEvent,
  }) {
    if (maxConcurrency < 1 || maxConcurrency > 4) {
      throw ArgumentError('maxConcurrency harus 1..4');
    }
  }

  final ResearchPlannerTurn plannerTurn;
  final ResearchTurn researcherTurn;
  final int maxConcurrency;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;

  void _emit(String type, Map<String, dynamic> data) =>
      emitEvent?.call(type, data);

  static String _plannerPrompt(String question) =>
      '''
Pecah pertanyaan riset berikut menjadi 1-6 sub-pertanyaan pencarian yang
spesifik, mandiri, dan saling melengkapi (tidak duplikat).
Balas HANYA JSON — tanpa penjelasan — bentuk persis:
{"queries":["<sub-pertanyaan 1>","<sub-pertanyaan 2>"]}

Pertanyaan riset:
$question'''
          .trim();

  static String _gatherPrompt(String query, int index, int total) =>
      '''
Kamu sub-riset $index/$total. Kumpulkan temuan FAKTUAL untuk sub-pertanyaan
berikut menggunakan tool riset yang tersedia (web_search, web_fetch,
http_request, read_file, list_dir, grep, unzip_archive) — jangan mengarang.

Sub-pertanyaan:
$query

Keluaran (maks ~60 baris): temuan poin-per-poin, tiap klaim disertai sumber
(URL atau path file). Bila tool gagal/tidak tersedia, jawab jujur apa yang
bisa disimpulkan dari informasi yang kamu miliki dan tandai ketidakpastian.''';

  static String _synthesisPrompt(String question, List<String> findings) =>
      '''
Tulis laporan riset markdown untuk pertanyaan berikut, hanya dari temuan
di bawah (jangan menambah klaim tanpa sumber). Struktur wajib:
## Ringkasan  (3-5 poin inti)
## Temuan     (per sub-pertanyaan, klaim + sumber)
## Kesimpulan (jawaban langsung atas pertanyaan)
## Sumber     (daftar URL/path unik)

Pertanyaan riset:
$question

Temuan sub-riset:
${findings.join('\n\n---\n\n')}''';

  static String _reviewPrompt(String report) => '''
Periksa laporan riset berikut: klaim tanpa sumber, sumber yang tidak
mendukung klaim, dan jawaban yang tidak menjawab pertanyaan.
Balas maksimal 5 poin catatan. Bila laporan sudah baik, balas
persis: LAPORAN_OK.

Laporan:
$report''';

  Future<ResearchRunnerResult> run({required String question}) async {
    final q = question.trim();
    if (q.isEmpty) throw ArgumentError('question wajib');
    final runId = 'r${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    var tokens = 0;
    var toolCalls = 0;

    _emit('research.started', {'run_id': runId, 'question': q});

    // ── 1. Plan ─────────────────────────────────────────────────────────
    var plan = ResearchPlan(source: 'fallback', queries: [q]);
    try {
      final turn = await plannerTurn(_plannerPrompt(q));
      tokens += turn.tokensUsed;
      toolCalls += turn.toolCallCount;
      final parsed = parseResearchPlan(turn.text);
      if (parsed != null) plan = parsed;
    } catch (e) {
      // Planner gagal → fallback satu pertanyaan; riset tidak pernah mati
      // hanya karena dekomposisi gagal.
      _emit('research.plan_fallback', {'run_id': runId, 'error': '$e'});
    }
    _emit('research.planned', {
      'run_id': runId,
      'source': plan.source,
      'queries': plan.queries,
    });

    // ── 2. Gather (paralel terbatas) ────────────────────────────────────
    final findings = List<String?>.filled(plan.queries.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= plan.queries.length) return;
        final query = plan.queries[i];
        final slot = 'q${i + 1}';
        _emit('research.gather_started', {
          'run_id': runId,
          'slot': slot,
          'query': query,
        });
        try {
          final turn = await researcherTurn(
            slot,
            _gatherPrompt(query, i + 1, plan.queries.length),
          );
          tokens += turn.tokensUsed;
          toolCalls += turn.toolCallCount;
          findings[i] = turn.text.trim();
          _emit('research.gather_done', {
            'run_id': runId,
            'slot': slot,
            'success': turn.success,
          });
        } catch (e) {
          // Satu sub-riset gagal tidak menggagalkan run — ditandai jujur
          // di temuan untuk dievaluasi tahap sintesis.
          findings[i] = '(sub-riset gagal: $e)';
          _emit('research.gather_failed', {
            'run_id': runId,
            'slot': slot,
            'error': '$e',
          });
        }
      }
    }

    await Future.wait([for (var w = 0; w < maxConcurrency; w++) worker()]);

    // ── 3. Synthesize ───────────────────────────────────────────────────
    final materialized = <String>[];
    for (var i = 0; i < findings.length; i++) {
      materialized.add(
        '## Sub-riset ${i + 1}: ${plan.queries[i]}\n'
        '${findings[i] ?? '(tidak ada temuan)'}',
      );
    }
    String report;
    try {
      final turn = await researcherTurn(
        '__synthesis',
        _synthesisPrompt(q, materialized),
      );
      tokens += turn.tokensUsed;
      toolCalls += turn.toolCallCount;
      report = turn.text.trim();
    } catch (e) {
      return ResearchRunnerResult(
        runId: runId,
        question: q,
        success: false,
        report: materialized.join('\n\n'),
        summary: '(sintesis gagal: $e)',
        queries: plan.queries,
        tokensUsed: tokens,
        toolCallCount: toolCalls,
        error: '$e',
      );
    }
    if (report.isEmpty) report = materialized.join('\n\n');

    // ── 4. Review ───────────────────────────────────────────────────────
    var reviewNote = '';
    try {
      final turn = await researcherTurn('__review', _reviewPrompt(report));
      tokens += turn.tokensUsed;
      toolCalls += turn.toolCallCount;
      final note = turn.text.trim();
      if (note.isNotEmpty && !note.contains('LAPORAN_OK')) {
        reviewNote = note;
      }
    } catch (e) {
      // Review bersifat best-effort; kegagalan tidak menggagalkan run.
      _emit('research.review_failed', {'run_id': runId, 'error': '$e'});
    }
    var finalReport = report;
    if (reviewNote.isNotEmpty) {
      finalReport = '$report\n\n## Catatan Review\n$reviewNote';
    }

    // Ringkasan: pakai bagian "## Ringkasan" kalau ada, kalau tidak awal
    // laporan dipotong.
    var summary = '';
    final sm = RegExp(
      r'^##\s*Ringkasan\s*$(.*?)(?=^##\s|\z)',
      multiLine: true,
      dotAll: true,
    ).firstMatch(finalReport);
    if (sm != null) {
      summary = sm.group(1)!.trim();
    } else {
      summary = finalReport.length <= 600
          ? finalReport
          : '${finalReport.substring(0, 600)}…';
    }

    final result = ResearchRunnerResult(
      runId: runId,
      question: q,
      success: true,
      report: finalReport,
      summary: summary,
      queries: plan.queries,
      tokensUsed: tokens,
      toolCallCount: toolCalls,
    );
    _emit('research.finished', {
      'run_id': runId,
      'success': true,
      'queries': plan.queries,
      'tokens_used': tokens,
    });
    return result;
  }
}

/// Tool `deep_research` — jalankan pipeline riset sekarang dan simpan
/// laporan + state kanban. Medium risk (di belakang approval ask-mode).
class DeepResearchTool implements Tool {
  DeepResearchTool(this.starter);

  final Future<ResearchRunRecord> Function(String question) starter;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'deep_research',
    description:
        'Riset mendalam multi-tahap (plan -> gather -> sintesis -> '
        'review): kumpulkan temuan bersumber, tulis laporan markdown, '
        'simpan di data/research, catat di papan Kanban.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string'},
      },
      'required': ['question'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final question = (args['question'] as String?)?.trim() ?? '';
    if (question.isEmpty) {
      return const ToolResult(
        content: 'question wajib',
        callId: '',
        isError: true,
      );
    }
    try {
      final record = await starter(question);
      final ok = record.status == 'ok';
      return ToolResult(
        callId: '',
        isError: !ok,
        content: ok
            ? 'Riset selesai id=${record.runId}\n'
                  'queries=${record.queries.length}\n'
                  'laporan=data/research/reports/${record.reportName}\n'
                  'kanban=${record.kanbanTaskId}\n\n'
                  '${record.summary}'
            : 'Riset gagal id=${record.runId}: ${record.error}\n',
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'deep_research error: $e',
        isError: true,
      );
    }
  }
}

/// Tool `schedule_research` — buat job scheduler riset berkala. Prompt job
/// memakai `[RISET] <pertanyaan>`; scheduler runtime mendeteksi prefiks dan
/// menjalankan pipeline riset tiap tick, lalu mengirim digest ke channel
/// milik job (layanan Hermes-parity).
class ScheduleResearchTool implements Tool {
  ScheduleResearchTool(this.scheduler);

  final Future<Job> Function({
    required String question,
    required String cron,
    required String timezone,
    required String channel,
    required String userKey,
  })
  scheduler;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'schedule_research',
    description:
        'Jadwalkan riset berkala: tiap tick, pipeline riset dijalankan '
        'dan digest hasilnya dikirim ke channel. cron 5 field '
        '(menit jam dom bulan dow), mis. "0 7 * * 1-5".',
    inputSchema: {
      'type': 'object',
      'properties': {
        'cron': {'type': 'string'},
        'question': {'type': 'string'},
        'timezone': {
          'type': 'string',
          'description': 'Nama zona IANA penuh, mis. Asia/Jakarta',
        },
        'channel': {'type': 'string', 'description': 'cli | telegram | …'},
        'user_key': {'type': 'string'},
      },
      'required': ['cron', 'question'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cron = (args['cron'] as String?)?.trim() ?? '';
    final question = (args['question'] as String?)?.trim() ?? '';
    if (cron.isEmpty || question.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'cron dan question wajib',
        isError: true,
      );
    }
    final tz = (args['timezone'] as String?)?.trim();
    final ch = (args['channel'] as String?)?.trim();
    final uk = (args['user_key'] as String?)?.trim();
    try {
      final job = await scheduler(
        question: question,
        cron: cron,
        timezone: (tz == null || tz.isEmpty) ? 'UTC' : tz,
        channel: (ch == null || ch.isEmpty) ? ctx.session.channel : ch,
        userKey: (uk == null || uk.isEmpty) ? ctx.session.userKey : uk,
      );
      return ToolResult(
        callId: '',
        content:
            'Riset terjadwal job=${job.id}\n'
            'cron=${job.cron}\n'
            'tz=${job.timezone}\n'
            'next_run=${job.nextRun.toIso8601String()}\n'
            'question=$question',
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'schedule_research error: $e',
        isError: true,
      );
    }
  }
}

/// Fase D — integrasi riset otomatis ke [TikoRuntime].
extension ResearchWiring on TikoRuntime {
  /// Tool riset bawaan untuk turn sub-riset. Tanpa write/shell — laporan
  /// ditulis runtime, bukan model (fail-closed terhadap akses shell liar).
  static const Set<String> defaultResearchTools = {
    'web_search',
    'web_fetch',
    'http_request',
    'read_file',
    'list_dir',
    'grep',
    'unzip_archive',
    'datetime',
  };

  Future<ChatRunResult> _researchTurn(
    String prompt, {
    required String sessionId,
    required String persona,
    required bool withTools,
  }) {
    final eco = resourceProfile == 'eco';
    String? personaPrompt;
    if (persona.isNotEmpty) {
      for (final a in AgentTeamTool.defaultRegistry.all) {
        if (a.id == persona) {
          personaPrompt = a.systemPrompt.isEmpty ? null : a.systemPrompt;
          break;
        }
      }
    }
    return chatWithStatus(
      prompt,
      sessionId: sessionId,
      channel: 'research',
      userKey: 'research',
      toolFilter: withTools ? defaultResearchTools : const <String>{},
      configOverride: AgentConfig(
        maxIterations: eco ? 4 : 12,
        maxTokensPerTask: eco ? 20000 : config.maxTokensPerTask,
        maxWallClockSec: eco ? 120 : config.maxWallClockSec,
        maxToolCalls: eco ? 4 : 24,
      ),
      personaPrompt: personaPrompt,
    );
  }

  /// Jalankan riset penuh + terminate ke Kanban (`data/kanban.json`) dan
  /// simpan run di `data/research/`. Tidak pernah throw untuk kegagalan
  /// pipeline — semua masalah menjadi status `failed` pada record.
  Future<ResearchRunRecord> runResearch({
    required String question,
    String? jobId,
    bool mirrorKanban = true,
    int maxConcurrency = 3,
  }) async {
    final store = ResearchRunStore(dataDir: dataDir);
    final runningAt = DateTime.now().toUtc();

    var kanbanId = '';
    final tracker = mirrorKanban
        ? ResearchKanbanTracker(KanbanBoard(p.join(dataDir, 'kanban.json')))
        : null;
    if (tracker != null) {
      try {
        kanbanId = await tracker.start(
          question,
          createdBy: jobId == null ? 'riset' : 'riset:$jobId',
        );
      } catch (e) {
        events.emit('research.kanban_error', {'error': '$e'});
      }
    }

    ResearchRunRecord record;
    try {
      final runner = ResearchRunner(
        plannerTurn: (prompt) {
          final stamp = DateTime.now().microsecondsSinceEpoch;
          return _researchTurn(
            prompt,
            sessionId: 'research:adhoc:__plan:$stamp',
            persona: 'planner',
            withTools: false,
          );
        },
        researcherTurn: (slot, prompt) {
          final stamp = DateTime.now().microsecondsSinceEpoch;
          return _researchTurn(
            prompt,
            sessionId: 'research:adhoc:$slot:$stamp',
            persona: slot == '__review' ? 'critic' : 'researcher',
            withTools: slot != '__synthesis' && slot != '__review',
          );
        },
        maxConcurrency: maxConcurrency.clamp(1, 4).toInt(),
        emitEvent: (type, data) => events.emit(type, data),
      );
      final result = await runner.run(question: question);
      final reportName = await store.saveReport(
        result.runId,
        result.question,
        result.report,
      );
      record = ResearchRunRecord(
        runId: result.runId,
        question: result.question,
        status: result.success ? 'ok' : 'failed',
        startedAt: runningAt,
        finishedAt: DateTime.now().toUtc(),
        summary: result.summary,
        reportName: reportName,
        kanbanTaskId: kanbanId,
        jobId: jobId,
        queries: result.queries,
        tokensUsed: result.tokensUsed,
        toolCallCount: result.toolCallCount,
        error: result.error,
      );
      await store.append(record);
      if (mirrorKanban && kanbanId.isNotEmpty) {
        try {
          await tracker!.complete(kanbanId, record.summary, reportName);
        } catch (e) {
          events.emit('research.kanban_error', {'error': '$e'});
        }
      }
    } catch (e) {
      record = ResearchRunRecord(
        runId: 'r${runningAt.microsecondsSinceEpoch.toRadixString(36)}',
        question: question.trim(),
        status: 'failed',
        startedAt: runningAt,
        finishedAt: DateTime.now().toUtc(),
        summary: '',
        reportName: '',
        kanbanTaskId: kanbanId,
        jobId: jobId,
        error: '$e',
      );
      await store.append(record);
      if (mirrorKanban && kanbanId.isNotEmpty) {
        try {
          await tracker!.fail(kanbanId, '$e');
        } catch (_) {}
      }
    }
    return record;
  }

  /// Buat job scheduler riset (prompt ber-prefix [researchPromptPrefix]).
  /// Channel/userKey default mengikuti sesi pemanggil agar digest dikirim
  /// balik ke tempat user bertanya.
  Future<Job> scheduleResearch({
    required String question,
    required String cron,
    String timezone = 'UTC',
    String? channel,
    String? userKey,
  }) {
    return jobs.addAndSave(
      cron: cron,
      prompt: '$researchPromptPrefix ${question.trim()}',
      channel: channel ?? 'cli',
      userKey: userKey ?? 'cli',
      timezone: timezone,
    );
  }

  /// Daftar job riset aktif (prompt ber-prefix).
  List<Job> researchJobs() => [
    for (final j in jobs.all)
      if (isResearchJobPrompt(j.prompt)) j,
  ];
}
