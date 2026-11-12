import 'dart:convert';

/// Multi-agent orchestration (Hermes v0.6-style subagent teams).
///
/// A team is a set of [AgentSpec] members coordinated by [TeamOrchestrator]
/// over a [TaskGraph]. Independent nodes run in parallel waves, dependent
/// nodes receive their upstream outputs through a shared [Blackboard], and a
/// final synthesis step joins the partial results into one answer.
///
/// The executor callback is injected so the orchestrator stays pure and
/// deterministic in tests: hosts wire it to their agent loop, tests wire it
/// to a stub.

/// Specialization of a team member.
enum AgentRole { planner, researcher, coder, critic, summarizer, custom }

/// Declarative description of one team member.
class AgentSpec {
  const AgentSpec({
    required this.id,
    required this.role,
    required this.systemPrompt,
    this.toolAllowlist = const [],
    this.modelTier = 'standard',
    this.maxTurns = 8,
  });

  final String id;
  final AgentRole role;
  final String systemPrompt;

  /// Empty means the member inherits the host tool registry; otherwise the
  /// host must restrict this member to the listed tool names.
  final List<String> toolAllowlist;
  final String modelTier;
  final int maxTurns;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'system_prompt': systemPrompt,
        'tool_allowlist': toolAllowlist,
        'model_tier': modelTier,
        'max_turns': maxTurns,
      };

  factory AgentSpec.fromJson(Map<String, dynamic> json) => AgentSpec(
        id: json['id'] as String? ?? '',
        role: AgentRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => AgentRole.custom,
        ),
        systemPrompt: json['system_prompt'] as String? ?? '',
        toolAllowlist: (json['tool_allowlist'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        modelTier: json['model_tier'] as String? ?? 'standard',
        maxTurns: json['max_turns'] as int? ?? 8,
      );
}

/// Registry of team members, addressable by id and by role.
class AgentRegistry {
  final Map<String, AgentSpec> _agents = {};

  int get length => _agents.length;

  void register(AgentSpec spec) => _agents[spec.id] = spec;

  AgentSpec? get(String id) => _agents[id];

  /// First registered agent with [role], or null.
  AgentSpec? byRole(AgentRole role) {
    for (final spec in _agents.values) {
      if (spec.role == role) return spec;
    }
    return null;
  }

  List<AgentSpec> get all => _agents.values.toList(growable: false);
}

/// Shared memory between team members. Every write bumps [revision] so
/// callers can detect stale reads.
class Blackboard {
  final Map<String, Object?> _slots = {};
  int _revision = 0;

  int get revision => _revision;

  void write(String slot, Object? value, {String? writer}) {
    _slots[slot] = value;
    _revision++;
    if (writer != null) {
      final writers = _writers.putIfAbsent(slot, () => <String>[]);
      if (!writers.contains(writer)) writers.add(writer);
    }
  }

  final Map<String, List<String>> _writers = {};

  Object? read(String slot) => _slots[slot];

  /// Output slot convention used by [TeamOrchestrator].
  static String resultSlot(String taskId) => 'result:$taskId';

  /// Dependency input slot convention: upstream output of [taskId].
  static String depSlot(String taskId) => 'dep:$taskId';

  Map<String, Object?> snapshot() => Map<String, Object?>.unmodifiable(_slots);
}

/// One unit of work inside a [TaskGraph].
class TaskNode {
  const TaskNode({
    required this.id,
    required this.prompt,
    this.agentId,
    this.dependsOn = const [],
    this.metadata = const {},
  });

  final String id;
  final String prompt;

  /// Team member that executes this node; null lets the orchestrator pick
  /// a default agent.
  final String? agentId;

