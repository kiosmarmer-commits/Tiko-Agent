import 'package:agent_core/agent_core.dart';

/// lease — explicit resource locking between parallel subagents
/// (NEW-07). Owner is the session id, so subagents of one runtime
/// coordinate through the shared LeaseManager instance.
class LeaseTool implements Tool {
  LeaseTool({required this.manager});

  final LeaseManager manager;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'lease',
    description:
        'Kunci sumber daya lintas subagent: file:..., port:..., db:... '
        'Aksi acquire/release/list; TTL mencegah deadlock.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['acquire', 'release', 'list'],
        },
        'resource': {
          'type': 'string',
          'description': 'Sumber daya, mis. file:src/main.go atau port:8080.',
        },
        'ttl_s': {
          'type': 'integer',
          'description': 'Umur lease dalam detik (default 600, maks 3600).',
        },
      },
      'required': ['action'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action'] as String? ?? '';
    switch (action) {
      case 'acquire':
        return _acquire(args, ctx);
      case 'release':
        return _release(args, ctx);
      case 'list':
        return _list();
      default:
        return const ToolResult(
          callId: '',
          content: 'action harus acquire, release, atau list',
          isError: true,
        );
    }
  }

  Future<ToolResult> _acquire(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final resource = args['resource'] as String? ?? '';
    if (!RegExp(r'^[a-z]+:[\w:./-]+$').hasMatch(resource)) {
      return const ToolResult(
        callId: '',
        content: 'resource tidak valid; format jenis:nama (mis. file:src/a.go)',
        isError: true,
      );
    }
    var ttl = (args['ttl_s'] as num?)?.toInt() ?? 600;
    if (ttl < 1) ttl = 1;
    if (ttl > 3600) ttl = 3600;
    final ok = manager.acquire(
      resource,
      ctx.session.id,
      Duration(seconds: ttl),
    );
    return ToolResult(
      callId: '',
      content: ok
          ? 'OK lease $resource diperoleh (TTL ${ttl}s)'
          : 'Gagal: $resource masih dipegang owner lain',
      isError: !ok,
    );
  }

  Future<ToolResult> _release(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final resource = args['resource'] as String? ?? '';
    final ok = manager.release(resource, ctx.session.id);
    return ToolResult(
      callId: '',
      content: ok
          ? 'OK lease $resource dilepas'
          : 'Tidak ada lease $resource milik sesi ini',
      isError: !ok,
    );
  }

  ToolResult _list() {
    final items = manager.list();
    if (items.isEmpty) {
      return const ToolResult(
        callId: '',
        content: '(tidak ada lease aktif)',
      );
    }
    final lines = <String>[];
    for (final i in items) {
      final status = i.expired ? 'kedaluwarsa' : 'aktif';
      lines.add(
        '${i.resource} owner=${i.owner} status=$status '
        'expires=${i.expiresAt.toUtc().toIso8601String()}',
      );
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
