import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Fase 40 — Review learnings queue (paritas Grok Bot "Review learnings"):
/// pelajaran hasil interaksi bot diantrikan dan WAJIB disetujui owner
/// sebelum masuk memori bot (`BotProfile.learnings`).
///
/// Konvensi repo:
/// - Fail-closed: proposal hanya masuk memori bot lewat approve eksplisit.
/// - Never-raises: semua aksi mengembalikan laporan/error jujur.
/// - Persist lokal: satu file JSON `<dataDir>/review_learnings.json`
///   (atomic tmp+rename), cap jumlah proposal.
enum LearningStatus { pending, approved, rejected }

class LearningProposal {
  LearningProposal({
    required this.id,
    required this.content,
    required this.source,
    this.botId = '',
    this.sessionId = '',
    this.status = LearningStatus.pending,
    DateTime? createdAt,
    this.decidedAt,
    this.decidedBy = '',
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String content;

  /// 'conversation' | 'note' | 'feedback'.
  final String source;
  final String botId;
  final String sessionId;
  LearningStatus status;
  final DateTime createdAt;
  DateTime? decidedAt;
  String decidedBy;

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'source': source,
        'bot_id': botId,
        'session_id': sessionId,
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        if (decidedAt != null) 'decided_at': decidedAt!.toIso8601String(),
        'decided_by': decidedBy,
      };

  static LearningProposal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final content = raw['content'];
    if (id is! String ||
        content is! String ||
        content.trim().isEmpty) {
      return null;
    }
    return LearningProposal(
      id: id,
      content: content.trim(),
      source: raw['source'] is String ? raw['source'] as String : 'note',
      botId: raw['bot_id'] is String ? raw['bot_id'] as String : '',
      sessionId: raw['session_id'] is String ? raw['session_id'] as String : '',
      status: LearningStatus.values.firstWhere(
        (s) => s.name == raw['status'],
        orElse: () => LearningStatus.pending,
      ),
      createdAt: DateTime.tryParse(raw['created_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      decidedAt: raw['decided_at'] is String
          ? DateTime.tryParse(raw['decided_at'] as String)?.toUtc()
          : null,
      decidedBy: raw['decided_by'] is String ? raw['decided_by'] as String : '',
    );
  }
}

/// Store antrian pembelajaran. Fail-open terhadap file korup.
class ReviewLearningsStore {
  ReviewLearningsStore({
    required String path,
    this.maxProposals = 200,
    this.maxContentChars = 4000,
  }) : path = path;

  final String path;
  final int maxProposals;
  final int maxContentChars;

  final Map<String, LearningProposal> _items = {};
  bool _loaded = false;
  int _counter = 0;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = json['proposals'];
      if (raw is! List) return;
      for (final item in raw) {
        final proposal = LearningProposal.fromJson(item);
        if (proposal != null && LearningProposal.idPattern.hasMatch(proposal.id)) {
          _items[proposal.id] = proposal;
        }
      }
    } on FormatException {
      _items.clear();
    }
  }

  List<LearningProposal> list({LearningStatus? status}) {
    final items = _items.values
        .where((e) => status == null || e.status == status)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List.unmodifiable(items);
  }

  LearningProposal? get(String id) => _items[id];

  Future<LearningProposal> propose({
    required String content,
    String source = 'note',
    String botId = '',
    String sessionId = '',
  }) async {
    final now = DateTime.now().toUtc();
    _counter += 1;
    var id = 'learn-${now.millisecondsSinceEpoch.toRadixString(36)}-$_counter';
    while (_items.containsKey(id)) {
      _counter += 1;
      id = 'learn-${now.millisecondsSinceEpoch.toRadixString(36)}-$_counter';
    }
    var text = content.trim();
    if (text.length > maxContentChars) {
      text = text.substring(0, maxContentChars);
    }
    final proposal = LearningProposal(
      id: id,
      content: text,
      source: source,
      botId: botId,
      sessionId: sessionId,
      createdAt: now,
    );
    _items[id] = proposal;
    while (_items.length > maxProposals) {
      _removeOldestPending();
    }
    await _persist();
    return proposal;
  }

  /// Set status proposal (idempoten aman: keputusan hanya mengubah pending).
  Future<LearningProposal?> decide(
    String id, {
    required bool approve,
    String decidedBy = '',
  }) async {
    final proposal = _items[id];
    if (proposal == null || proposal.status != LearningStatus.pending) return null;
    proposal
      ..status = approve ? LearningStatus.approved : LearningStatus.rejected
      ..decidedAt = DateTime.now().toUtc()
      ..decidedBy = decidedBy;
    await _persist();
    return proposal;
  }

  void _removeOldestPending() {
    final pendings = _items.values
        .where((e) => e.status == LearningStatus.pending)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (pendings.isEmpty) {
      final all = _items.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (all.isEmpty) return;
      _items.remove(all.first.id);
      return;
    }
    _items.remove(pendings.first.id);
  }

