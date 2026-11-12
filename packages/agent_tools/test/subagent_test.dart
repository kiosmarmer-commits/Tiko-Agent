import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/src/subagent.dart';
import 'package:test/test.dart';

void main() {
  group('SubagentBudget', () {
    test('default budget values', () {
      const budget = SubagentBudget();
      expect(budget.maxTokens, 4000);
      expect(budget.maxTimeSeconds, 120);
      expect(budget.maxToolCalls, 10);
      expect(budget.maxCost, 0.5);
    });

    test('custom budget values', () {
      const budget = SubagentBudget(
        maxTokens: 10000,
        maxTimeSeconds: 300,
        maxToolCalls: 50,
        maxCost: 2.0,
      );
      expect(budget.maxTokens, 10000);
      expect(budget.maxTimeSeconds, 300);
      expect(budget.maxToolCalls, 50);
      expect(budget.maxCost, 2.0);
    });

    test('toJson serialization', () {
      const budget = SubagentBudget(
        maxTokens: 2000,
        maxTimeSeconds: 60,
        maxToolCalls: 5,
        maxCost: 1.0,
      );
      final json = budget.toJson();
      expect(json['max_tokens'], 2000);
      expect(json['max_time_seconds'], 60);
      expect(json['max_tool_calls'], 5);
      expect(json['max_cost'], 1.0);
    });
  });

  group('SubagentResult', () {
    test('success result', () {
      final result = const SubagentResult(
        success: true,
        output: 'Task completed successfully',
        subagentId: 'sub-1',
        parentId: 'parent-1',
      );
      expect(result.success, isTrue);
      expect(result.output, 'Task completed successfully');
      expect(result.error, isNull);
      expect(result.subagentId, 'sub-1');
      expect(result.parentId, 'parent-1');
    });

    test('failure result', () {
      final result = const SubagentResult(
        success: false,
        output: '',
        error: 'Task failed',
        subagentId: 'sub-1',
        parentId: 'parent-1',
      );
      expect(result.success, isFalse);
      expect(result.output, '');
      expect(result.error, 'Task failed');
    });

    test('toJson serialization', () {
      final result = SubagentResult(
        success: true,
        output: 'Done',
        tokenCount: 100,
        timeSeconds: 1.5,
        toolCallCount: 3,
        cost: 0.1,
        subagentId: 'sub-1',
        parentId: 'parent-1',
        startedAt: DateTime.utc(2026, 1, 1),
        completedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
      final json = result.toJson();
      expect(json['success'], isTrue);
      expect(json['output'], 'Done');
      expect(json['token_count'], 100);
      expect(json['time_seconds'], 1.5);
      expect(json['tool_call_count'], 3);
      expect(json['cost'], 0.1);
      expect(json['subagent_id'], 'sub-1');
      expect(json['parent_id'], 'parent-1');
    });

    test('toSummary for success', () {
      final result = const SubagentResult(
        success: true,
        output: 'This is a long output that should be truncated',
      );
      final summary = result.toSummary();
      expect(summary, contains('sukses'));
      expect(summary.length, lessThan(150));
    });

    test('toSummary for failure', () {
      final result = const SubagentResult(
        success: false,
        output: 'Error occurred',
      );
      final summary = result.toSummary();
      expect(summary, contains('gagal'));
    });
  });

  group('SpawnSubagentTool', () {
    test('rejects empty goal', () async {
      final tool = SpawnSubagentTool();
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': ''}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('goal wajib'));
    });

    test('rejects when max depth reached', () async {
      final tool = SpawnSubagentTool(maxDepth: 2);
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      // Set depth to max
      SpawnSubagentTool.setDepth(session, 2);
      
      final result = await tool.run({'goal': 'test goal'}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('Batas kedalaman'));

      // Reset so later tests sharing session id 'test' start at depth 0.
      SpawnSubagentTool.setDepth(session, 0);
    });

    test('rejects when max subagents reached', () async {
      final tool = SpawnSubagentTool(maxDepth: 2, maxSubagents: 2);
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      // Register 2 subagents (max)
      SpawnSubagentTool.registerSubagent('sub-1');
      SpawnSubagentTool.registerSubagent('sub-2');
      
      try {
        final result = await tool.run({'goal': 'test goal'}, ctx);
        expect(result.isError, isTrue);
        expect(result.content, contains('Batas jumlah subagent'));
      } finally {
        // Clean up
        SpawnSubagentTool.unregisterSubagent('sub-1');
        SpawnSubagentTool.unregisterSubagent('sub-2');
      }
    });

    test('parses budget from arguments', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        defaultBudget: const SubagentBudget(
          maxTokens: 4000,
          maxTimeSeconds: 120,
          maxToolCalls: 10,
          maxCost: 0.5,
        ),
      );
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      // Without a runner, it should return SUBAGENT_REQUEST
      final result = await tool.run(
        {
          'goal': 'test goal',
          'budget': {
            'max_tokens': 2000,
            'max_time_seconds': 60,
            'max_tool_calls': 5,
            'max_cost': 0.25,
          },
        },
        ctx,
      );
      
      // Should not throw, and should return SUBAGENT_REQUEST
      expect(result.isError, isFalse);
      expect(result.content, contains('SUBAGENT_REQUEST'));
    });

    test('parses allowed tools from arguments', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        defaultAllowedTools: const {'read_file', 'list_dir'},
      );
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run(
        {
          'goal': 'test goal',
          'allowed_tools': ['read_file', 'grep'],
        },
        ctx,
      );
      
      expect(result.isError, isFalse);
      expect(result.content, contains('SUBAGENT_REQUEST'));
    });

    test('active subagent tracking', () {
      expect(SpawnSubagentTool.activeSubagentCount(), 0);
      
      SpawnSubagentTool.registerSubagent('sub-1');
      expect(SpawnSubagentTool.activeSubagentCount(), 1);
      
      SpawnSubagentTool.registerSubagent('sub-2');
      expect(SpawnSubagentTool.activeSubagentCount(), 2);
      
      SpawnSubagentTool.unregisterSubagent('sub-1');
      expect(SpawnSubagentTool.activeSubagentCount(), 1);
      
      SpawnSubagentTool.unregisterSubagent('sub-2');
      expect(SpawnSubagentTool.activeSubagentCount(), 0);
    });

    test('registerSubagent fails when limit reached', () {
      // Max 4 subagents
      SpawnSubagentTool.registerSubagent('sub-1');
      SpawnSubagentTool.registerSubagent('sub-2');
      SpawnSubagentTool.registerSubagent('sub-3');
      SpawnSubagentTool.registerSubagent('sub-4');
      
      expect(SpawnSubagentTool.registerSubagent('sub-5'), isFalse);
      expect(SpawnSubagentTool.activeSubagentCount(), 4);
      
      // Clean up
      SpawnSubagentTool.unregisterSubagent('sub-1');
      SpawnSubagentTool.unregisterSubagent('sub-2');
      SpawnSubagentTool.unregisterSubagent('sub-3');
      SpawnSubagentTool.unregisterSubagent('sub-4');
    });
  });

  group('SubagentBudget validation in SpawnSubagentTool', () {
    test('with runner, respects budget limits', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) async {
          // Simulate a subagent that uses too many tokens
          return SubagentResult(
            success: true,
            output: 'A' * 10000, // 10000 tokens
            tokenCount: 10000,
            timeSeconds: 1.0,
            toolCallCount: 0,
            cost: 0.0,
          );
        },
        defaultBudget: const SubagentBudget(
          maxTokens: 5000, // Less than what the runner returns
        ),
      );
      
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': 'test'}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('melebihi batas token'));
    });

    test('with runner, respects time limit', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) async {
          // Simulate a subagent that takes too long
          return const SubagentResult(
            success: true,
            output: 'Done',
            tokenCount: 100,
            timeSeconds: 200.0, // 200 seconds
            toolCallCount: 0,
            cost: 0.0,
          );
        },
        defaultBudget: const SubagentBudget(
          maxTimeSeconds: 60, // Less than what the runner returns
        ),
      );
      
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': 'test'}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('melebihi batas waktu'));
    });

    test('with runner, respects tool call limit', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) async {
          // Simulate a subagent that makes too many tool calls
          return const SubagentResult(
            success: true,
            output: 'Done',
            tokenCount: 100,
            timeSeconds: 1.0,
            toolCallCount: 20, // 20 tool calls
            cost: 0.0,
          );
        },
        defaultBudget: const SubagentBudget(
          maxToolCalls: 10, // Less than what the runner returns
        ),
      );
      
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': 'test'}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('melebihi batas tool calls'));
    });

    test('with runner, respects cost limit', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) async {
          // Simulate a subagent that costs too much
          return const SubagentResult(
            success: true,
            output: 'Done',
            tokenCount: 100,
            timeSeconds: 1.0,
            toolCallCount: 1,
            cost: 5.0, // $5.00
          );
        },
        defaultBudget: const SubagentBudget(
          maxCost: 1.0, // Less than what the runner returns
        ),
      );
      
      final session = Session(id: 'test', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': 'test'}, ctx);
      expect(result.isError, isTrue);
      expect(result.content, contains('melebihi batas biaya'));
    });

    test('with runner, returns structured result on success', () async {
      final tool = SpawnSubagentTool(
        maxDepth: 2,
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) async {
          return SubagentResult(
            success: true,
            output: 'Task completed',
            tokenCount: 100,
            timeSeconds: 1.5,
            toolCallCount: 2,
            cost: 0.1,
            subagentId: 'sub-1',
            parentId: parent.id,
            startedAt: DateTime.now(),
            completedAt: DateTime.now(),
          );
        },
      );
      
      final session = Session(id: 'parent-1', channel: 'cli', userKey: 'user');
      final ctx = ToolContext(session: session, workspacePath: '.');
      
      final result = await tool.run({'goal': 'test'}, ctx);
      expect(result.isError, isFalse);
      expect(result.content, contains('sukses'));
      expect(result.content, contains('<subagent_result>'));
      expect(result.content, contains('"success":true'));
      expect(result.content, contains('subagent_id'));
    });
  });
}
