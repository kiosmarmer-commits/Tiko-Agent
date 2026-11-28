import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Fase 48 — SOP templates (paritas paper MetaGPT): template Standard
/// Operating Procedure deterministik yang menyusun role + langkah + validasi
/// menjadi rencana kerja terstruktur; bisa dieksekusi lewat bot team
/// (callback) bila host menyediakannya.
///
/// Konvensi repo:
/// - Store lokal `<dataDir>/sop_templates.json` (atomic tmp+rename,
///   fail-open terhadap file korup); seed 2 template generik saat pertama.
/// - `run` tanpa `execute` hanya me-render rencana (tanpa LLM); `execute`
///   mendelegasikan ke callback team yang disediakan host.
/// - Never-raises.
class SopRole {
  const SopRole({required this.name, this.responsibility = ''});

  final String name;
  final String responsibility;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (responsibility.isNotEmpty) 'responsibility': responsibility,
      };

  static SopRole? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return SopRole(
      name: name.trim(),
      responsibility:
          raw['responsibility'] is String ? raw['responsibility'] as String : '',
    );
  }
}

class SopStep {
  const SopStep({
    required this.title,
    this.description = '',
    this.role = '',
    this.outputs = const [],
  });

  final String title;
  final String description;
  final String role;
  final List<String> outputs;

  Map<String, dynamic> toJson() => {
        'title': title,
        if (description.isNotEmpty) 'description': description,
        if (role.isNotEmpty) 'role': role,
        if (outputs.isNotEmpty) 'outputs': outputs,
      };

  static SopStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    if (title is! String || title.trim().isEmpty) return null;
    final outputs = raw['outputs'];
    return SopStep(
      title: title.trim(),
      description:
          raw['description'] is String ? raw['description'] as String : '',
      role: raw['role'] is String ? raw['role'] as String : '',
      outputs: outputs is List
          ? outputs.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
          : const [],
    );
  }
}

class SopTemplate {
  SopTemplate({
    required this.id,
    required this.name,
    this.description = '',
    required this.roles,
    required this.steps,
    required this.createdAt,
    required this.updatedAt,
  })  : assert(steps.length >= 1 && steps.length <= 32),
        assert(roles.length >= 1 && roles.length <= 8);

  final String id;
  final String name;
  final String description;
  final List<SopRole> roles;
  final List<SopStep> steps;
  final DateTime createdAt;
  final DateTime updatedAt;

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'roles': [for (final r in roles) r.toJson()],
        'steps': [for (final s in steps) s.toJson()],
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static SopTemplate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || !idPattern.hasMatch(id.trim())) return null;
    if (name is! String || name.trim().isEmpty) return null;
    final rolesRaw = raw['roles'];
    final stepsRaw = raw['steps'];
    final roles = <SopRole>[];
    if (rolesRaw is List) {
      for (final r in rolesRaw) {
        final role = SopRole.fromJson(r);
        if (role != null && roles.length < 8) roles.add(role);
      }
    }
    final steps = <SopStep>[];
    if (stepsRaw is List) {
      for (final s in stepsRaw) {
        final step = SopStep.fromJson(s);
        if (step != null && steps.length < 32) steps.add(step);
      }
    }
    if (roles.isEmpty || steps.isEmpty) return null;
    return SopTemplate(
      id: id.trim(),
      name: name.trim(),
      description:
          raw['description'] is String ? raw['description'] as String : '',
      roles: roles,
      steps: steps,
      createdAt: DateTime.tryParse('${raw['created_at'] ?? ''}') ??
          DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse('${raw['updated_at'] ?? ''}') ??
          DateTime.now().toUtc(),
    );
  }

  /// Render SOP menjadi rencana kerja Markdown deterministik dengan goal.
  String toMarkdown({required String goal}) {
    final buf = StringBuffer('# SOP: $name\n\n');
    if (description.isNotEmpty) buf.writeln('$description\n');
    buf.writeln('**Goal**: $goal\n');
    buf.writeln('## Peran');
    for (final r in roles) {
      buf.writeln('- **${r.name}**'
          '${r.responsibility.isEmpty ? '' : ' — ${r.responsibility}'}');
    }
    buf.writeln('\n## Langkah');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      buf.writeln('${i + 1}. **${s.title}**'
          '${s.role.isEmpty ? '' : ' (${s.role})'}');
      if (s.description.isNotEmpty) buf.writeln('   ${s.description}');
      if (s.outputs.isNotEmpty) {
        buf.writeln('   Output: ${s.outputs.join(', ')}');
      }
    }
    return buf.toString();
  }
}

