/// Fase 33 — tool `raptor` (audit 2026-11-28 §6 #12, RAPTOR-lite):
/// build pohon ringkasan dari korpus RAG runtime, query pertanyaan global,
/// dan status. Deterministik, bounded, never-raises. Pohon persist ke
/// [treePath] agar tidak rebuild tiap restart; query return ringkasan +
/// id chunk sumber untuk drill-down/citation lewat jalur RAG biasa.
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';

class RaptorTool extends Tool {
  RaptorTool({
    required this.chunksProvider,
    required this.treePath,
    this.onEvent,
  });

  /// Chunk korpus dari pipeline RAG runtime (dipanggil saat build).
  final List<({String id, String text})> Function() chunksProvider;
  final String treePath;
  final void Function(String type, Map<String, dynamic> data)? onEvent;

  RaptorTree? _tree;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'raptor',
        description:
            'Pohon ringkasan hierarkis korpus dokumen (RAPTOR-lite). '
            'Aksi "build": bangun/rebuild pohon dari korpus RAG. '
            'Aksi "query": cari ringkasan yang relevan untuk pertanyaan '
            'global (return ringkasan + id chunk sumber). '
            'Aksi "status": statistik pohon.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['build', 'query', 'status'],
            },
            'query': {'type': 'string'},
            'top_k': {'type': 'integer'},
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = '${args['action'] ?? ''}'.trim();
    try {
      switch (action) {
        case 'build':
          _tree = RaptorTree();
          final count = _tree!.build(chunksProvider());
          _tree!.save(treePath);
          _emit('raptor.built', {
            'nodes': count,
            'chunks': count == 0 ? 0 : _leafCount(),
          });
          return ToolResult(
            callId: '',
            content: const JsonEncoder.withIndent('  ').convert({
              'action': 'build',
              'nodes': count,
              'saved': treePath,
            }),
          );
        case 'query':
          final query = '${args['query'] ?? ''}'.trim();
          if (query.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'Parameter "query" wajib untuk aksi query.',
              isError: true,
            );
          }
          final tree = _tree ??= RaptorTree.load(treePath);
          if (tree == null || !tree.built) {
            return const ToolResult(
              callId: '',
              content:
                  'Pohon RAPTOR belum dibangun. Jalankan aksi "build" '
                  'terlebih dahulu.',
              isError: true,
            );
          }
          final topK = (args['top_k'] as num?)?.toInt() ?? 4;
          final result =
              tree.query(query, topK: topK.clamp(1, 10));
          _emit('raptor.query', {
            'matches': result.matchedNodes.length,
            'sources': result.sourceChunkIds.length,
          });
          return ToolResult(
            callId: '',
            content: const JsonEncoder.withIndent('  ').convert({
              'query': query.length > 200 ? query.substring(0, 200) : query,
              'matches': [
                for (final (node, score) in result.matchedNodes)
                  {
                    'id': node.id,
                    'level': node.level,
                    'score': double.parse(score.toStringAsFixed(4)),
                    'summary': node.summary,
                  },
              ],
              'source_chunk_ids': result.sourceChunkIds,
            }),
          );
        case 'status':
          final tree = _tree ??= RaptorTree.load(treePath);
          return ToolResult(
            callId: '',
            content: const JsonEncoder.withIndent('  ').convert({
              'built': tree != null && tree.built,
              'nodes': tree?.nodeCount ?? 0,
              'levels': _levelCounts(tree),
              'path': treePath,
            }),
          );
        default:
          return const ToolResult(
            callId: '',
            content: 'Aksi tidak dikenal; gunakan build/query/status.',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'raptor gagal: $e',
        isError: true,
      );
    }
  }

  int _leafCount() {
    final tree = _tree;
    if (tree == null) return 0;
    return tree.nodes
        .where((n) => n.level == 0)
        .length;
  }

  Map<int, int> _levelCounts(RaptorTree? tree) {
    if (tree == null) return {};
    final out = <int, int>{};
    for (final n in tree.nodes) {
      out[n.level] = (out[n.level] ?? 0) + 1;
    }
    return out;
  }

  void _emit(String type, Map<String, dynamic> data) {
    try {
      onEvent?.call(type, data);
    } catch (_) {}
  }
}
