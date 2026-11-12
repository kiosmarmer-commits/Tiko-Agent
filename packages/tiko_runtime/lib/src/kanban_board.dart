import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';

import 'cross_process_lock.dart';

/// Kanban states for durable multi-process task dispatch.
enum KanbanState { backlog, doing, done, failed }

KanbanState _parseState(String s) => KanbanState.values.firstWhere(
      (v) => v.name == s,
      orElse: () => KanbanState.backlog,
    );

/// A durable task card on the [KanbanBoard].
class KanbanTask {
  const KanbanTask({
    required this.id,
    required this.title,
    required this.state,
    required this.createdBy,
    required this.updatedAt,
    this.claimedBy = '',
    this.result = '',
  });

  final String id;
  final String title;
  final KanbanState state;
  final String createdBy;
  final String claimedBy;
  final DateTime updatedAt;
  final String result;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'state': state.name,
        'created_by': createdBy,
        'claimed_by': claimedBy,
        'updated_at': updatedAt.toIso8601String(),
        'result': result,
      };

  static KanbanTask fromJson(Map<String, dynamic> json) => KanbanTask(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        state: _parseState(json['state']?.toString() ?? 'backlog'),
        createdBy: json['created_by']?.toString() ?? '',
        claimedBy: json['claimed_by']?.toString() ?? '',
        updatedAt:
            DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
                DateTime.now().toUtc(),
        result: json['result']?.toString() ?? '',
      );

  KanbanTask copyWith({
    KanbanState? state,
    String? claimedBy,
    String? result,
  }) =>
      KanbanTask(
        id: id,
        title: title,
        state: state ?? this.state,
        createdBy: createdBy,
        claimedBy: claimedBy ?? this.claimedBy,
        updatedAt: DateTime.now().toUtc(),
        result: result ?? this.result,
      );
}

/// Durable JSON-backed Kanban board shared across OS processes.
///
/// Every mutation happens inside a [CrossProcessLock] (exclusive O_EXCL file
/// create), so a CLI process and the daemon can safely share one board file.
/// [claim] is atomic: only one claimer can move a card from backlog to doing.
class KanbanBoard {
  KanbanBoard(
    this.filePath, {
    CrossProcessLock? lock,
    Duration lockTimeout = const Duration(seconds: 5),
  }) : _lock = lock ?? CrossProcessLock(filePath, timeout: lockTimeout);

  final String filePath;
  final CrossProcessLock _lock;
  final Random _rng = Random();

  Future<Map<String, dynamic>> _read() async {
    final file = File(filePath);
    if (!await file.exists()) return {'tasks': <String, dynamic>{}};
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return {'tasks': <String, dynamic>{}};
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return {'tasks': <String, dynamic>{}};
    return map;
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final tmp = '$filePath.tmp';
    await File(tmp).writeAsString(jsonEncode(data));
    await File(tmp).rename(filePath);
  }

  Map<String, KanbanTask> _tasks(Map<String, dynamic> data) {
    final raw = data['tasks'];
    if (raw is! Map<String, dynamic>) return {};
    return raw.map(
      (k, v) => MapEntry(
        k,
        v is Map<String, dynamic>
            ? KanbanTask.fromJson(v)
            : KanbanTask(id: k, title: '', state: KanbanState.backlog, createdBy: '', updatedAt: DateTime.now().toUtc()),
      ),
    );
  }

  String _newId() =>
      'kb-${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(1 << 32)}';

  Future<T> _mutate<T>(Future<T> Function(Map<String, KanbanTask>) fn) async {
    final ticket = await _lock.acquire();
    try {
      final data = await _read();
      final tasks = _tasks(data);
      final out = await fn(tasks);
      await _write({'tasks': tasks.map((k, v) => MapEntry(k, v.toJson()))});
      return out;
    } finally {
      await ticket.release();
    }
  }

