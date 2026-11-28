/// Fase 34 — tool `graph_query` (GraphRAG-lite, audit §6 #13): query graph
/// wikilink vault simpul ke agent utama. Vault discan read-only saat build
/// (bounded [GraphRagCfg.maxNotes]); teks note dianggap untrusted evidence;
/// AI access policy note-level (AI-42) tetap milik jalur simpul — tool ini
/// hanya membaca file markdown biasa yang sudah bisa dibaca agent via
/// permission file normal.
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:simpul_core/simpul_core.dart';

class GraphRagQueryTool extends Tool {
  GraphRagQueryTool({
    required this.vaultDir,
    required this.maxHops,
    required this.maxNotes,
    this.onEvent,
  });

  final String vaultDir;
  final int maxHops;
  final int maxNotes;
  final void Function(String type, Map<String, dynamic> data)? onEvent;

  GraphRagIndex? _index;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'graph_query',
        description:
            'GraphRAG-lite atas vault Markdown (simpul): cari konteks '
            'lintas note memakai graph wikilink (seed + ekspansi hop) dan '
            'ringkasan community (Louvain). Return context ber-marker '
            '[n] source + daftar path sumber untuk citation.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'top_k': {'type': 'integer'},
            'rebuild': {'type': 'boolean'},
          },
          'required': ['query'],
        },
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = '${args['query'] ?? ''}'.trim();
    if (query.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Parameter "query" wajib diisi.',
        isError: true,
      );
    }
    try {
      final rebuild = args['rebuild'] is bool && args['rebuild'] as bool;
      if (_index == null || !_index!.built || rebuild) {
        final scanned = await VaultScanner.scan(vaultDir);
        final notes = [
          for (final s in scanned.take(maxNotes)) s.toIndexed(),
        ];
        _index = GraphRagIndex(maxHops: maxHops)..build(notes);
        _emit('graph_rag.indexed', {
          'notes': notes.length,
          'communities': _index!.communityCount,
        });
      }
      final topK = (args['top_k'] as num?)?.toInt() ?? 6;
      final answer = _index!.query(query, topK: topK.clamp(1, 12));
      _emit('graph_rag.query', {
        'sources': answer.sources.length,
        'global': answer.globalQuery,
      });
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ').convert({
          'query': query.length > 200 ? query.substring(0, 200) : query,
          'empty': answer.isEmpty,
          'community_count': answer.communityCount,
          'sources': [for (final s in answer.sources) s.toJson()],
          'context': answer.context,
        }),
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'graph_query gagal: $e',
        isError: true,
      );
    }
  }

  void _emit(String type, Map<String, dynamic> data) {
    try {
      onEvent?.call(type, data);
    } catch (_) {} // best-effort
  }
}
