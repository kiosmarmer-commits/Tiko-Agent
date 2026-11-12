import 'package:agent_core/agent_core.dart';

/// Cross-conversation session search (P1: parity with Hermes session search).
/// Returns ranked, redacted snippets from past conversations so the model can
/// recall what happened in earlier sessions and summarize them.
class SessionSearchTool implements Tool {
  SessionSearchTool(this.store);

  final SessionStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'session_search',
    description:
        'Cari lintas percakapan lama (semua sesi tersimpan). Mengembalikan '
        'potongan pesan yang relevan beserta sesi asalnya; gunakan untuk '
        'mengingat konteks percakapan sebelumnya.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'limit': {'type': 'integer'},
      },
      'required': ['query'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final q = (args['query'] as String?)?.trim() ?? '';
    if (q.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'query wajib',
        isError: true,
      );
    }
    final limit = (args['limit'] as num?)?.toInt() ?? 8;
    final hits = await store.searchSessions(q, limit: limit.clamp(1, 50));
    if (hits.isEmpty) {
      return const ToolResult(callId: '', content: '(tidak ada percakapan cocok)');
    }
    final lines = [
      for (final h in hits)
        '- [${h.score.toStringAsFixed(2)}] ${h.title ?? h.sessionId} '
            '(${h.role}${h.timestamp == null ? '' : ', ${h.timestamp!.toIso8601String()}'}): '
            '${h.snippet.replaceAll('\n', ' ')}',
    ].join('\n');
    // Search results are evidence, not instructions. Neutralize any attempt
    // inside stored text to close or forge the untrusted-data envelope.
    final safeLines = lines
        .replaceAll('</untrusted_data', '<\\/untrusted_data')
        .replaceAll('<untrusted_data', '<\\untrusted_data');
    return ToolResult(
      callId: '',
      content: '<untrusted_data source="session-search">\n$safeLines\n</untrusted_data>',
    );
  }
}