  Future<void> _persist() async {
    await Directory(p.dirname(path)).create(recursive: true);
    final payload = jsonEncode({
      'proposals': _items.values.map((e) => e.toJson()).toList(),
    });
    final tmp = File('$path.tmp');
    await tmp.writeAsString(payload);
    await tmp.rename(path);
  }
}

/// Tool `review_learnings` — antrian pembelajaran bot: propose/list/approve/
/// reject. Approve hanya menandai proposal; penulisan ke memori bot dilakukan
/// wiring runtime lewat callback `onApproved` (tetap fail-closed: tool tidak
/// pernah menulis memori langsung).
class ReviewLearningsTool implements Tool {
  ReviewLearningsTool({
    required this.store,
    this.onApproved,
  });

  final ReviewLearningsStore store;

  /// Dipanggil saat proposal disetujui; return false berarti penulisan
  /// memori gagal dan laporan menandainya.
  final Future<bool> Function(LearningProposal proposal)? onApproved;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'review_learnings',
        description:
            'Kelola antrian pembelajaran bot: ajukan pelajaran baru, lihat '
            'antrian, setujui atau tolak. Hanya proposal yang disetujui yang '
            'masuk memori bot. Actions: propose, list, approve, reject.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['propose', 'list', 'approve', 'reject'],
            },
            'content': {
              'type': 'string',
              'description': 'Isi pelajaran untuk action propose.',
            },
            'bot': {
              'type': 'string',
              'description': 'Id bot sasaran (opsional; kosong = host).',
            },
            'source': {
              'type': 'string',
              'description': 'Asal pelajaran: conversation, note, feedback.',
            },
            'id': {
              'type': 'string',
              'description': 'Id proposal untuk approve/reject.',
            },
            'status_filter': {
              'type': 'string',
              'enum': ['pending', 'approved', 'rejected'],
              'description': 'Filter status untuk list (default pending).',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 30,
        maxOutputChars: 12000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final content = (args['content'] as String?)?.trim() ?? '';
    final botId = (args['bot'] as String?)?.trim().toLowerCase() ?? '';
    final source = (args['source'] as String?)?.trim().toLowerCase() ?? 'note';
    final id = (args['id'] as String?)?.trim() ?? '';
    try {
      switch (action) {
        case 'propose':
          if (content.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'content wajib untuk action propose.',
              isError: true,
            );
          }
          final validSource =
              const {'conversation', 'note', 'feedback'}.contains(source)
                  ? source
                  : 'note';
          final proposal = await store.propose(
            content: content,
            source: validSource,
            botId: botId,
            sessionId: ctx.session.id,
          );
          return ToolResult(
            callId: '',
            content: 'Pelajaran "${proposal.id}" masuk antrian review. '
                'Owner harus menyetujui sebelum masuk memori bot.',
          );

        case 'list':
          await store.load();
          final filterRaw = (args['status_filter'] as String?)?.trim() ?? '';
          LearningStatus? filter;
          for (final s in LearningStatus.values) {
            if (s.name == filterRaw) filter = s;
          }
          final items = store.list(status: filter ?? LearningStatus.pending);
          if (items.isEmpty) {
            return const ToolResult(
                callId: '', content: 'Antrian kosong untuk filter ini.');
          }
          final buf = StringBuffer();
          for (final item in items) {
            buf.writeln(
                '- ${item.id} [${item.status.name}] (${item.source})${item.botId.isNotEmpty ? ' bot=${item.botId}' : ''}: ${item.content}');
          }
          return ToolResult(callId: '', content: buf.toString().trim());

        case 'approve':
        case 'reject':
          if (id.isEmpty) {
            return ToolResult(
              callId: '',
              content: 'id wajib untuk action $action.',
              isError: true,
            );
          }
          final proposal = await store.decide(
            id,
            approve: action == 'approve',
            decidedBy: ctx.session.id,
          );
          if (proposal == null) {
            return ToolResult(
              callId: '',
              content:
                  'Proposal "$id" tidak dikenal atau sudah diputuskan.',
              isError: true,
            );
          }
          if (action == 'reject') {
            return ToolResult(
              callId: '',
              content: 'Pelajaran "${proposal.id}" ditolak.',
            );
          }
          var memoryOk = true;
          if (onApproved != null) {
            try {
              memoryOk = await onApproved!(proposal);
            } catch (_) {
              memoryOk = false;
            }
          }
          return ToolResult(
            callId: '',
            content: memoryOk
                ? 'Pelajaran "${proposal.id}" disetujui dan masuk memori bot.'
                : 'Pelajaran "${proposal.id}" disetujui tetapi penulisan '
                    'memori gagal.',
            isError: !memoryOk,
          );

        default:
          return const ToolResult(
            callId: '',
            content:
                'action tidak dikenal. Gunakan: propose, list, approve, reject.',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'review_learnings gagal: $e',
        isError: true,
      );
    }
  }
}