  Future<KanbanTask> add(String title, {String createdBy = 'agent'}) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError('title kosong');
    final task = KanbanTask(
      id: _newId(),
      title: trimmed,
      state: KanbanState.backlog,
      createdBy: createdBy,
      updatedAt: DateTime.now().toUtc(),
    );
    return _mutate<KanbanTask>((tasks) async {
      tasks[task.id] = task;
      return task;
    });
  }

  Future<List<KanbanTask>> list({KanbanState? state}) async {
    final ticket = await _lock.acquire();
    try {
      final tasks = _tasks(await _read()).values.toList()
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      return state == null ? tasks : tasks.where((t) => t.state == state).toList();
    } finally {
      await ticket.release();
    }
  }

  Future<KanbanTask?> claim(String taskId, {String claimer = 'agent'}) =>
      _mutate<KanbanTask?>((tasks) async {
        final task = tasks[taskId];
        if (task == null || task.state != KanbanState.backlog) return null;
        final claimed = task.copyWith(
          state: KanbanState.doing,
          claimedBy: claimer,
        );
        tasks[taskId] = claimed;
        return claimed;
      });

  Future<KanbanTask?> complete(String taskId, {String result = ''}) =>
      _mutate<KanbanTask?>((tasks) async {
        final task = tasks[taskId];
        if (task == null || task.state != KanbanState.doing) return null;
        final done = task.copyWith(state: KanbanState.done, result: result);
        tasks[taskId] = done;
        return done;
      });

  Future<KanbanTask?> fail(String taskId, {String result = ''}) =>
      _mutate<KanbanTask?>((tasks) async {
        final task = tasks[taskId];
        if (task == null || task.state != KanbanState.doing) return null;
        final failed = task.copyWith(state: KanbanState.failed, result: result);
        tasks[taskId] = failed;
        return failed;
      });

  Future<bool> delete(String taskId) => _mutate<bool>((tasks) async {
        return tasks.remove(taskId) != null;
      });
}

/// Agent tool over [KanbanBoard]: durable multi-process task dispatch.
class KanbanTool implements Tool {
  KanbanTool(this.board);

  final KanbanBoard board;

  @override
  ToolSpec get spec => ToolSpec(
        name: 'kanban',
        description:
            'Papan Kanban durable lintas proses: tambah/klaim/selesaikan '
            'tugas. Gunakan untuk mendelegasikan pekerjaan ke worker lain.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['add', 'list', 'claim', 'complete', 'fail', 'delete'],
            },
            'id': {'type': 'string', 'description': 'Id tugas (claim/complete/fail/delete)'},
            'title': {'type': 'string', 'description': 'Judul tugas (add)'},
            'result': {'type': 'string', 'description': 'Catatan hasil (complete/fail)'},
            'state': {
              'type': 'string',
              'enum': ['backlog', 'doing', 'done', 'failed'],
              'description': 'Filter list',
            },
          },
          'required': ['action'],
        },
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    try {
      switch (action) {
        case 'add':
          final title = (args['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) {
            return const ToolResult(callId: '', content: 'title wajib untuk add', isError: true);
          }
          final task = await board.add(title, createdBy: ctx.session.userKey);
          return ToolResult(callId: '', content: 'added ${task.id} [backlog] $title');
        case 'list':
          final stateRaw = args['state'] as String?;
          final state = stateRaw == null || stateRaw.isEmpty
              ? null
              : _parseState(stateRaw);
          final tasks = await board.list(state: state);
          if (tasks.isEmpty) return const ToolResult(callId: '', content: '(kosong)');
          final buf = StringBuffer();
          for (final t in tasks) {
            buf.writeln(
              '${t.id} [${t.state.name}] ${t.title}'
              '${t.claimedBy.isEmpty ? '' : ' (by ${t.claimedBy})'}'
              '${t.result.isEmpty ? '' : ' => ${t.result}'}',
            );
          }
          return ToolResult(callId: '', content: buf.toString().trimRight());
        case 'claim':
          final task = await board.claim(
            (args['id'] as String?)?.trim() ?? '',
            claimer: ctx.session.userKey,
          );
          return task == null
              ? const ToolResult(
                  callId: '',
                  content: 'claim gagal: tugas tidak ada atau bukan backlog',
                  isError: true)
              : ToolResult(callId: '', content: 'claimed ${task.id} [doing]');
        case 'complete':
          final task = await board.complete(
            (args['id'] as String?)?.trim() ?? '',
            result: (args['result'] as String?) ?? '',
          );
          return task == null
              ? const ToolResult(
                  callId: '',
                  content: 'complete gagal: tugas tidak ada atau bukan doing',
                  isError: true)
              : ToolResult(callId: '', content: 'done ${task.id}');
        case 'fail':
          final task = await board.fail(
            (args['id'] as String?)?.trim() ?? '',
            result: (args['result'] as String?) ?? '',
          );
          return task == null
              ? const ToolResult(
                  callId: '',
                  content: 'fail gagal: tugas tidak ada atau bukan doing',
                  isError: true)
              : ToolResult(callId: '', content: 'failed ${task.id}');
        case 'delete':
          final ok = await board.delete((args['id'] as String?)?.trim() ?? '');
          return ok
              ? const ToolResult(callId: '', content: 'deleted')
              : const ToolResult(
                  callId: '', content: 'tugas tidak ditemukan', isError: true);
        default:
          return const ToolResult(
            callId: '',
            content: 'action tidak dikenal: add|list|claim|complete|fail|delete',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(callId: '', content: 'kanban error: $e', isError: true);
    }
  }
}
