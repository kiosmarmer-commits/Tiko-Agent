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
    this.refineRounds = 0,
    this.pdfName,
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

  /// F4 — jumlah putaran refine (critique -> re-plan -> gather -> sintesis
  /// -> review) yang benar-benar dijalankan (0..2).
  final int refineRounds;

  /// F4 — nama file ekspor PDF di `<dataDir>/research/reports/` (best-effort;
  /// null bila ekspor gagal atau tidak dijalankan).
  final String? pdfName;
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
    if (refineRounds > 0) 'refine_rounds': refineRounds,
    if (pdfName != null) 'pdf': pdfName,
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
        refineRounds: (j['refine_rounds'] as num?)?.toInt() ?? 0,
        pdfName: j['pdf']?.toString(),
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

  /// F4 — simpan ekspor PDF laporan riset. Nama file mengikuti pola laporan
  /// markdown (`riset-<id>.pdf`) dan tunduk pada jail nama yang sama dengan
  /// [readReport]. Gagal sebuah ekspor tidak boleh menggagalkan run riset —
  /// pemanggil memutuskan (best-effort).
  Future<String> savePdfReport(String runId, Uint8List bytes) async {
    await Directory(reportsDir).create(recursive: true);
    final name = 'riset-$runId.pdf';
    final file = File(p.join(reportsDir, name));
    await file.writeAsBytes(bytes, flush: true);
    return name;
  }
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

/// F4 — dedupe bagian `## Sumber` laporan riset. Entri URL/path dinormalisasi
/// (fragment + parameter pelacakan `utm_*`/`fbclid`/`gclid`/`ref` dibuang,
/// trailing slash diratakan, case-insensitive) dan duplikat direduksi ke
/// kemunculan pertama apa adanya. Laporan tanpa bagian `## Sumber` tidak
/// diubah. Murni, deterministik, diuji langsung di `research_test.dart`.
String dedupeSources(String report) {
  final lines = report.split('\n');
  final headingRe = RegExp(r'^##\s*Sumber\s*$');
  var heading = -1;
  for (var i = 0; i < lines.length; i++) {
    if (headingRe.hasMatch(lines[i])) {
      heading = i;
      break;
    }
  }
  if (heading < 0) return report;
  var sectionEnd = lines.length;
  for (var i = heading + 1; i < lines.length; i++) {
    if (RegExp(r'^#{1,6}\s').hasMatch(lines[i])) {
      sectionEnd = i;
      break;
    }
  }
  final seen = <String>{};
  final kept = <String>[];
  for (final line in lines.sublist(heading + 1, sectionEnd)) {
    final norm = _normalizeSource(line);
    if (norm == null) {
      kept.add(line);
      continue;
    }
    if (!seen.add(norm)) continue;
    kept.add(line);
  }
  return [
    ...lines.sublist(0, heading + 1),
    ...kept,
    ...lines.sublist(sectionEnd),
  ].join('\n');
}

