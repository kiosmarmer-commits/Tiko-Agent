import 'package:agent_core/agent_core.dart';

import 'rag_pipeline.dart';

/// Exposes [RagPipeline] ingestion to the agent: chunk + index a document
/// into the hybrid (dense + BM25) store.
class RagIngestTool implements Tool {
  RagIngestTool(this._pipeline);

  final RagPipeline _pipeline;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'rag_ingest',
        description:
            'Indeks dokumen ke store RAG hibrida (chunking paragraf + dense + BM25).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'doc_id': {'type': 'string', 'description': 'Pengenal dokumen unik'},
            'text': {'type': 'string', 'description': 'Isi dokumen'},
          },
          'required': ['doc_id', 'text'],
        },
        risk: 'low',
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final docId = (args['doc_id'] as String?)?.trim() ?? '';
    final text = (args['text'] as String?) ?? '';
    if (docId.isEmpty || text.trim().isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'doc_id dan text wajib diisi',
        isError: true,
      );
    }
    final chunks = await _pipeline.ingest(docId, text);
    return ToolResult(
      callId: '',
      content: 'terindeks ${chunks.length} chunk untuk dokumen $docId',
    );
  }
}

/// Hybrid retrieval (dense + BM25 + RRF + lexical rerank) over the ingested
/// corpus; returns the cited context block ready for the prompt.
class RagQueryTool implements Tool {
  RagQueryTool(this._pipeline);

  final RagPipeline _pipeline;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'rag_query',
        description:
            'Retrieval hibrida (dense + BM25 + RRF) di atas dokumen yang '
            'diindeks rag_ingest; mengembalikan konteks bersitasi.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'k': {
              'type': 'integer',
              'description': 'Jumlah hit maksimal (default 6)',
            },
          },
          'required': ['query'],
        },
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'query wajib diisi',
        isError: true,
      );
    }
    final k = (args['k'] as num?)?.toInt() ?? 6;
    final result = await _pipeline.retrieve(query, k: k);
    if (result.hits.isEmpty) {
      return const ToolResult(callId: '', content: '(tidak ada dokumen cocok)');
    }
    return ToolResult(callId: '', content: result.context);
  }
}