class SopStore {
  SopStore({required this.path, this.maxTemplates = 64});

  final String path;
  final int maxTemplates;

  final Map<String, SopTemplate> templates = {};
  bool _loaded = false;

  static SopTemplate _seedBugfix() => SopTemplate(
        id: 'bugfix-delivery',
        name: 'Bugfix Delivery',
        description:
            'SOP generik perbaikan bug: repro → akar masalah → fix kecil → '
            'verifikasi → ringkasan.',
        roles: const [
          SopRole(
            name: 'investigator',
            responsibility: 'reproduksi bug dan temukan akar penyebab',
          ),
          SopRole(
            name: 'fixer',
            responsibility: 'setor perubahan minimal di workspace',
          ),
          SopRole(
            name: 'reviewer',
            responsibility: 'periksa fix tidak menyembunyikan gejala',
          ),
        ],
        steps: const [
          SopStep(
            title: 'Reproduksi & lokalize',
            description:
                'Kumpulkan bukti error, temukan file yang relevan di '
                'workspace.',
            role: 'investigator',
            outputs: ['lokasi akar masalah'],
          ),
          SopStep(
            title: 'Perbaikan minimal',
            description:
                'Setor fix terkecil yang benar; jangan sentuh kode tak '
                'relevan.',
            role: 'fixer',
            outputs: ['diff perubahan'],
          ),
          SopStep(
            title: 'Verifikasi & review',
            description:
                'Jalankan test/verify command; reviewer cek fix menyelesaikan '
                'akar masalah.',
            role: 'reviewer',
            outputs: ['hasil verifikasi'],
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

  static SopTemplate _seedFeature() => SopTemplate(
        id: 'feature-delivery',
        name: 'Feature Delivery',
        description:
            'SOP generik pengiriman fitur: spesifikasi → desain → '
            'implementasi → verifikasi → dokumentasi.',
        roles: const [
          SopRole(
            name: 'planner',
            responsibility: 'pecah fitur menjadi langkah terukur',
          ),
          SopRole(
            name: 'implementer',
            responsibility: 'setor implementasi di workspace',
          ),
          SopRole(
            name: 'verifier',
            responsibility: 'jalankan test dan pastikan kontrak',
          ),
        ],
        steps: const [
          SopStep(
            title: 'Spesifikasi',
            description: 'Definisikan perilaku, batas, dan kriteria lulus.',
            role: 'planner',
            outputs: ['kriteria lulus'],
          ),
          SopStep(
            title: 'Implementasi',
            description: 'Setor kode + test mengikuti gaya repo.',
            role: 'implementer',
            outputs: ['perubahan kode'],
          ),
          SopStep(
            title: 'Verifikasi & dokumentasi',
            description: 'Jalankan test; perbarui dokumentasi terkait.',
            role: 'verifier',
            outputs: ['bukti test', 'catatan docs'],
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map) return;
      final list = decoded['templates'];
      if (list is! List) return;
      for (final raw in list) {
        final t = SopTemplate.fromJson(raw);
        if (t != null) templates[t.id] = t;
      }
    } catch (_) {
      templates.clear();
    }
  }

  Future<void> save() async {
    try {
      final list = templates.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      while (list.length > maxTemplates) {
        final evict = list.removeAt(0);
        templates.remove(evict.id);
      }
      final f = File(path);
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'templates': [for (final t in list) t.toJson()],
      }));
      await tmp.rename(f.path);
    } catch (_) {
      // fail-open
    }
  }

  /// Seed template generik hanya bila store kosong (pertama kali).
  Future<void> ensureSeeded() async {
    await load();
    if (templates.isNotEmpty) return;
    for (final t in [_seedBugfix(), _seedFeature()]) {
      templates[t.id] = t;
    }
    await save();
  }
}

/// Callback eksekusi SOP via bot team (host menyuntikkan; LLM-heavy).
typedef SopRunTeam = Future<Map<String, dynamic>> Function(
  String goal,
  String sopMarkdown,
);

