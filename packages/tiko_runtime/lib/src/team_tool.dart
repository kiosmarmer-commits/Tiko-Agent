import 'package:agent_core/agent_core.dart';

/// Runs one prompt as a specific team member and returns the final text.
/// The host injects this so the tool stays decoupled from TikoRuntime.
typedef TeamTurnRunner = Future<String> Function(
  String prompt,
  AgentSpec agent,
);

/// Multi-agent team execution tool (Hermes v0.6-style orchestration).
///
/// Input is a DAG of tasks; independent tasks run in parallel waves with
/// results shared through a [Blackboard], then everything is synthesized
/// into a single answer.
class AgentTeamTool implements Tool {
  AgentTeamTool({required this.runner, this.maxTasks = 8});

  final TeamTurnRunner runner;
  final int maxTasks;

  /// Default role-specialized members, addressable by id via `agent`.
  static final AgentRegistry defaultRegistry = AgentRegistry()
    ..register(const AgentSpec(
      id: 'planner',
      role: AgentRole.planner,
      systemPrompt:
          'Kamu planner. Pecah tujuan menjadi langkah konkret dan berurutan.',
      maxTurns: 4,
    ))
    ..register(const AgentSpec(
      id: 'researcher',
      role: AgentRole.researcher,
      systemPrompt:
          'Kamu researcher. Kumpulkan fakta relevan dan sitasi sumbernya.',
      maxTurns: 6,
    ))
    ..register(const AgentSpec(
      id: 'coder',
      role: AgentRole.coder,
      systemPrompt: 'Kamu coder. Tulis kode yang benar, lengkap, dan siap uji.',
      maxTurns: 6,
    ))
    ..register(const AgentSpec(
      id: 'critic',
      role: AgentRole.critic,
      systemPrompt:
          'Kamu critic. Temukan cacat, risiko, dan langkah yang belum terverifikasi.',
      maxTurns: 4,
    ))
    ..register(const AgentSpec(
      id: 'summarizer',
      role: AgentRole.summarizer,
      systemPrompt: 'Kamu summarizer. Rangkum temuan menjadi jawaban akhir ringkas.',
      maxTurns: 4,
    ));

  @override
  ToolSpec get spec => ToolSpec(
        name: 'agent_team',
        description:
            'Jalankan tim multi-agent pada DAG tugas; tugas independen '
            'berjalan paralel dan hasilnya disintesis. Input: goal + tasks.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'goal': {'type': 'string'},
            'tasks': {
              'type': 'array',
              'description':
                  'Daftar tugas: {id, prompt, agent?, depends_on?: [id]}',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'prompt': {'type': 'string'},
                  'agent': {
                    'type': 'string',
                    'description':
                        'Id anggota tim: planner|researcher|coder|critic|summarizer',
                  },
                  'depends_on': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['id', 'prompt'],
              },
            },
          },
          'required': ['goal', 'tasks'],
        },
        risk: 'medium',
        timeoutSec: 600,
        maxOutputChars: 40000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final goal = (args['goal'] as String?)?.trim() ?? '';
    final rawTasks = args['tasks'];
    if (rawTasks is! List || rawTasks.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'tasks wajib berupa daftar tidak kosong',
        isError: true,
      );
    }
    if (rawTasks.length > maxTasks) {
      return ToolResult(
        callId: '',
        content: 'terlalu banyak tugas (maks $maxTasks)',
        isError: true,
      );
    }
    final graph = TaskGraph();
    try {
      for (final raw in rawTasks) {
        if (raw is! Map) {
          return const ToolResult(
            callId: '',
            content: 'setiap task harus berupa objek',
            isError: true,
          );
        }
        final map = Map<String, dynamic>.from(raw);
        if (map['agent'] != null && map['agent_id'] == null) {
          map['agent_id'] = map.remove('agent');
        }
        final node = TaskNode.fromJson(map);
        if (node.id.isEmpty || node.prompt.trim().isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'setiap task butuh id dan prompt',
            isError: true,
          );
        }
        graph.add(node);
      }
    } on ArgumentError catch (e) {
      return ToolResult(callId: '', content: e.message ?? '$e', isError: true);
    } on StateError catch (e) {
      return ToolResult(callId: '', content: e.message, isError: true);
    }

    final orchestrator = TeamOrchestrator(
      executor: (agent, node, blackboard) async {
        final prompt = agent.systemPrompt.isEmpty
            ? node.prompt
            : '${agent.systemPrompt}\n\n${node.prompt}';
        return runner(prompt, agent);
      },
      registry: defaultRegistry,
    );

    try {
      final result = await orchestrator.run(graph, goal: goal);
      final failed = result.results.where((r) => !r.success).toList();
      final buffer = StringBuffer();
      if (result.synthesis.isNotEmpty) {
        buffer
          ..writeln(result.synthesis)
          ..writeln();
      }
      buffer.writeln('--- status tugas ---');
      for (final r in result.results) {
        buffer.writeln(
          '${r.success ? "OK" : "GAGAL"}\t${r.taskId}\t'
          '${r.agentId}\t${r.durationMs}ms',
        );
      }
      return ToolResult(
        callId: '',
        content: buffer.toString().trim(),
        isError: failed.length == result.results.length &&
            result.results.isNotEmpty,
      );
    } on StateError catch (e) {
      return ToolResult(callId: '', content: e.message, isError: true);
    }
  }
}
