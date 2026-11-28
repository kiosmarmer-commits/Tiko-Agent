/// Fase 37 — LATM maker/user tool-generation pipeline (audit 2026-11-28
/// §6 #16: "ToolForge menghasilkan typed tool dengan contract tests dan
/// sandbox; belum full separate maker/user tool-generation pipeline").
///
/// Pemisahan peran LATM yang diadopsi (bukan replikasi penuh: tanpa caching
/// lintas-instance dan tanpa server functions terdistribusi):
///
/// 1. **Maker** — LLM auxiliar terpisah (strong model) menerjemahkan task
///    menjadi `ForgedToolDef` (nama ber-namespace `made_`, command sandbox,
///    contract tests). Turn maker TANPA tool dan TANPA akses workspace —
///    murni menghasilkan definisi.
/// 2. **Validator** — contract tests dijalankan oleh [ToolForge] yang sudah
///    ada (fail-closed: tanpa sandbox, tidak ada instalasi) — pola reuse,
///    bukan duplikasi jalur verifikasi NEW-12.
/// 3. **User** — agent utama memakai tool hasil instalasi lewat registry
///    biasa; permission gate tetap berlaku (risk `high` dari `ForgedTool`).
///
/// Prinsip kontrak: never-raises terhadap caller, fail-closed (def tidak
/// valid / uji gagal / nama bentrok → tidak ada instalasi), event telemetry
/// bebas-konten. Default off (panggilan LLM + eksekusi sandbox).

import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';

/// Laporan pembuatan tool oleh maker; serializable dan jujur.
class ToolMakerReport {
  const ToolMakerReport({
    required this.ok,
    required this.task,
    this.toolName,
    this.testsRun = 0,
    this.error,
    this.reason,
  });

  final bool ok;
  final String task;
  final String? toolName;
  final int testsRun;

  /// Detail kegagalan (parse/validation/contract tests).
  final String? error;

  /// 'installed' saat sukses; selain itu penanda tahap gagal.
  final String? reason;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'task': task,
        if (toolName != null) 'tool_name': toolName,
        'tests_run': testsRun,
        if (error != null) 'error': error,
        'reason': reason,
      };
}

/// Turn maker (LLM auxiliar) — host menyuntikkan; teks balasan diparse
/// menjadi `ForgedToolDef`.
typedef ToolMakerTurn = Future<String?> Function(String prompt);

/// Pipeline maker/validator/installer. Murni (callbacks injected).
class ToolMakerPipeline {
  ToolMakerPipeline({
    required this.forge,
    required this.makerTurn,
    required this.hasTool,
    required this.registerTool,
    this.maxTests = 8,
    this.maxCommandParts = 12,
    this.emitEvent,
  })  : assert(maxTests >= 1 && maxTests <= 16),
        assert(maxCommandParts >= 2 && maxCommandParts <= 32);

  final ToolForge forge;
  final ToolMakerTurn makerTurn;
  final bool Function(String name) hasTool;
  final void Function(Tool tool) registerTool;
  final int maxTests;
  final int maxCommandParts;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;

  static final RegExp _namePattern = RegExp(r'^made_[a-z0-9_]{1,40}$');

  String _prompt(String task, String? nameHint, List<String> existing) {
    final ns = existing.isEmpty
        ? '(belum ada tool made_)'
        : existing.map((e) => '- $e').join('\n');
    return '''
Kamu adalah TOOL MAKER. Tugas: mendesain SATU tool reusable (command-line,
dijalankan di sandbox) untuk kelas task berikut, agar agent lain bisa
memakainya berulang kali. Balas HANYA JSON — tanpa penjelasan — bentuk persis:
{"name":"made_<nama_snake_case>","description":"<maks 300 char>","command":["<exe>","<arg>",...],"tests":[{"input":{...},"expect_contains":"<string opsional>"}]}

Aturan:
- name HARUS diawali made_ dan hanya [a-z0-9_], maks 41 karakter.
- command: executable + argumen (maks $maxCommandParts bagian); argumen tool
  dikirim sebagai SATU JSON di argumen TERAKHIR.
- tests: WAJIB 2-$maxTests uji kontrak dengan input representatif; tambahkan
  expect_contains bila keluaran deterministik.
- Tool harus stateless dan aman dijalankan di sandbox (tanpa jaringan bila
  tidak perlu).

Task yang dilingkup:
$task

Tool made_ yang sudah ada:
$ns
${nameHint == null || nameHint.isEmpty ? '' : '\nSaran nama (boleh ditolak jika melanggar aturan): $nameHint'}''';
  }

