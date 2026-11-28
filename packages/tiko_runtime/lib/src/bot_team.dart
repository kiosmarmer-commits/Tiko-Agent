part of 'tiko_runtime.dart';

/// Fase C — orkestra bot team (Hermes-parity, paritas bot teams Claude Code):
/// tujuan pengguna dipecah otomatis oleh planner menjadi DAG tugas, tugas
/// independen berjalan paralel oleh anggota terspesialisasi (researcher,
/// coder, critic, summarizer), hasilnya dibagi lewat blackboard, lalu
/// disintesis dan direview — dengan gate verifikasi objektif opsional
/// (mewarisi kontrak Fase B: exit 0 adalah satu-satunya bukti sukses).
///
/// Prinsip yang sama dengan Fase A/B:
/// - **Fail-closed:** rencana planner tidak valid → fallback DAG satu node
///   (tujuan dijalankan apa adanya), bukan rencana karangan. Store tim yang
///   korup dilompati, bukan menggagalkan runtime.
/// - **Bounded:** maksimum 12 node rencana, konsumsi turn per anggota tetap
///   dijaga `BudgetGuard` dan `maxTurns` anggota.
/// - **Jujur:** hasil menyimpan status per node (status TaskResult asli),
///   ulasan kritik bukan proklamasi sukses; ketika `verify_command` diset,
///   sukses akhir menuntut exit 0.
/// - **Teramati:** setiap tahap memancarkan event `team.*` (`EventBus`), dan
///   laporan run tersimpan di `data/teams/runs/`.

/// Tim tersimpan sebagai file JSON di `teams/<id>.json`: anggotanya adalah
/// [AgentSpec] penuh (persona, allowlist tool, tier model, budget turn)
/// sehingga satu format dipakai CLI, REST, dan tool.
class BotTeamDoc {
  const BotTeamDoc({
    required this.id,
    required this.name,
    this.description = '',
    required this.members,
  });

  final String id;
  final String name;
  final String description;
  final List<AgentSpec> members;

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool isValidId(String id) => idPattern.hasMatch(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'members': [for (final m in members) m.toJson()],
      };

  factory BotTeamDoc.fromJson(Map<String, dynamic> json) => BotTeamDoc(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? json['id'] as String? ?? '',
        description: json['description'] as String? ?? '',
        members: _parseMembers(json['members']),
      );

  static List<AgentSpec> _parseMembers(Object? raw) {
    if (raw is! List) return const [];
    final out = <AgentSpec>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final spec = AgentSpec.fromJson(Map<String, dynamic>.from(item));
      final persona = spec.systemPrompt.trim();
      // Anggota tanpa persona dianggap gagal jujur: persona adalah satu-satunya
      // pembeda perilaku antar anggota; null allowlist berarti tanpa tool.
      if (spec.id.trim().isEmpty || persona.isEmpty) continue;
      out.add(AgentSpec(
        id: spec.id.trim(),
        role: spec.role,
        systemPrompt: persona,
        toolAllowlist: spec.toolAllowlist,
        modelTier: spec.modelTier,
        maxTurns: spec.maxTurns,
      ));
    }
    return out;
  }
}

/// Store tim + laporan run, mengikuti pola [BotStore]: tulis atomik
/// (tmp → rename), file korup dilompati, jangan pernah gagalkan host.
class BotTeamStore {
  BotTeamStore({required String dataDir})
      : teamsDir = p.join(dataDir, 'teams');

  final String teamsDir;

  String get runsDir => p.join(teamsDir, 'runs');

  final Map<String, BotTeamDoc> _teams = {};

