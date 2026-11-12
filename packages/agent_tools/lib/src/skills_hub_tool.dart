import 'package:agent_core/agent_core.dart';

import 'skills_hub.dart';

/// Tool wrapper for the Hermes-style Skills Hub marketplace. Install runs
/// the full safety pipeline inside [SkillsHubClient] (checksum, manifest,
/// static scan, path guard) before any file lands in the skills directory.
class SkillsHubTool implements Tool {
  SkillsHubTool(this._client);

  final SkillsHubClient _client;

  @override
  ToolSpec get spec => ToolSpec(
        name: 'skills_hub',
        description:
            'Skills Hub komunitas: cari, instal, hapus, dan daftar skill '
            'terpasang. Aksi: search|install|uninstall|list.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['search', 'install', 'uninstall', 'list'],
            },
            'query': {'type': 'string', 'description': 'Untuk aksi search'},
            'id': {
              'type': 'string',
              'description': 'Id/skill slug untuk install/uninstall',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      switch (args['action']?.toString()) {
        case 'search':
          final query = (args['query'] as String?)?.trim() ?? '';
          final results = await _client.search(query);
          if (results.isEmpty) {
            return const ToolResult(callId: '', content: '(tidak ada skill cocok)');
          }
          return ToolResult(
            callId: '',
            content: results
                .map((s) => '- ${s.id}\t${s.name}\t${s.description}')
                .join('\n'),
          );
        case 'install':
          final id = (args['id'] as String?)?.trim() ?? '';
          if (id.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'id wajib untuk aksi install',
              isError: true,
            );
          }
          final slug = await _client.installFromHub(id);
          return ToolResult(callId: '', content: 'skill terpasang: $slug');
        case 'uninstall':
          final slug = (args['id'] as String?)?.trim() ?? '';
          if (slug.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'id wajib untuk aksi uninstall',
              isError: true,
            );
          }
          final ok = await _client.uninstall(slug);
          return ToolResult(
            callId: '',
            content: ok ? 'dihapus: $slug' : 'tidak ditemukan: $slug',
          );
        case 'list':
          await _client.refreshInstalled();
          final installed = _client.installed;
          if (installed.isEmpty) {
            return const ToolResult(
              callId: '',
              content: '(belum ada skill hub terpasang)',
            );
          }
          return ToolResult(
            callId: '',
            content: installed.entries
                .map((e) => '- ${e.key}\t${e.value.name}\tv${e.value.version}')
                .join('\n'),
          );
        default:
          return const ToolResult(
            callId: '',
            content: 'aksi tidak dikenal; gunakan search|install|uninstall|list',
            isError: true,
          );
      }
    } on SkillsHubException catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    }
  }
}