/// Tool `sop` — kelola & jalankan template SOP (risk medium; `execute`
/// mendelegasikan ke bot team bila callback tersedia, selain itu render
/// rencana deterministik tanpa LLM).
class SopTool implements Tool {
  SopTool({required this.store, this.runTeam});

  final SopStore store;

  /// Eksekusi via bot team (mis. `rt.runBotTeam`); null → execute ditolak.
  final SopRunTeam? runTeam;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'sop',
        description:
            'Template SOP (MetaGPT-style): daftar/tampilkan/buat/hapus '
            'template prosedur, atau render rencana kerja peran+langkah '
            'dari sebuah goal; execute opsional via bot team.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'show', 'create', 'delete', 'run'],
            },
            'id': {'type': 'string', 'description': 'Id template.'},
            'template': {
              'type': 'string',
              'description':
                  'JSON template untuk create (id/name/roles/steps).',
            },
            'goal': {
              'type': 'string',
              'description': 'Goal untuk action run.',
            },
            'execute': {
              'type': 'boolean',
              'description':
                  'Run dengan eksekusi bot team (default false — hanya '
                  'rencana).',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 300,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    await store.ensureSeeded();
    final action = '${args['action'] ?? ''}'.trim();
    switch (action) {
      case 'list':
        final ids = store.templates.keys.toList()..sort();
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert({
            'count': ids.length,
            'templates': [
              for (final id in ids)
                {
                  'id': id,
                  'name': store.templates[id]!.name,
                  'steps': store.templates[id]!.steps.length,
                },
            ],
          }),
        );
      case 'show':
        final t = store.templates['${args['id'] ?? ''}'.trim()];
        if (t == null) {
          return const ToolResult(
            callId: '',
            content: 'template tidak ditemukan.',
            isError: true,
          );
        }
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert(t.toJson()),
        );
      case 'create':
        final raw = '${args['template'] ?? ''}'.trim();
        if (raw.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'argumen `template` (JSON) wajib untuk create.',
            isError: true,
          );
        }
        SopTemplate? parsed;
        try {
          final decoded = jsonDecode(raw);
          parsed = SopTemplate.fromJson(decoded);
        } on FormatException {
          parsed = null;
        }
        if (parsed == null) {
          return const ToolResult(
            callId: '',
            content: 'template tidak valid (id pattern, roles 1-8, steps '
                '1-32 wajib).',
            isError: true,
          );
        }
        store.templates[parsed.id] = parsed;
        await store.save();
        return ToolResult(callId: '', content: 'SOP "${parsed.id}" disimpan.');
      case 'delete':
        final id = '${args['id'] ?? ''}'.trim();
        final removed = store.templates.remove(id) != null;
        if (removed) await store.save();
        return ToolResult(
          callId: '',
          content: removed ? 'SOP "$id" dihapus.' : 'template tidak ditemukan.',
          isError: !removed,
        );
      case 'run':
        final id = '${args['id'] ?? ''}'.trim();
        final t = store.templates[id];
        if (t == null) {
          return const ToolResult(
            callId: '',
            content: 'template tidak ditemukan.',
            isError: true,
          );
        }
        final goal = '${args['goal'] ?? ''}'.trim();
        if (goal.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'argumen `goal` wajib untuk run.',
            isError: true,
          );
        }
        final plan = t.toMarkdown(goal: goal);
        if (args['execute'] != true) {
          return ToolResult(callId: '', content: plan);
        }
        final team = runTeam;
        if (team == null) {
          return ToolResult(
            callId: '',
            content: 'Eksekusi bot team tidak tersedia di host ini.\n\n$plan',
          );
        }
        try {
          final result = await team(goal, plan);
          return ToolResult(
            callId: '',
            content:
                '${const JsonEncoder.withIndent('  ').convert(result)}\n\n$plan',
          );
        } catch (e) {
          return ToolResult(
            callId: '',
            content: 'Eksekusi bot team gagal: $e\n\n$plan',
            isError: true,
          );
        }
      default:
        return const ToolResult(
          callId: '',
          content: 'action tidak dikenal (list|show|create|delete|run).',
          isError: true,
        );
    }
  }
}
