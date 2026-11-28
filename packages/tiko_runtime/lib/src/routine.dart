import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Fase 38 — Routines (paritas Grok Bot "observe → retain → rerun"): langkah
/// tool-call yang sukses direkam menjadi resep deterministik yang bisa
/// dijalankan ulang tanpa LLM.
///
/// Konvensi repo:
/// - Deterministik: replay menjalankan langkah persis seperti terekam,
///   fail-fast pada langkah pertama yang error (kecuali `continueOnError`).
/// - Never-raises: setiap operasi mengembalikan laporan/error jujur.
/// - Data lokal: resep disimpan di `<dataDir>/routines/<id>.json` (atomic
///   tmp+rename), tanpa konten keluar.
class RoutineStep {
  RoutineStep({required this.tool, required this.args, this.argsHash = ''});

  final String tool;
  final Map<String, dynamic> args;
  final String argsHash;

  Map<String, dynamic> toJson() =>
      {'tool': tool, 'args': args, if (argsHash.isNotEmpty) 'args_hash': argsHash};

  static RoutineStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tool = raw['tool'];
    if (tool is! String || tool.trim().isEmpty) return null;
    final args = raw['args'];
    return RoutineStep(
      tool: tool.trim(),
      args: args is Map ? Map<String, dynamic>.from(args) : const {},
      argsHash: raw['args_hash'] is String ? raw['args_hash'] as String : '',
    );
  }
}

class RoutineRecipe {
  RoutineRecipe({
    required this.id,
    required this.name,
    required this.steps,
    required this.createdAt,
    required this.updatedAt,
    this.runCount = 0,
    this.lastRunAt,
    this.lastStatus = '',
  });

  final String id;
  final String name;
  final List<RoutineStep> steps;
  final DateTime createdAt;
  final DateTime updatedAt;
  int runCount;
  DateTime? lastRunAt;
  String lastStatus;

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  bool get isValidId => idPattern.hasMatch(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'run_count': runCount,
        if (lastRunAt != null) 'last_run_at': lastRunAt!.toIso8601String(),
        'last_status': lastStatus,
      };

  static RoutineRecipe? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final rawSteps = json['steps'];
    if (id is! String || name is! String || rawSteps is! List) return null;
    final steps = <RoutineStep>[];
    for (final raw in rawSteps) {
      final step = RoutineStep.fromJson(raw);
      if (step != null) steps.add(step);
    }
    if (steps.isEmpty) return null;
    return RoutineRecipe(
      id: id,
      name: name,
      steps: steps,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      runCount: json['run_count'] is int ? json['run_count'] as int : 0,
      lastRunAt: json['last_run_at'] is String
          ? DateTime.tryParse(json['last_run_at'] as String)?.toUtc()
          : null,
      lastStatus: json['last_status'] is String ? json['last_status'] as String : '',
    );
  }
}

class RoutineRunStepReport {
  RoutineRunStepReport({
    required this.index,
    required this.tool,
    required this.ok,
    this.error = '',
  });

  final int index;
  final String tool;
  final bool ok;
  final String error;

  Map<String, dynamic> toJson() => {
        'index': index,
        'tool': tool,
        'ok': ok,
        if (error.isNotEmpty) 'error': error,
      };
}

class RoutineRunReport {
  RoutineRunReport({
    required this.recipeId,
    required this.total,
    required this.ok,
    required this.executed,
    required this.steps,
    required this.dryRun,
    this.error = '',
  });

  final String recipeId;
  final int total;
  final bool ok;
  final int executed;
  final List<RoutineRunStepReport> steps;
  final bool dryRun;
  final String error;

  Map<String, dynamic> toJson() => {
        'recipe_id': recipeId,
        'total': total,
        'ok': ok,
        'executed': executed,
        'dry_run': dryRun,
        if (error.isNotEmpty) 'error': error,
        'steps': steps.map((s) => s.toJson()).toList(),
      };
}

