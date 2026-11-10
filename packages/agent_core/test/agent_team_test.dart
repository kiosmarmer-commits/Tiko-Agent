import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  AgentRegistry registry() {
    final r = AgentRegistry()
      ..register(const AgentSpec(
        id: 'planner',
        role: AgentRole.planner,
        systemPrompt: 'pecah tujuan jadi langkah',
      ))
      ..register(const AgentSpec(
        id: 'researcher',
        role: AgentRole.researcher,
        systemPrompt: 'kumpulkan fakta',
        toolAllowlist: ['web_search'],
      ))
      ..register(const AgentSpec(
        id: 'coder',
        role: AgentRole.coder,
        systemPrompt: 'tulis kode',
      ));
    return r;
  }

  TaskGraph sampleGraph() => TaskGraph()
    ..add(const TaskNode(id: 'plan', prompt: 'buat rencana',
        agentId: 'planner'))
    ..add(const TaskNode(id: 'research', prompt: 'cari data',
        agentId: 'researcher'))
    ..add(const TaskNode(id: 'code', prompt: 'implementasi',
        agentId: 'coder', dependsOn: ['plan', 'research']));

  test('waves order independent nodes together and dependents after', () {
    final waves = sampleGraph().waves();
    expect(waves.length, 2);
    expect(waves[0], containsAll(['plan', 'research']));
    expect(waves[1], ['code']);
  });

  test('cycle detection throws', () {
    final g = TaskGraph()
      ..add(const TaskNode(id: 'a', prompt: 'a', dependsOn: ['b']))
      ..add(const TaskNode(id: 'b', prompt: 'b', dependsOn: ['a']));
    expect(() => g.waves(), throwsStateError);
  });

  test('unknown dependency throws', () {
    final g = TaskGraph()
      ..add(const TaskNode(id: 'a', prompt: 'a', dependsOn: ['ghost']));
    expect(() => g.waves(), throwsStateError);
  });

  test('duplicate task id rejected', () {
    final g = TaskGraph()
      ..add(const TaskNode(id: 'a', prompt: 'a'));
    expect(() => g.add(const TaskNode(id: 'a', prompt: 'a')),
        throwsArgumentError);
  });

  test('parallel execution of independent nodes', () async {
    var concurrent = 0;
    var peak = 0;
    final orch = TeamOrchestrator(
      registry: registry(),
      maxConcurrency: 2,
      executor: (agent, node, board) async {
        concurrent++;
        if (concurrent > peak) peak = concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        concurrent--;
        return '${agent.id}:${node.id}';
      },
    );
    final result = await orch.run(sampleGraph());
    expect(peak, 2);
    expect(result.results.length, 3);
    expect(result.allSucceeded, isTrue);
    expect(result.blackboard[Blackboard.resultSlot('plan')], 'planner:plan');
  });

  test('dependent node receives upstream context in prompt', () async {
    TaskNode? captured;
    final orch = TeamOrchestrator(
      registry: registry(),
      maxConcurrency: 4,
      executor: (agent, node, board) async {
        if (node.id == 'code') captured = node;
        return 'ok:${node.id}';
      },
    );
    await orch.run(sampleGraph());
    expect(captured, isNotNull);
    expect(captured!.prompt, contains('--- hasil plan ---'));
    expect(captured!.prompt, contains('ok:plan'));
    expect(captured!.prompt, contains('ok:research'));
  });

  test('executor failure is captured, not thrown', () async {
    final orch = TeamOrchestrator(
      registry: registry(),
      executor: (agent, node, board) async {
        if (node.id == 'research') throw Exception('boom');
        return 'fine';
      },
    );
    final result = await orch.run(sampleGraph());
    final failed = result.results.firstWhere((r) => r.taskId == 'research');
    expect(failed.success, isFalse);
    expect(failed.error, contains('boom'));
    expect(result.allSucceeded, isFalse);
  });

  test('deterministic synthesis joins outputs when no synthesizer', () async {
    final orch = TeamOrchestrator(
      registry: registry(),
      executor: (agent, node, board) async => 'out-${node.id}',
    );
    final result = await orch.run(sampleGraph(), goal: 'uji');
    expect(result.synthesis, contains('Tujuan: uji'));
    expect(result.synthesis, contains('out-plan'));
    expect(result.synthesis, contains('out-research'));
    expect(result.synthesis, contains('out-code'));
  });

  test('custom synthesizer is used when provided', () async {
    final orch = TeamOrchestrator(
      registry: registry(),
      executor: (agent, node, board) async => 'x',
      synthesizer: (goal, results) async =>
          'gabungan ${results.length} hasil untuk $goal',
    );
    final result = await orch.run(sampleGraph(), goal: 'uji');
    expect(result.synthesis, 'gabungan 3 hasil untuk uji');
  });

  test('empty registry without explicit agent throws', () async {
    final orch = TeamOrchestrator(
      registry: AgentRegistry(),
      executor: (agent, node, board) async => 'x',
    );
    final g = TaskGraph()..add(const TaskNode(id: 'a', prompt: 'a'));
    expect(() => orch.run(g), throwsStateError);
  });

  test('json round trip for AgentSpec and TaskNode', () {
    const spec = AgentSpec(id: 'critic', role: AgentRole.critic,
        systemPrompt: 'review');
    final spec2 = AgentSpec.fromJson(spec.toJson());
    expect(spec2.id, 'critic');
    expect(spec2.role, AgentRole.critic);

    const node = TaskNode(id: 't1', prompt: 'p', agentId: 'critic',
        dependsOn: ['t0']);
    final node2 = TaskNode.fromJson(node.toJson());
    expect(node2.id, 't1');
    expect(node2.agentId, 'critic');
    expect(node2.dependsOn, ['t0']);
  });
}