  /// Ids of nodes that must complete before this one starts.
  final List<String> dependsOn;
  final Map<String, Object?> metadata;

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        if (agentId != null) 'agent_id': agentId,
        'depends_on': dependsOn,
        'metadata': metadata,
      };

  factory TaskNode.fromJson(Map<String, dynamic> json) => TaskNode(
        id: json['id'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        agentId: json['agent_id'] as String?,
        dependsOn: (json['depends_on'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        metadata: json['metadata'] is Map
            ? Map<String, Object?>.from(json['metadata'] as Map)
            : const {},
      );
}

/// Directed acyclic graph of [TaskNode]s.
class TaskGraph {
  final List<TaskNode> _nodes = [];

  int get length => _nodes.length;

  void add(TaskNode node) {
    if (_nodes.any((n) => n.id == node.id)) {
      throw ArgumentError('Duplicate task id: ${node.id}');
    }
    _nodes.add(node);
  }

  List<TaskNode> get nodes => List<TaskNode>.unmodifiable(_nodes);

  /// Topological waves of node ids. Nodes in the same wave are independent
  /// and safe to run in parallel. Throws [StateError] on unknown
  /// dependencies or dependency cycles.
  List<List<String>> waves() {
    final byId = {for (final n in _nodes) n.id: n};
    for (final n in _nodes) {
      for (final dep in n.dependsOn) {
        if (!byId.containsKey(dep)) {
          throw StateError('Unknown dependency "${n.id}" -> "$dep"');
        }
      }
    }
    final remaining = Map<String, TaskNode>.from(byId);
    final done = <String>{};
    final waves = <List<String>>[];
    while (remaining.isNotEmpty) {
      final ready = remaining.values
          .where((n) => n.dependsOn.every(done.contains))
          .map((n) => n.id)
          .toList()
        ..sort();
      if (ready.isEmpty) {
        throw StateError('Dependency cycle in task graph');
      }
      waves.add(ready);
      for (final id in ready) {
        done.add(id);
        remaining.remove(id);
      }
    }
    return waves;
  }
}

/// Outcome of a single node execution.
class TaskResult {
  const TaskResult({
    required this.taskId,
    required this.agentId,
    required this.output,
    required this.success,
    this.error,
    this.durationMs = 0,
  });

  final String taskId;
  final String agentId;
  final String output;
  final bool success;
  final String? error;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'agent_id': agentId,
        'output': output,
        'success': success,
        if (error != null) 'error': error,
        'duration_ms': durationMs,
      };
}

/// Final outcome of a [TeamOrchestrator.run].
class TeamRunResult {
  const TeamRunResult({
    required this.results,
    required this.synthesis,
    required this.blackboard,
  });

  final List<TaskResult> results;
  final String synthesis;
  final Map<String, Object?> blackboard;

  bool get allSucceeded => results.every((r) => r.success);

  Map<String, dynamic> toJson() => {
        'results': results.map((r) => r.toJson()).toList(),
        'synthesis': synthesis,
        'all_succeeded': allSucceeded,
      };
}

/// Signature of the node executor injected by the host. Receives the agent
/// that runs the node, the node itself (prompt already augmented with
/// dependency context) and the blackboard for optional side-channel reads.
typedef NodeExecutor = Future<String> Function(
  AgentSpec agent,
  TaskNode node,
  Blackboard blackboard,
);

/// Signature of the optional LLM-backed synthesis step. Receives the goal
/// and all node outputs in wave order.
typedef Synthesizer = Future<String> Function(
  String goal,
  List<TaskResult> results,
);

/// Coordinates a team of agents over a task graph.
///
/// Execution model:
/// 1. [TaskGraph.waves] splits nodes into dependency-ordered waves.
/// 2. Within a wave, nodes run concurrently, capped at [maxConcurrency].
/// 3. Each node's prompt is prefixed with its dependencies' outputs from
///    the [Blackboard].
/// 4. Node outputs are written back to the blackboard (`result:<id>`).
/// 5. A synthesis step joins all outputs; deterministic join when no
///    [synthesizer] is configured.
class TeamOrchestrator {
  TeamOrchestrator({
    required this.executor,
    required this.registry,
    this.synthesizer,
    this.maxConcurrency = 4,
    this.defaultAgentId,
  }) {
    if (maxConcurrency < 1) {
      throw ArgumentError('maxConcurrency must be >= 1');
    }
  }

  final NodeExecutor executor;
  final AgentRegistry registry;
  final Synthesizer? synthesizer;
  final int maxConcurrency;
  final String? defaultAgentId;

  Future<TeamRunResult> run(TaskGraph graph, {String goal = ''}) async {
    final blackboard = Blackboard();
    final results = <TaskResult>[];
    for (final wave in graph.waves()) {
      final waveResults = await _runWave(wave, graph, blackboard);
      results.addAll(waveResults);
    }
    final synthesis = await _synthesize(goal, results);
    return TeamRunResult(
      results: results,
      synthesis: synthesis,
      blackboard: blackboard.snapshot(),
    );
  }

  Future<List<TaskResult>> _runWave(
    List<String> wave,
    TaskGraph graph,
    Blackboard blackboard,
  ) async {
    final byId = {for (final n in graph.nodes) n.id: n};
    final pending = List<TaskNode>.from(wave.map((id) => byId[id]!));
    final out = <TaskResult>[];
    while (pending.isNotEmpty) {
      final batch = pending.take(maxConcurrency).toList();
      pending.removeRange(0, batch.length);
      final settled = await Future.wait(batch.map((node) async {
        final agent = _resolveAgent(node);
        final augmented = TaskNode(
          id: node.id,
          prompt: _augment(node, blackboard),
          agentId: node.agentId,
          dependsOn: node.dependsOn,
          metadata: node.metadata,
        );
        final watch = Stopwatch()..start();
        try {
          final output = await executor(agent, augmented, blackboard);
          watch.stop();
          blackboard.write(Blackboard.resultSlot(node.id), output,
              writer: agent.id);
          return TaskResult(
            taskId: node.id,
            agentId: agent.id,
            output: output,
            success: true,
            durationMs: watch.elapsedMilliseconds,
          );
        } catch (e) {
          watch.stop();
          return TaskResult(
            taskId: node.id,
            agentId: agent.id,
            output: '',
            success: false,
            error: e.toString(),
            durationMs: watch.elapsedMilliseconds,
          );
        }
      }));
      for (final result in settled) {
        blackboard.write(Blackboard.depSlot(result.taskId), result.output,
            writer: 'orchestrator');
      }
      out.addAll(settled);
    }
    return out;
  }

  AgentSpec _resolveAgent(TaskNode node) {
    final explicit = node.agentId ?? defaultAgentId;
    final spec = explicit == null ? null : registry.get(explicit);
    if (spec != null) return spec;
    final any = registry.all;
    if (any.isEmpty) {
      throw StateError('Agent registry is empty; register at least one agent');
    }
    return any.first;
  }

  String _augment(TaskNode node, Blackboard blackboard) {
    if (node.dependsOn.isEmpty) return node.prompt;
    final buffer = StringBuffer('Konteks dari langkah sebelumnya:\n');
    for (final dep in node.dependsOn) {
      final value = blackboard.read(Blackboard.depSlot(dep));
      buffer
        ..writeln('--- hasil $dep ---')
        ..writeln(value is String ? value : jsonEncode(value))
        ..writeln('--- akhir $dep ---');
    }
    buffer
      ..writeln()
      ..writeln('Tugas:')
      ..write(node.prompt);
    return buffer.toString();
  }

  Future<String> _synthesize(String goal, List<TaskResult> results) async {
    final custom = synthesizer;
    if (custom != null) {
      return custom(goal, results);
    }
    final buffer = StringBuffer();
    if (goal.isNotEmpty) buffer.writeln('Tujuan: $goal');
    for (final r in results) {
      buffer
        ..writeln('[${r.taskId} via ${r.agentId}]')
        ..writeln(r.success ? r.output : 'GAGAL: ${r.error}');
    }
    return buffer.toString().trim();
  }
}
