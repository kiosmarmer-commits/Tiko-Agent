import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'memory_layers.dart';

/// Tool wrapper for the layered memory system (episodic/semantic/procedural)
/// with importance scoring and Ebbinghaus-style decay.
class LayeredMemoryTool implements Tool {
  LayeredMemoryTool(this._memory);

  final LayeredMemory _memory;

  @override
  ToolSpec get spec => ToolSpec(
        name: 'layered_memory',
        description:
            'Memori berlapis (episodic/semantic/procedural) dengan skor '
            'kepentingan dan decay. Aksi: add|retrieve|consolidate|stats.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['add', 'retrieve', 'consolidate', 'stats'],
            },
            'layer': {
              'type': 'string',
              'enum': ['episodic', 'semantic', 'procedural'],
              'description': 'Layer untuk aksi add (default episodic)',
            },
            'text': {'type': 'string'},
            'importance': {'type': 'number'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'query': {'type': 'string'},
            'k': {'type': 'integer'},
          },
          'required': ['action'],
        },
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final now = DateTime.now().toUtc();
    switch (args['action']?.toString()) {
      case 'add':
        final text = (args['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'text wajib untuk aksi add',
            isError: true,
          );
        }
        final layerName = args['layer']?.toString() ?? 'episodic';
        final layer = MemoryLayerType.values.firstWhere(
          (l) => l.name == layerName,
          orElse: () => MemoryLayerType.episodic,
        );
        final entry = _memory.add(
          layer,
          text,
          importance: (args['importance'] as num?)?.toDouble() ?? 0.5,
          tags: [
            for (final t in (args['tags'] as List<dynamic>? ?? const <dynamic>[]))
              t.toString(),
          ],
          ownerKey: ctx.session.userKey,
          sourceSession: ctx.session.id,
          now: now,
        );
        return ToolResult(
          callId: '',
          content: 'tersimpan ${entry.id} (layer ${entry.layer.name})',
        );
      case 'retrieve':
        final query = (args['query'] as String?)?.trim() ?? '';
        if (query.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'query wajib untuk aksi retrieve',
            isError: true,
          );
        }
        final k = (args['k'] as num?)?.toInt() ?? 8;
        final hits = _memory.retrieve(query, k: k, ownerKey: ctx.session.userKey);
        if (hits.isEmpty) {
          return const ToolResult(callId: '', content: '(tidak ada hasil)');
        }
        return ToolResult(
          callId: '',
          content: hits
              .map((e) => '- [${e.layer.name}; '
                  '${e.effectiveScore(now, halfLifeDays: _memory.halfLifeDays).toStringAsFixed(2)}] '
                  '${e.text}')
              .join('\n'),
        );
      case 'consolidate':
        final report = _memory.consolidate(now: now);
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'promoted': report.promoted,
            'decayed': report.decayed,
            'forgotten': report.forgotten,
          }),
        );
      case 'stats':
        return ToolResult(callId: '', content: jsonEncode(_memory.stats(now: now)));
      default:
        return const ToolResult(
          callId: '',
          content: 'aksi tidak dikenal; gunakan add|retrieve|consolidate|stats',
          isError: true,
        );
    }
  }
}