/// Penyimpanan resep routine di `<dataDir>/routines/`. Fail-open terhadap
/// file korup: file tidak valid dilewati, store tetap hidup.
class RoutineStore {
  RoutineStore({required String dataDir})
      : routinesDir = p.join(dataDir, 'routines');

  final String routinesDir;
  final Map<String, RoutineRecipe> _recipes = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final dir = Directory(routinesDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final recipe = RoutineRecipe.fromJson(json);
        if (recipe != null && recipe.isValidId) _recipes[recipe.id] = recipe;
      } on FormatException {
        // Skip file korup; jangan gagalkan seluruh store.
      }
    }
  }

  List<RoutineRecipe> list() =>
      _recipes.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  RoutineRecipe? get(String id) => _recipes[id];

  bool exists(String id) => _recipes.containsKey(id);

  Future<RoutineRecipe> save(RoutineRecipe recipe) async {
    _recipes[recipe.id] = recipe;
    await _write(recipe);
    return recipe;
  }

  Future<bool> delete(String id) async {
    if (_recipes.remove(id) == null) return false;
    final file = File(p.join(routinesDir, '$id.json'));
    if (await file.exists()) await file.delete();
    return true;
  }

  Future<void> _write(RoutineRecipe recipe) async {
    final dir = Directory(routinesDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(p.join(routinesDir, '${recipe.id}.json'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(recipe.toJson()),
    );
    await tmp.rename(target.path);
  }
}

/// Perekam langkah tool-call sukses per sesi. Hanya langkah dengan
/// `isError == false` yang terekam — resep selalu terverifikasi sukses.
class RoutineRecorder {
  RoutineRecorder({this.maxSteps = 64, this.maxArgsChars = 2000});

  final int maxSteps;
  final int maxArgsChars;

  final Map<String, List<RoutineStep>> _buffers = {};

  bool isRecording(String sessionId) => _buffers.containsKey(sessionId);

  Set<String> get recordingSessions => Set.unmodifiable(_buffers.keys);

  /// Mulai merekam untuk [sessionId]. Return false bila sudah merekam.
  bool start(String sessionId) {
    if (_buffers.containsKey(sessionId)) return false;
    _buffers[sessionId] = <RoutineStep>[];
    return true;
  }

  /// Rekam satu langkah. Diabaikan bila tidak sedang merekam atau resep
  /// sudah penuh (cap [maxSteps] — resep panjang tidak aman direplay).
  void record(String sessionId, String tool, Map<String, dynamic> args,
      {required bool isError}) {
    final buffer = _buffers[sessionId];
    if (buffer == null || isError || buffer.length >= maxSteps) return;
    final clamped = _clampArgs(args);
    buffer.add(RoutineStep(tool: tool, args: clamped));
  }

  /// Hentikan rekaman; mengembalikan langkah terekam (kosong bila tak ada).
  List<RoutineStep> stop(String sessionId) {
    final buffer = _buffers.remove(sessionId);
    return buffer == null ? const [] : List.unmodifiable(buffer);
  }

  Map<String, dynamic> _clampArgs(Map<String, dynamic> args) {
    final out = <String, dynamic>{};
    for (final entry in args.entries) {
      final value = entry.value;
      if (value is String && value.length > maxArgsChars) {
        out[entry.key] = value.substring(0, maxArgsChars);
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }
}

/// Runner replay resep: menjalankan langkah secara berurutan melalui
/// executor yang diinjeksi (deterministik dalam test), fail-fast default.
class RoutineRunner {
  RoutineRunner({
    required this.store,
    required this.executeStep,
    this.maxSteps = 64,
    this.emitEvent,
  });

  final RoutineStore store;
  final Future<ToolResult> Function(RoutineStep step, ToolContext ctx)
      executeStep;
  final int maxSteps;
  final void Function(String event, Map<String, dynamic> payload)? emitEvent;

  Future<RoutineRunReport> run(
    String recipeId, {
    required ToolContext ctx,
    bool dryRun = false,
    bool continueOnError = false,
  }) async {
    final recipe = store.get(recipeId);
    if (recipe == null) {
      return RoutineRunReport(
        recipeId: recipeId,
        total: 0,
        ok: false,
        executed: 0,
        steps: const [],
        dryRun: dryRun,
        error: 'routine "$recipeId" tidak dikenal',
      );
    }
    if (recipe.steps.length > maxSteps) {
      return RoutineRunReport(
        recipeId: recipeId,
        total: recipe.steps.length,
        ok: false,
        executed: 0,
        steps: const [],
        dryRun: dryRun,
        error:
            'resep memiliki ${recipe.steps.length} langkah, melebihi cap $maxSteps',
      );
    }
    final reports = <RoutineRunStepReport>[];
    var executed = 0;
    var ok = true;
    var failure = '';
    for (var i = 0; i < recipe.steps.length; i++) {
      final step = recipe.steps[i];
      if (dryRun) {
        reports.add(RoutineRunStepReport(index: i, tool: step.tool, ok: true));
        continue;
      }
      try {
        final result = await executeStep(step, ctx);
        executed++;
        final stepOk = !result.isError;
        reports.add(RoutineRunStepReport(
          index: i,
          tool: step.tool,
          ok: stepOk,
          error: stepOk ? '' : _clip(result.content),
        ));
        if (!stepOk) {
          ok = false;
          failure = 'langkah $i (${step.tool}) gagal: ${_clip(result.content)}';
          if (!continueOnError) break;
        }
      } catch (e) {
        executed++;
        ok = false;
        reports.add(RoutineRunStepReport(
          index: i,
          tool: step.tool,
          ok: false,
          error: _clip('$e'),
        ));
        failure = 'langkah $i (${step.tool}) melempar error: ${_clip('$e')}';
        if (!continueOnError) break;
      }
    }
    final status = dryRun
        ? 'dry_run'
        : (ok ? 'ok' : 'failed');
    if (!dryRun) {
      recipe
        ..runCount += 1
        ..lastRunAt = DateTime.now().toUtc()
        ..lastStatus = status;
      try {
        await store.save(recipe);
      } catch (_) {
        // Persist best-effort; laporan run tetap dikembalikan.
      }
    }
    emitEvent?.call('routine.run', {
      'recipe': recipeId,
      'status': status,
      'executed': executed,
      'total': recipe.steps.length,
    });
    return RoutineRunReport(
      recipeId: recipeId,
      total: recipe.steps.length,
      ok: ok,
      executed: executed,
      steps: reports,
      dryRun: dryRun,
      error: failure,
    );
  }

  static String _clip(String text) =>
      text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

/// Tool `routine` — manajemen resep: record_start/record_stop/list/show/
/// run/delete. Risiko high karena replay mengeksekusi tool nyata.
class RoutineTool implements Tool {
  RoutineTool({
    required this.store,
    required this.recorder,
    required this.runner,
  });

  final RoutineStore store;
  final RoutineRecorder recorder;
  final RoutineRunner runner;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'routine',
        description:
            'Kelola routine: rekam langkah tool-call sukses menjadi resep '
            'deterministik lalu jalankan ulang tanpa LLM. Actions: list, '
            'show, record_start, record_stop, run, delete.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'list',
                'show',
                'record_start',
                'record_stop',
                'run',
                'delete',
              ],
            },
            'session': {
              'type': 'string',
              'description': 'Id sesi sasaran untuk record_start/record_stop.',
            },
            'name': {
              'type': 'string',
              'description': 'Nama/id routine (record_stop, show, run, delete).',
            },
            'dry_run': {
              'type': 'boolean',
              'description': 'Tampilkan langkah tanpa mengeksekusi (run).',
            },
            'continue_on_error': {
              'type': 'boolean',
              'description': 'Lanjut ke langkah berikutnya saat langkah gagal.',
            },
          },
          'required': ['action'],
        },
        risk: 'high',
        timeoutSec: 300,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final session = (args['session'] as String?)?.trim() ?? '';
    final name = (args['name'] as String?)?.trim().toLowerCase() ?? '';
    try {
      switch (action) {
        case 'list':
          await store.load();
          final recipes = store.list();
          if (recipes.isEmpty) return const ToolResult(callId: '', content: 'Belum ada routine.');
          final buf = StringBuffer();
          for (final r in recipes) {
            buf.writeln(
                '- ${r.id} — ${r.steps.length} langkah, dijalankan ${r.runCount}x, status terakhir: ${r.lastStatus.isEmpty ? '-' : r.lastStatus}');
          }
          return ToolResult(callId: '', content: buf.toString().trim());

        case 'show':
          if (name.isEmpty) {
            return const ToolResult(
                callId: '', content: 'name wajib untuk action show.', isError: true);
          }
          final recipe = store.get(name);
          if (recipe == null) {
            return ToolResult(
                callId: '', content: 'Routine "$name" tidak dikenal.', isError: true);
          }
          return ToolResult(
            callId: '',
            content: const JsonEncoder.withIndent('  ').convert(recipe.toJson()),
          );

        case 'record_start':
          if (session.isEmpty) {
            return const ToolResult(
                callId: '', content: 'session wajib untuk record_start.', isError: true);
          }
          final started = recorder.start(session);
          return ToolResult(
            callId: '',
            content: started
                ? 'Rekaman routine dimulai untuk sesi "$session". '
                    'Panggil record_stop dengan name untuk menyimpan.'
                : 'Sesi "$session" sudah sedang merekam.',
            isError: !started,
          );

        case 'record_stop':
          if (session.isEmpty || name.isEmpty) {
            return const ToolResult(
                callId: '',
                content: 'session dan name wajib untuk record_stop.',
                isError: true);
          }
          if (!RoutineRecipe.idPattern.hasMatch(name)) {
            return const ToolResult(
                callId: '',
                content:
                    'name tidak valid: gunakan [a-z0-9][a-z0-9_-]{0,63}.',
                isError: true);
          }
          final steps = recorder.stop(session);
          if (steps.isEmpty) {
            return ToolResult(
              callId: '',
              content: recorder.isRecording(session)
                  ? 'Rekaman berlanjut.'
                  : 'Tidak ada rekaman aktif untuk sesi "$session" atau tidak '
                      'ada langkah sukses terekam.',
              isError: true,
            );
          }
          final now = DateTime.now().toUtc();
          final existing = store.get(name);
          final recipe = RoutineRecipe(
            id: name,
            name: existing?.name ?? name,
            steps: List.of(steps),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            runCount: existing?.runCount ?? 0,
            lastRunAt: existing?.lastRunAt,
            lastStatus: existing?.lastStatus ?? '',
          );
          await store.save(recipe);
          return ToolResult(
            callId: '',
            content: 'Routine "$name" disimpan: ${steps.length} langkah. '
                'Jalankan dengan action=run.',
          );

        case 'run':
          if (name.isEmpty) {
            return const ToolResult(
                callId: '', content: 'name wajib untuk action run.', isError: true);
          }
          final report = await runner.run(
            name,
            ctx: ctx,
            dryRun: args['dry_run'] is bool ? args['dry_run'] as bool : false,
            continueOnError: args['continue_on_error'] is bool
                ? args['continue_on_error'] as bool
                : false,
          );
          return ToolResult(
            callId: '',
            content:
                const JsonEncoder.withIndent('  ').convert(report.toJson()),
            isError: !report.ok,
          );

        case 'delete':
          if (name.isEmpty) {
            return const ToolResult(
                callId: '', content: 'name wajib untuk action delete.', isError: true);
          }
          final deleted = await store.delete(name);
          return ToolResult(
            callId: '',
            content: deleted
                ? 'Routine "$name" dihapus.'
                : 'Routine "$name" tidak dikenal.',
            isError: !deleted,
          );

        default:
          return const ToolResult(
            callId: '',
            content:
                'action tidak dikenal. Gunakan: list, show, record_start, '
                'record_stop, run, delete.',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'routine gagal: $e',
        isError: true,
      );
    }
  }
}