  /// Parse balasan maker menjadi def; null bila tidak valid.
  ForgedToolDef? parseMakerDef(String raw) {
    var text = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*(.*?)```', dotAll: true);
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1))
          as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final name = '${decoded['name'] ?? ''}'.trim();
    final description = '${decoded['description'] ?? ''}'.trim();
    final command = decoded['command'];
    final tests = decoded['tests'];
    if (!_namePattern.hasMatch(name)) return null;
    if (description.isEmpty || description.length > 300) return null;
    if (command is! List || command.isEmpty) return null;
    final parts = [
      for (final c in command) '$c'.trim(),
    ]..removeWhere((c) => c.isEmpty);
    if (parts.isEmpty || parts.length > maxCommandParts) return null;
    if (tests is! List || tests.isEmpty || tests.length > maxTests) {
      return null;
    }
    final parsed = <ForgeTest>[];
    for (final t in tests) {
      if (t is! Map) return null;
      final input = t['input'];
      if (input is! Map) return null;
      final expect = t['expect_contains'];
      parsed.add(ForgeTest(
        input: Map<String, dynamic>.from(input),
        expectContains: expect is String && expect.isNotEmpty ? expect : null,
      ));
    }
    return ForgedToolDef(
      name: name,
      description: description,
      command: parts,
      tests: parsed,
    );
  }

  /// Jalankan pipeline penuh. Tidak pernah throw; kegagalan apa pun →
  /// report `ok: false` dengan alasan tahap.
  Future<ToolMakerReport> make({
    required String task,
    String? nameHint,
  }) async {
    final taskTrim = task.trim();
    assert(taskTrim.isNotEmpty, 'task wajib');
    String? raw;
    try {
      raw = await makerTurn(_prompt(taskTrim, nameHint, forge.installed));
    } catch (e) {
      return ToolMakerReport(
        ok: false,
        task: taskTrim,
        error: 'maker turn gagal: $e',
        reason: 'maker',
      );
    }
    if (raw == null || raw.trim().isEmpty) {
      return ToolMakerReport(
        ok: false,
        task: taskTrim,
        error: 'maker tidak menghasilkan balasan',
        reason: 'maker',
      );
    }
    final def = parseMakerDef(raw);
    if (def == null) {
      return ToolMakerReport(
        ok: false,
        task: taskTrim,
        error: 'definisi maker tidak valid (nama/description/command/tests)',
        reason: 'validate',
      );
    }
    if (hasTool(def.name)) {
      return ToolMakerReport(
        ok: false,
        task: taskTrim,
        toolName: def.name,
        error: 'nama tool sudah terpakai',
        reason: 'validate',
      );
    }
    final failure = await forge.runContractTests(def);
    if (failure != null) {
      emitEvent?.call('tool_maker.rejected', {
        'tool': def.name,
        'stage': 'contract_tests',
      });
      return ToolMakerReport(
        ok: false,
        task: taskTrim,
        toolName: def.name,
        testsRun: def.tests.length,
        error: failure,
        reason: 'contract_tests',
      );
    }
    forge.markInstalled(def);
    registerTool(ForgedTool(def: def, forge: forge));
    emitEvent?.call('tool_maker.installed', {
      'tool': def.name,
      'tests': def.tests.length,
    });
    return ToolMakerReport(
      ok: true,
      task: taskTrim,
      toolName: def.name,
      testsRun: def.tests.length,
      reason: 'installed',
    );
  }
}

/// Tool `tool_maker` — pemicu pipeline LATM: maker LLM mendesain tool
/// reusable, contract tests memvalidasi di sandbox, tool terpasang untuk
/// dipakai agent (user). Hanya terdaftar bila config `tool_maker.enabled`
/// DAN ada LLM auxiliar (fail-closed).
class ToolMakerTool implements Tool {
  ToolMakerTool({required this.pipeline});

  final ToolMakerPipeline pipeline;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'tool_maker',
        description:
            'Delegasikan pembuatan tool reusable ke tool maker: task yang '
            'didesain menjadi tool command-line tervalidasi contract tests, '
            'lalu terpasang untuk dipakai berulang. Gunakan untuk tugas '
            'berulang yang butuh tool khusus; bukan sekali pakai.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'task': {
              'type': 'string',
              'description': 'Deskripsi kelas task yang perlu tool.',
            },
            'name_hint': {
              'type': 'string',
              'description': 'Saran nama tool (opsional).',
            },
          },
          'required': ['task'],
        },
        risk: 'high',
        timeoutSec: 300,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final task = (args['task'] as String?)?.trim() ?? '';
    if (task.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'task wajib: kelas task yang perlu tool reusable.',
        isError: true,
      );
    }
    try {
      final report = await pipeline.make(
        task: task,
        nameHint: (args['name_hint'] as String?)?.trim(),
      );
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ').convert(report.toJson()),
        isError: !report.ok,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'tool_maker gagal dijalankan: $e',
        isError: true,
      );
    }
  }
}