  Future<void> load() async {
    final dir = Directory(teamsDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final doc = BotTeamDoc.fromJson(json);
        if (doc.id.isEmpty || doc.members.isEmpty) {
          // Tim tanpa anggota tidak bisa jalan: abaikan, jangan crash.
          continue;
        }
        _teams[doc.id] = doc;
      } on FormatException {
        // Skip file korup; store harus tetap bisa jalan.
      }
    }
  }

  List<BotTeamDoc> list() =>
      _teams.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  BotTeamDoc? get(String id) => _teams[id];

  Future<BotTeamDoc> save(BotTeamDoc doc) async {
    _teams[doc.id] = doc;
    final dir = Directory(teamsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(p.join(teamsDir, '${doc.id}.json'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(doc.toJson()),
    );
    await tmp.rename(target.path);
    return doc;
  }

  Future<bool> delete(String id) async {
    final removed = _teams.remove(id) != null;
    final file = File(p.join(teamsDir, '$id.json'));
    if (await file.exists()) await file.delete();
    return removed;
  }

  /// Simpan laporan run ke `teams/runs/`. Nama file dihasilkan dari run id
  /// dan hal yang sama menjadi kunci baca balik.
  Future<String> saveRunReport(Map<String, dynamic> report) async {
    final dir = Directory(runsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = '${report['run_id']}';
    final target = File(p.join(runsDir, '$name.json'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    await tmp.rename(target.path);
    return target.path;
  }

  /// Laporan run terbaru dulu (nama file ber-stamp waktu menurun abjad).
  Future<List<Map<String, dynamic>>> listRunReports({int limit = 20}) async {
    final dir = Directory(runsDir);
    if (!await dir.exists()) return const [];
    final names = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        names.add(p.basenameWithoutExtension(entity.path));
      }
    }
    names.sort((a, b) => b.compareTo(a));
    final out = <Map<String, dynamic>>[];
    for (final name in names.take(limit.clamp(1, 200))) {
      final r = await readRunReport(name);
      if (r != null) out.add(r);
    }
    return out;
  }

  Future<Map<String, dynamic>?> readRunReport(String name) async {
    // Validasi nama: hanya komponen aman, tanpa traversal.
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$').hasMatch(name) ||
        name.contains('..')) {
      return null;
    }
    final file = File(p.join(runsDir, '$name.json'));
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }
}

/// Rencana DAG hasil dekomposisi planner (atau fallback).
class BotTeamPlan {
  const BotTeamPlan({required this.source, required this.tasks});

  /// 'planner' = hasil dekomposisi LLM yang tervalidasi; 'fallback' = satu
  /// node dengan tujuan apa adanya.
  final String source;
  final List<TaskNode> tasks;
}

/// Parse keluaran planner menjadi [BotTeamPlan]. Menerima JSON murni maupun
/// JSON dalam code fence. Fail-closed: balik null bila bentuk tidak valid
/// (id duplikat/kosong, prompt kosong, dependensi tak dikenal, siklus,
/// lebih dari [maxNodes] node); caller wajib pakai fallback saat null.
BotTeamPlan? parseBotTeamPlan(
  String raw, {
  required List<String> agentIds,
  int maxNodes = 12,
}) {
  var text = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*(.*?)```', dotAll: true);
  final m = fence.firstMatch(text);
  if (m != null) text = m.group(1)!.trim();
  // Ambil objek JSON pertama kalau planner menambahkan prose.
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
  final rawTasks = decoded['tasks'];
  if (rawTasks is! List || rawTasks.isEmpty || rawTasks.length > maxNodes) {
    return null;
  }
  final graph = TaskGraph();
  for (final raw in rawTasks) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    map['prompt'] = map['prompt'] ?? map['task'] ?? map['goal'];
    if (map['agent'] != null && map['agent_id'] == null) {
      map['agent_id'] = map.remove('agent');
    }
    final TaskNode node;
    try {
      node = TaskNode.fromJson(map);
    } on Exception {
      return null;
    }
    final prompt = node.prompt.trim();
    final id = node.id.trim();
    if (id.isEmpty || prompt.isEmpty) return null;
    final agentId = node.agentId?.trim();
    if (agentId != null && !agentIds.contains(agentId)) return null;
    try {
      graph.add(TaskNode(
        id: id,
        prompt: prompt,
        agentId: (agentId == null || agentId.isEmpty) ? null : agentId,
        dependsOn: [for (final d in node.dependsOn) d.trim()]
          ..removeWhere((d) => d.isEmpty),
      ));
    } on ArgumentError {
      return null;
    }
  }
  try {
    graph.waves();
  } on StateError {
    return null; // dependensi tak dikenal / siklus → fallback.
  }
  return BotTeamPlan(source: 'planner', tasks: graph.nodes);
}

/// Hasil satu node (dibungkus ulang agar tidak membocorkan tipe core di
/// kontrak publik runtime: JSON-only untuk CLI/REST/GUI).
class BotTeamNodeRecord {
  const BotTeamNodeRecord({
    required this.nodeId,
    required this.agentId,
    required this.ok,
    required this.output,
    this.error,
    this.durationMs = 0,
  });

  final String nodeId;
  final String agentId;
  final bool ok;
  final String output;
  final String? error;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'agent_id': agentId,
        'ok': ok,
        'output': output,
        if (error != null) 'error': error,
        'duration_ms': durationMs,
      };
}

/// Hasil run penuh; selalu serializable dan tidak pernah throw dari [run].
class BotTeamRunResult {
  const BotTeamRunResult({
    required this.runId,
    required this.goal,
    required this.success,
    required this.planSource,
    required this.plan,
    required this.nodeRecords,
    required this.synthesis,
    this.teamId,
    this.review,
    this.verifyOk,
    this.verifyExitCode,
    this.tokensUsed = 0,
    this.toolCallCount = 0,
  });

  final String runId;
  final String? teamId;
  final String goal;
  final bool success;
  final String planSource;
  final List<TaskNode> plan;
  final List<BotTeamNodeRecord> nodeRecords;
  final String synthesis;
  final String? review;

  /// Null = tanpa verifikasi; non-null = hasil exit code nyata (Fase B gate).
  final bool? verifyOk;
  final int? verifyExitCode;
  final int tokensUsed;
  final int toolCallCount;

  Map<String, dynamic> toJson() => {
        'run_id': runId,
        if (teamId != null) 'team_id': teamId,
        'goal': goal,
        'success': success,
        'plan_source': planSource,
        'plan': [
          for (final n in plan)
            {
              'id': n.id,
              'prompt': n.prompt,
              if (n.agentId != null) 'agent_id': n.agentId,
              'depends_on': n.dependsOn,
            },
        ],
        'nodes': [for (final r in nodeRecords) r.toJson()],
        'synthesis': synthesis,
        if (review != null) 'review': review,
        if (verifyOk != null) 'verify_ok': verifyOk,
        if (verifyExitCode != null) 'verify_exit_code': verifyExitCode,
        'tokens_used': tokensUsed,
        'tool_call_count': toolCallCount,
      };
}

/// Satu turn anggota (mis. closure ke `TikoRuntime.chatWithStatus`
/// dengan persona + toolFilter + budget anggota). [slot] adalah id node,
/// atau label khusus (`__plan`, `__synthesis`, `__review`, `__repair<i>`)
/// untuk turn non-node — dipakai pemanggil sebagai session id unik.
typedef BotTeamMemberTurn = Future<ChatRunResult> Function(
  AgentSpec agent,
  String slot,
  String prompt,
);

/// Dekomposisi tujuan → rencana (planner tanpa tool; teks JSON).
typedef BotTeamPlannerTurn = Future<ChatRunResult> Function(String prompt);

/// Runner orkestrasi Fase C. Murni (injected callbacks) → deterministik di
/// test, tanpa mengenal detail router/registry host.
class BotTeamRunner {
  BotTeamRunner({
    required this.members,
    required this.plannerTurn,
    required this.memberTurn,
    required this.workspacePath,
    this.critic,
    this.maxConcurrency = 4,
    this.maxOutputChars = 6000,
    this.emitEvent,
    this.onNodeEvent,
    this.sandbox,
  }) {
    if (maxConcurrency < 1 || maxConcurrency > 8) {
      throw ArgumentError('maxConcurrency harus 1..8');
    }
    if (members.all.isEmpty) {
      throw ArgumentError('Butuh minimal satu anggota tim');
    }
  }

  final AgentRegistry members;
  final BotTeamPlannerTurn plannerTurn;
  final BotTeamMemberTurn memberTurn;
  final String workspacePath;

  /// Anggota critic untuk tahap review (opsional).
  final AgentSpec? critic;

  final int maxConcurrency;
  final int maxOutputChars;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;
  final void Function(String nodeId, String agentId, bool starting)?
      onNodeEvent;
  final SandboxRunner? sandbox;

  void _emit(String type, Map<String, dynamic> data) =>
      emitEvent?.call(type, data);

  static String _plannerPrompt(String goal, List<AgentSpec> roster) {
    final rosterList = [
      for (final a in roster)
        '- ${a.id} (${a.role.name}): ${_oneLine(a.systemPrompt)}',
    ].join('\n');
    return '''
Pecah tujuan berikut menjadi DAG tugas untuk tim agent (${roster.length} anggota).
Balas HANYA JSON — tanpa penjelasan — dengan bentuk persis:
{"tasks":[{"id":"<pendek>","prompt":"<intruksi konkret>","agent":"<id anggota>","depends_on":["<id>"]}]}

Aturan: maksimum 12 tugas; prompt per tugas spesifik dan mandiri (agent tidak
melihat percakapan ini); agent WAJIB salah satu id di bawah; depends_on hanya
menunjuk id tugas; contractor kritis tergantung hasil tahap sebelumnya.

Tujuan:
$goal

Anggota tim:
$rosterList'''.trim();
  }

  static String _oneLine(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length <= 80 ? t : '${t.substring(0, 80)}…';
  }

  static const String _repairInstruction = '''
Perbaiki akar penyebab error di atas DI WORKSPACE (jangan cuma jelaskan).
Setelah jawabanmu, verifikasi objektif dijalankan lagi.''';

  /// Jalankan orkestra penuh. Tidak pernah throw — hasil final terstruktur
  /// dengan `success` jujur (semua node sukses DAN, bila verify diset,
  /// exit 0), kecuali bahaya terselubung: node gagal dicatat sebagai gagal.
  /// [runIdOverride] opsional dipakai host (Mission Control) supaya event
  /// live `team.*` bisa dirujuk balik ke registri yang sama; [cancelToken]
  /// opsional untuk pembatalan kooperatif antar-gelombang DAG.
  Future<BotTeamRunResult> run({
    required String goal,
    String? teamId,
    String? runIdOverride,
    CancellationToken? cancelToken,
    String? verifyCommand,
    int repairIterations = 1,
    Duration verifyTimeout = const Duration(seconds: 180),
    bool unsandboxedFallback = true,
  }) async {
    final goalTrim = goal.trim();
    assert(goalTrim.isNotEmpty, 'goal wajib');
    final runId = runIdOverride ??
        't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    var tokens = 0;
    var toolCalls = 0;

    // ── 1. Plan (bila tanpa planner, fallback satu node) ─────────────────
    BotTeamPlan plan;
    try {
      final planTurn = await plannerTurn(_plannerPrompt(goalTrim, members.all));
      tokens += planTurn.tokensUsed;
      toolCalls += planTurn.toolCallCount;
      plan = parseBotTeamPlan(planTurn.text, agentIds: [
        for (final a in members.all) a.id,
      ]) ??
          BotTeamPlan(
            source: 'fallback',
            tasks: [
              TaskNode(id: 'main', prompt: goalTrim),
            ],
          );
    } catch (_) {
      // Planner tidak boleh membunuh orkestra: jujur pakai fallback.
      plan = BotTeamPlan(
        source: 'fallback',
        tasks: [TaskNode(id: 'main', prompt: goalTrim)],
      );
    }
    final graph = TaskGraph();
    for (final n in plan.tasks) {
      graph.add(n);
    }
    _emit('team.planned', {
      'run_id': runId,
      'source': plan.source,
      'nodes': [for (final n in plan.tasks) n.id],
    });

    // ── 2. Execute DAG (wave paralel) ────────────────────────────────────
    final orchestrator = TeamOrchestrator(
      executor: (agent, node, blackboard) async {
        onNodeEvent?.call(node.id, agent.id, true);
        _emit('team.node_started', {
          'run_id': runId,
          'node': node.id,
          'agent': agent.id,
        });
        try {
          final turn = await memberTurn(agent, node.id, node.prompt);
          tokens += turn.tokensUsed;
          toolCalls += turn.toolCallCount;
          onNodeEvent?.call(node.id, agent.id, false);
          _emit('team.node_finished', {
            'run_id': runId,
            'node': node.id,
            'agent': agent.id,
            'ok': turn.success,
            // Tail output pendek — bahan Mission Control (live status node).
            'output': _eventTail(turn.text),
          });
          return turn.text;
        } catch (e) {
          _emit('team.node_finished', {
            'run_id': runId,
            'node': node.id,
            'agent': agent.id,
            'ok': false,
            'error': e.toString(),
          });
          rethrow;
        }
      },
      registry: members,
      maxConcurrency: maxConcurrency,
      defaultAgentId: members.all.first.id,
      synthesizer: _synthesizer,
    );

    final TeamRunResult teamRun;
    try {
      teamRun = await orchestrator.run(graph, goal: goalTrim);
    } catch (e) {
      return BotTeamRunResult(
        runId: runId,
        teamId: teamId,
        goal: goalTrim,
        success: false,
        planSource: plan.source,
        plan: plan.tasks,
        nodeRecords: const [],
        synthesis: cancelToken?.isCancelled == true
            ? 'Orkestra dibatalkan sebelum selesai.'
            : 'Orkestra gagal dijalankan: $e',
      );
    }

    final nodeRecords = [
      for (final r in teamRun.results)
        BotTeamNodeRecord(
          nodeId: r.taskId,
          agentId: r.agentId,
          ok: r.success,
          output: r.output,
          error: r.error,
          durationMs: r.durationMs,
        ),
    ];
    final allNodesOk = teamRun.allSucceeded;
    var synthesis = teamRun.synthesis;

    // Dibatalkan kooperatif: lompati review/verify — node tersisa memang
    // sudah dicatat gagal/cancel oleh orkestrator, tidak ada kerja lanjut.
    if (cancelToken?.isCancelled == true) {
      return BotTeamRunResult(
        runId: runId,
        teamId: teamId,
        goal: goalTrim,
        success: false,
        planSource: plan.source,
        plan: plan.tasks,
        nodeRecords: nodeRecords,
        synthesis: synthesis.isEmpty ? 'Run tim dibatalkan.' : synthesis,
      );
    }

    // ── 3. Review (critic) — advisory, bukan gate ────────────────────────
    String? review;
    final criticSpec = critic ?? _byRole(AgentRole.critic);
    if (criticSpec != null) {
      final failedList = [
        for (final r in nodeRecords.where((r) => !r.ok))
          '- ${r.nodeId} (${r.agentId}): ${r.error ?? 'tanpa output'}',
      ].join('\n');
      try {
        final reviewTurn = await memberTurn(
          criticSpec,
          '__review',
          '''
Review hasil tim untuk tujuan:
$goalTrim

--- sintesis ---
$synthesis
--- akhir sintesis ---

Tugas GAGAL:
${failedList.isEmpty ? '(tidak ada)' : failedList}

Sebut cacat, risiko, dan langkah yang BELUM terverifikasi. Ringkas.''',
        );
        tokens += reviewTurn.tokensUsed;
        toolCalls += reviewTurn.toolCallCount;
        review = reviewTurn.text.trim();
      } catch (e) {
        review = '(review critic gagal: $e — bukan gate, diabaikan)';
      }
      _emit('team.review_done', {'run_id': runId});
    }

    // ── 4. Verify objektif + perbaikan terbatas (mewarisi kontrak Fase B) ─
    bool? verifyOk;
    int? verifyExit;
    final verifyTrim = verifyCommand?.trim() ?? '';
    if (verifyTrim.isNotEmpty) {
      var outcome = await runVerification(
        verifyTrim,
        workspacePath: workspacePath,
        sandbox: sandbox,
        unsandboxedFallback: unsandboxedFallback,
        timeout: verifyTimeout,
      );
      verifyExit = outcome.exitCode;
      var attempts = 1;
      verifyOk = outcome.ok;
      final repairer = _byRole(AgentRole.coder) ?? members.all.first;
      for (var i = 1; !outcome.ok && i <= repairIterations.clamp(0, 3); i++) {
        final repair = await memberTurn(
          repairer,
          '__repair$i',
          '''
Verifikasi tim GAGAL (exit ${outcome.exitCode}); perintah:
  $verifyTrim

Task asli: $goalTrim

--- output verifikasi (tail) ---
${_tail(outcome.output)}
--- akhir output ---

$_repairInstruction''',
        );
        tokens += repair.tokensUsed;
        toolCalls += repair.toolCallCount;
        outcome = await runVerification(
          verifyTrim,
          workspacePath: workspacePath,
          sandbox: sandbox,
          unsandboxedFallback: unsandboxedFallback,
          timeout: verifyTimeout,
        );
        verifyExit = outcome.exitCode;
        attempts++;
        verifyOk = outcome.ok;
        _emit('team.verify', {
          'run_id': runId,
          'attempt': attempts,
          'ok': outcome.ok,
        });
      }
    }

    final success = allNodesOk && (verifyOk ?? true);
    return BotTeamRunResult(
      runId: runId,
      teamId: teamId,
      goal: goalTrim,
      success: success,
      planSource: plan.source,
      plan: plan.tasks,
      nodeRecords: nodeRecords,
      synthesis: synthesis,
      review: review,
      verifyOk: verifyOk,
      verifyExitCode: verifyExit,
      tokensUsed: tokens,
      toolCallCount: toolCalls,
    );
  }

  String _tail(String s) {
    if (s.length <= maxOutputChars) return s;
    return '${s.substring(s.length - maxOutputChars)}\n'
        '\u2026[tail terpotong ke $maxOutputChars karakter terakhir]';
  }

  /// Sanitasi tail output untuk event live: karakter kontrol dibuang,
  /// dibatasi 200 karakter terakhir (payload event tetap ringan).
  static String _eventTail(String s) {
    final clean =
        s.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), ' ').trim();
    return clean.length <= 200
        ? clean
        : '\u2026${clean.substring(clean.length - 200)}';
  }

  AgentSpec? _byRole(AgentRole role) => members.byRole(role);

  /// Sintesis: bila ada summarizer, satu turn rangkuman; kalau tidak,
  /// gabungan deterministik (bukan klaim model).
  Future<String> _synthesizer(String goal, List<TaskResult> results) async {
    final summarizer = _byRole(AgentRole.summarizer);
    final body = [
      for (final r in results)
        '[${r.taskId} via ${r.agentId}]\n'
            '${r.success ? r.output : 'GAGAL: ${r.error}'}',
    ].join('\n\n');
    if (summarizer == null) {
      return [
        if (goal.isNotEmpty) 'Tujuan: $goal',
        body,
      ].join('\n\n');
    }
    try {
      final turn = await memberTurn(
        summarizer,
        '__synthesis',
        '''
Gabungkan hasil anggota tim berikut menjadi jawaban akhir yang ringkas dan
jujur untuk tujuan: ${goal.isEmpty ? '(tanpa tujuan eksplisit)' : goal}

Team bertanda GAGAL harus tetap disebut gagal — jangan diklaim berhasil.

--- hasil ---
$body
--- akhir hasil ---''',
      );
      final text = turn.text.trim();
      if (text.isNotEmpty) return text;
    } catch (_) {
      // Sintesis LLM gagal → gabungan deterministik (jujur & tidak kosong).
    }
    return body;
  }

}

/// Fase C — integrasi orkestra ke [TikoRuntime]: satu panggilan API untuk
/// "capai tujuan X dengan tim bot". Session/channel khusus `team:` supaya
/// log turn tiap anggota terpisah rapi dari chat biasa; tool anggota
/// difilter per allowlist; budget per anggota tetap `BudgetGuard` host.
extension BotTeamWiring on TikoRuntime {
  /// Tool coding bawaan untuk turn perbaikan verifikasi (gate Fase B).
  static const Set<String> defaultCoderTools = {
    'read_file', 'list_dir', 'grep', 'write_file', 'patch_file',
    'verify_project', 'unzip_archive', 'datetime',
  };

  /// Roster efektif: tim tersimpan bila [saved] beranggota, selain itu
  /// roster bawaan ([AgentTeamTool.defaultRegistry]).
  List<AgentSpec> rosterFor(BotTeamDoc? saved) {
    if (saved != null && saved.members.isNotEmpty) return saved.members;
    return AgentTeamTool.defaultRegistry.all;
  }

  /// Orkestra tim: [teamId] menunjuk tim tersimpan (`tiko team save` /
  /// REST `/v1/teams`); null = tim bawaan (planner, researcher, coder,
  /// critic, summarizer). [verifyCommand] menyalakan gate objektif Fase B:
  /// sukses akhir menuntut exit 0, plus maksimal [repairIterations] turn
  /// perbaikan oleh anggota coder bila verifikasi gagal.
  Future<BotTeamRunResult> runBotTeam({
    required String goal,
    String? teamId,
    String? verifyCommand,
    int maxConcurrency = 4,
    int repairIterations = 1,
    Duration verifyTimeout = const Duration(seconds: 180),
    bool unsandboxedVerification = true,
    Set<String>? extraCoderTools,
    void Function(String nodeId, String agentId, bool starting)? onNodeEvent,
  }) async {
    final goalTrim = goal.trim();
    final runId =
        't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final cancelToken = CancellationToken();
    swarmControl.startRun(
      runId: runId,
      teamId: teamId ?? 'adhoc',
      goal: goalTrim,
    );
    final savedDoc = teamId == null ? null : botTeamStore.get(teamId);
    final roster = rosterFor(savedDoc);
    final registry = AgentRegistry();
    for (final spec in roster) {
      registry.register(spec);
    }
    final eco = resourceProfile == 'eco';

    Future<ChatRunResult> memberTurn(
      AgentSpec agent,
      String slot,
      String prompt,
    ) {
      final sessionId =
          'team:${teamId ?? 'adhoc'}:${agent.id}:'
          '${DateTime.now().microsecondsSinceEpoch}';
      swarmControl.trackSession(runId, sessionId);
      final allow = agent.toolAllowlist;
      final isRepair = slot.startsWith('__repair');
      final filter = isRepair
          ? {
              ...defaultCoderTools,
              if (extraCoderTools != null) ...extraCoderTools,
            }
          : allow == null
              // Tanpa allowlist eksplisit → tanpa tool (fail-closed, kontrak
              // sama dengan agent_team P2-2).
              ? const <String>{}
              : allow.isEmpty
                  ? null
                  : Set.of(allow);
      return chatWithStatus(
        prompt,
        sessionId: sessionId,
        channel: 'team',
        userKey: 'team',
        toolFilter: filter,
        configOverride: AgentConfig(
          maxIterations: agent.maxTurns,
          maxTokensPerTask: eco ? 20000 : config.maxTokensPerTask,
          maxWallClockSec: eco ? 120 : config.maxWallClockSec,
          maxToolCalls: eco ? 12 : config.maxToolCalls,
          preferredTier: modelTierToRouterTier(agent.modelTier),
        ),
        personaPrompt: agent.systemPrompt.isEmpty ? null : agent.systemPrompt,
      );
    }

    final plannerMember = roster.firstWhere(
      (a) => a.role == AgentRole.planner,
      orElse: () => roster.first,
    );
    final runner = BotTeamRunner(
      members: registry,
      plannerTurn: (prompt) {
        final sessionId =
            'team:${teamId ?? 'adhoc'}:__plan:'
            '${DateTime.now().microsecondsSinceEpoch}';
        swarmControl.trackSession(runId, sessionId);
        return chatWithStatus(
          prompt,
          sessionId: sessionId,
          channel: 'team',
          userKey: 'team',
          toolFilter: const <String>{},
          configOverride: AgentConfig(
            maxIterations: 4,
            maxTokensPerTask: eco ? 20000 : config.maxTokensPerTask,
            maxWallClockSec: eco ? 120 : config.maxWallClockSec,
            maxToolCalls: 0,
          ),
          personaPrompt:
              plannerMember.systemPrompt.isEmpty
                  ? null
                  : plannerMember.systemPrompt,
        );
      },
      memberTurn: memberTurn,
      workspacePath: workspace,
      maxConcurrency: maxConcurrency.clamp(1, 8).toInt(),
      emitEvent: (type, data) {
        events.emit(type, data);
        _feedSwarm(runId, type, data);
      },
      onNodeEvent: onNodeEvent,
      sandbox: SandboxRunner(kind: sandboxKind, workspacePath: workspace),
    );

    BotTeamRunResult result;
    try {
      result = await runner.run(
        goal: goal,
        teamId: teamId,
        runIdOverride: runId,
        cancelToken: cancelToken,
        verifyCommand: verifyCommand,
        repairIterations: repairIterations,
        verifyTimeout: verifyTimeout,
        unsandboxedFallback: unsandboxedVerification,
      );
    } catch (e) {
      swarmControl.runFinished(
        runId,
        success: false,
        cancelled: cancelToken.isCancelled,
      );
      rethrow;
    }
    swarmControl.runFinished(
      runId,
      success: result.success,
      cancelled: cancelToken.isCancelled,
    );
    events.emit('team.finished', {
      'run_id': result.runId,
      'team_id': result.teamId,
      'success': result.success,
      'nodes': result.nodeRecords.length,
    });
    try {
      // Laporan adalah data terbaik — kegagalan filesystem tidak boleh
      // menggagalkan hasil orkestra yang sudah selesai dihitung.
      await botTeamStore.saveRunReport(result.toJson());
    } catch (_) {} // best-effort
    return result;
  }

  /// Cermin event `team.*` ke registri Mission Control (best-effort; event
  /// dari runner selalu valid untuk run [runId] yang sedang berjalan).
  void _feedSwarm(
    String runId,
    String type,
    Map<String, dynamic> data,
  ) {
    switch (type) {
      case 'team.planned':
        final nodes = data['nodes'];
        swarmControl.setPlanned(
          runId: runId,
          nodeIds: nodes is List
              ? nodes.whereType<String>().toList(growable: false)
              : const <String>[],
        );
      case 'team.node_started':
        final node = data['node'];
        final agent = data['agent'];
        if (node is String && agent is String) {
          swarmControl.nodeStarted(runId, node, agent);
        }
      case 'team.node_finished':
        final node = data['node'];
        if (node is String) {
          swarmControl.nodeFinished(
            runId,
            node,
            ok: data['ok'] == true,
            error: data['error'] is String ? data['error'] as String : null,
            output: data['output'] is String ? data['output'] as String : null,
          );
        }
    }
  }
}
