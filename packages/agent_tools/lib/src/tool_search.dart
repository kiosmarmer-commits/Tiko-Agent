import 'dart:convert';

import 'package:agent_core/agent_core.dart';

/// Dynamic tool discovery (P2): instead of always sending every tool schema
/// to the model, a large registry exposes a relevance-ranked subset plus a
/// `tool_search` meta-tool so the model can pull additional schemas on
/// demand.
///
/// Scoring is deterministic keyword matching over name and description:
/// - exact tool-name match in the query: +10
/// - name token match: +4 per token
/// - description token match: +1 per token (capped at 5)
/// Ties break by name ascending.

/// Ranks [specs] against [query] and returns the top [k] most relevant.
List<ToolSpec> rankToolSpecs(
  List<ToolSpec> specs,
  String query, {
  int k = 12,
}) {
  final tokens = _tokenize(query);
  if (tokens.isEmpty) {
    return specs.take(k).toList();
  }
  final scored = <(ToolSpec, double)>[];
  for (final spec in specs) {
    final nameLower = spec.name.toLowerCase();
    final descLower = spec.description.toLowerCase();
    var score = 0.0;
    if (nameLower == query.trim().toLowerCase()) score += 10;
    if (query.trim().toLowerCase().contains(nameLower)) score += 6;
    for (final token in tokens) {
      if (nameLower.contains(token)) score += 4;
      var descHits = 0;
      if (descLower.contains(token)) {
        descHits++;
        score += 1;
      }
      if (descHits > 5) score += descHits - 5;
    }
    if (score > 0) scored.add((spec, score));
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    if (byScore != 0) return byScore;
    return a.$1.name.compareTo(b.$1.name);
  });
  return [for (final (spec, _) in scored) spec].take(k).toList();
}

Set<String> _tokenize(String query) {
  return query
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9_]+'))
      .where((t) => t.length >= 3)
      .toSet();
}

/// Meta-tool the model calls to discover tool schemas that were not included
/// in its context. Read-only: it only exposes specs already registered.
class ToolSearchTool implements Tool {
  ToolSearchTool(this._specsProvider);

  final List<ToolSpec> Function() _specsProvider;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'tool_search',
        description:
            'Cari tool berdasarkan kata kunci; kembalikan skema tool yang cocok. '
            'Gunakan bila tool yang dibutuhkan tidak ada di daftar tool aktif.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Kata kunci nama/fungsi tool',
            },
            'k': {
              'type': 'integer',
              'description': 'Maksimum hasil (default 8)',
            },
          },
          'required': ['query'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = args['query']?.toString() ?? '';
    if (query.trim().isEmpty) {
      return ToolResult(
        callId: '',
        content: 'query wajib diisi',
        isError: true,
      );
    }
    final k = (args['k'] as num?)?.toInt() ?? 8;
    final matches = rankToolSpecs(_specsProvider(), query, k: k.clamp(1, 32));
    final payload = [
      for (final m in matches)
        {
          'name': m.name,
          'description': m.description,
          'parameters': m.inputSchema,
          'risk': m.risk,
        },
    ];
    return ToolResult(
      callId: '',
      content: payload.isEmpty
          ? 'Tidak ada tool yang cocok untuk "$query".'
          : jsonEncode(payload),
    );
  }
}