/// Kunci dedupe untuk satu baris sumber. null = baris kosong (dipertahankan
/// apa adanya). URL diekstrak dari bullet; baris non-URL dinormalisasi utuh
/// (lowercase) sehingga teks duplikat juga tereduksi.
String? _normalizeSource(String line) {
  final t = line.trim().replaceAll(
        RegExp(r'^[-*+]\s+|^\d+[.)]\s+'),
        '',
      );
  if (t.isEmpty) return null;
  final url = RegExp(r'https?://\S+').firstMatch(t)?.group(0);
  if (url == null) return t.toLowerCase();
  var u = url.split('#').first.toLowerCase();
  final qIdx = u.indexOf('?');
  if (qIdx >= 0) {
    final params = u
        .substring(qIdx + 1)
        .split('&')
        .where(
          (kv) => kv.isNotEmpty &&
              !RegExp(r'^(utm_[a-z]+|fbclid|gclid|msclkid|ref|ref_src)=').hasMatch(kv),
        )
        .toList();
    final path = u.substring(0, qIdx);
    final pathKey = path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    u = params.isEmpty
        ? pathKey
        : '$pathKey?${params.join('&')}';
  }
  while (u.length > 1 && u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
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
    this.refineRounds = 0,
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

  /// F4 — jumlah putaran refine yang dijalankan (critique -> re-plan ->
  /// gather -> sintesis -> review), 0..maxRefineRounds.
  final int refineRounds;
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
    this.maxRefineRounds = 0,
    this.tokenBudget,
    this.verifyClaims = false,
  }) {
    if (maxConcurrency < 1 || maxConcurrency > 4) {
      throw ArgumentError('maxConcurrency harus 1..4');
    }
    if (maxRefineRounds < 0 || maxRefineRounds > 2) {
      throw ArgumentError('maxRefineRounds harus 0..2');
    }
    if (tokenBudget != null && tokenBudget! < 1) {
      throw ArgumentError('tokenBudget minimal 1 bila diset');
    }
  }

  final ResearchPlannerTurn plannerTurn;
  final ResearchTurn researcherTurn;
  final int maxConcurrency;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;

  /// F4 — maks putaran critique -> re-plan -> gather -> sintesis -> review
  /// setelah review pertama (0 = perilaku lama, default untuk kompatibilitas
  /// test/callbacks lama; runtime mengaktifkan 2).
  final int maxRefineRounds;

  /// F4 — budget guard refine: putaran berhenti bila token terpakai sudah
  /// melampaui angka ini (null = tanpa batas budget refine).
  final int? tokenBudget;

  /// F4 — stage verifikasi evidence: setelah laporan final (dan refine),
  /// slot `__verify` (dengan tool) diminta mengikat klaim utama ke bukti
  /// via `claim` + `verify_claims`; hasilnya jadi bagian laporan.
  final bool verifyClaims;

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

  /// F4 — planner khusus refine: tutup gap dari kritik reviewer dengan
  /// sub-pertanyaan BARU; jangan ulangi yang sudah diteliti.
  static String _refinePlannerPrompt(String question, String critique) =>
      '''
Kamu planner riset. Kritik reviewer menunjukkan gap laporan riset berikut.
Susun HANYA JSON — tanpa penjelasan — bentuk persis:
{"queries":["<sub-pertanyaan BARU 1>","..."]}

Aturan: 1-4 sub-pertanyaan pencarian spesifik untuk menutup gap tersebut,
JANGAN mengulang pertanyaan yang sudah diteliti. Bila tidak ada gap yang
bisa ditambal dengan pencarian, balas {"queries":[]}.

Pertanyaan riset awal:
$question

Kritik reviewer:
$critique''';

  /// F4 — prompt stage verifikasi evidence (tool claim + verify_claims)
  /// sebelum laporan final terbit.
  static String _verifyPrompt(String report) => '''
Verifikasi laporan riset berikut dengan tool yang tersedia (claim,
verify_claims, web_search, web_fetch, http_request). Pilih hingga 3 klaim
utama, cek ulang tiap klaim dengan tool riset, ikat hasilnya ke bukti
(ID call dari cek-mu sendiri) dengan tool `claim`, lalu jalankan
`verify_claims`. Keluaran (maks ~20 baris): status OK/FAIL per klaim plus
sumber cek. Bila tidak ada klaim yang bisa diverifikasi, balas persis:
VERIFIKASI_TIDAK_TERSEDIA.

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

    // ── 2. Gather (paralel terbatas) ─────────────────────────────────────────
    // F4: gather jadi closure reusable — dipakai putaran awal DAN tiap
    // putaran refine (query tambahan menutup gap hasil kritik reviewer).
    final findings = <String>[]; // blok '## Sub-riset N: query' siap sintesis
    var cursor = 0;
    Future<void> worker(List<String> queries, String slotPrefix) async {
      while (true) {
        final i = cursor++;
        if (i >= queries.length) return;
        final query = queries[i];
        final slot = '$slotPrefix${i + 1}';
        _emit('research.gather_started', {
          'run_id': runId,
          'slot': slot,
          'query': query,
        });
        try {
          final turn = await researcherTurn(
            slot,
            _gatherPrompt(query, i + 1, queries.length),
          );
          tokens += turn.tokensUsed;
          toolCalls += turn.toolCallCount;
          findings.add(
            '## Sub-riset ${findings.length + 1}: $query\n${turn.text.trim()}',
          );
          _emit('research.gather_done', {
            'run_id': runId,
            'slot': slot,
            'success': turn.success,
          });
        } catch (e) {
          // Satu sub-riset gagal tidak menggagalkan run — ditandai jujur
          // di temuan untuk dievaluasi tahap sintesis.
          findings.add(
            '## Sub-riset ${findings.length + 1}: $query\n(sub-riset gagal: $e)',
          );
          _emit('research.gather_failed', {
            'run_id': runId,
            'slot': slot,
            'error': '$e',
          });
        }
      }
    }

    Future<void> gather(List<String> queries, String slotPrefix) {
      cursor = 0;
      return Future.wait([
        for (var w = 0; w < maxConcurrency; w++) worker(queries, slotPrefix),
      ]);
    }

    await gather(plan.queries, 'q');

    // ── 3. Synthesize ───────────────────────────────────────────────────────
    String report;
    Future<String> synthesize(String critique) async {
      final turn = await researcherTurn(
        '__synthesis',
        critique.isEmpty
            ? _synthesisPrompt(q, findings)
            : _synthesisPrompt(
                '$q\n\nCatatan reviewer yang wajib ditutup:\n$critique',
                findings,
              ),
      );
      tokens += turn.tokensUsed;
      toolCalls += turn.toolCallCount;
      return turn.text.trim();
    }

    try {
      report = await synthesize('');
    } catch (e) {
      return ResearchRunnerResult(
        runId: runId,
        question: q,
        success: false,
        report: findings.join('\n\n'),
        summary: '(sintesis gagal: $e)',
        queries: plan.queries,
        tokensUsed: tokens,
        toolCallCount: toolCalls,
        error: '$e',
      );
    }
    if (report.isEmpty) report = findings.join('\n\n');

    // ── 4. Review ───────────────────────────────────────────────────────────
    Future<String> review(String rpt) async {
      final turn = await researcherTurn('__review', _reviewPrompt(rpt));
      tokens += turn.tokensUsed;
      toolCalls += turn.toolCallCount;
      return turn.text.trim();
    }

    var reviewNote = '';
    try {
      final note = await review(report);
      if (note.isNotEmpty && !note.contains('LAPORAN_OK')) {
        reviewNote = note;
      }
    } catch (e) {
      // Review bersifat best-effort; kegagalan tidak menggagalkan run.
      _emit('research.review_failed', {'run_id': runId, 'error': '$e'});
    }

    // ── 4b. Refine (F4) — critique -> re-plan -> gather -> synth -> review.
    // Maks [maxRefineRounds] putaran, budget-guarded via [tokenBudget]:
    // satu langkah gagal/tidak produktif dipotong, run tidak pernah mati.
    var refineRounds = 0;
    var critique = reviewNote;
    while (critique.isNotEmpty &&
        refineRounds < maxRefineRounds &&
        (tokenBudget == null || tokens < tokenBudget!)) {
      _emit('research.refine_started', {
        'run_id': runId,
        'round': refineRounds + 1,
      });
      ResearchPlan? refined;
      try {
        final turn = await plannerTurn(_refinePlannerPrompt(q, critique));
        tokens += turn.tokensUsed;
        toolCalls += turn.toolCallCount;
        refined = parseResearchPlan(turn.text, maxQueries: 4);
      } catch (e) {
        _emit('research.refine_failed', {'run_id': runId, 'error': '$e'});
        break;
      }
      final followups = <String>[
        if (refined != null)
          for (final nq in refined.queries)
            if (!plan.queries.any((oq) => oq.toLowerCase() == nq.toLowerCase()))
              nq,
      ];
      if (followups.isEmpty) {
        _emit('research.refine_noop', {'run_id': runId});
        break;
      }
      refineRounds++;
      plan = ResearchPlan(
        source: refineRounds == 1 && plan.source == 'planner'
            ? 'planner'
            : 'refine',
        queries: [...plan.queries, ...followups],
      );
      _emit('research.refine_planned', {
        'run_id': runId,
        'round': refineRounds,
        'queries': followups,
      });
      await gather(followups, 'r${refineRounds}q');
      try {
        report = await synthesize(critique);
        if (report.isEmpty) report = findings.join('\n\n');
      } catch (e) {
        _emit('research.refine_failed', {'run_id': runId, 'error': '$e'});
        break;
      }
      try {
        final note = await review(report);
        critique = note.isNotEmpty && !note.contains('LAPORAN_OK') ? note : '';
      } catch (e) {
        _emit('research.review_failed', {'run_id': runId, 'error': '$e'});
        critique = '';
      }
    }

    // F4: catatan review efektif = hasil review TERAKHIR (putaran awal
    // yang sudah ditambal oleh refine tidak lagi relevan di laporan final).
    reviewNote = critique;

    // ── 4c. Verifikasi evidence (F4, opt-in) — klaim utama diikat ke bukti
    // (tool claim) lalu diverifikasi (verify_claims) sebelum laporan terbit.
    var verifySection = '';
    if (verifyClaims) {
      try {
        final turn = await researcherTurn('__verify', _verifyPrompt(report));
        tokens += turn.tokensUsed;
        toolCalls += turn.toolCallCount;
        final out = turn.text.trim();
        if (out.isNotEmpty && !out.contains('VERIFIKASI_TIDAK_TERSEDIA')) {
          verifySection = out;
        }
      } catch (e) {
        // Best-effort: kegagalan verifikasi tidak menggagalkan laporan.
        _emit('research.verify_failed', {'run_id': runId, 'error': '$e'});
      }
    }

    var finalReport = report;
    if (verifySection.isNotEmpty) {
      finalReport = '$finalReport\n\n## Verifikasi Klaim\n$verifySection';
    }
    if (reviewNote.isNotEmpty) {
      finalReport = '$finalReport\n\n## Catatan Review\n$reviewNote';
    }
    finalReport = dedupeSources(finalReport);

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
      refineRounds: refineRounds,
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
        'review -> refine terarah maks 2 putaran budget-guarded -> '
        'verifikasi klaim): temuan bersumber, laporan markdown + ekspor '
        'PDF, simpan di data/research, catat di papan Kanban.',
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
                  'refine_rounds=${record.refineRounds}\n'
                  'laporan=data/research/reports/${record.reportName}\n'
                  '${record.pdfName == null ? '' : 'pdf=data/research/reports/${record.pdfName}\n'}'
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
    // F4 — klaim + verifikasi bukti untuk stage verifikasi laporan.
    'claim',
    'verify_claims',
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
            persona: slot == '__review' || slot == '__verify'
                ? 'critic'
                : 'researcher',
            withTools: slot != '__synthesis' && slot != '__review',
          );
        },
        maxConcurrency: maxConcurrency.clamp(1, 4).toInt(),
        emitEvent: (type, data) => events.emit(type, data),
        // F4 — riset unggul: refine terarah maks 2 putaran (budget-guarded)
        // + verifikasi evidence sebelum laporan terbit.
        maxRefineRounds: 2,
        tokenBudget: resourceProfile == 'eco' ? 60000 : 300000,
        verifyClaims: true,
      );
      final result = await runner.run(question: question);
      final reportName = await store.saveReport(
        result.runId,
        result.question,
        result.report,
      );
      // F4 — ekspor PDF (pure Dart, tanpa dependensi). Best-effort:
      // kegagalan ekspor tidak menggagalkan run — dipantau via event.
      String? pdfName;
      try {
        pdfName = await store.savePdfReport(
          result.runId,
          buildPdfReport(result.report),
        );
      } catch (e) {
        events.emit('research.pdf_export_failed', {
          'run_id': result.runId,
          'error': '$e',
        });
      }
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
        refineRounds: result.refineRounds,
        pdfName: pdfName,
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
