import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('CancellationToken', () {
    test('cancel idempotent dan whenCancelled selesai', () async {
      final t = CancellationToken();
      expect(t.isCancelled, isFalse);
      await t.guard(Future.value('ok'));
      t.cancel();
      t.cancel();
      expect(t.isCancelled, isTrue);
      await t.whenCancelled;
    });

    test('throwIfCancelled melempar setelah cancel', () {
      final t = CancellationToken();
      expect(t.throwIfCancelled, returnsNormally);
      t.cancel();
      expect(t.throwIfCancelled, throwsA(isA<OperationCancelledException>()));
    });

    test('guard melempar cancellation saat token dibatalkan di tengah aksi',
        () async {
      final t = CancellationToken();
      final slow = Completer<String>();
      final raced = t.guard(slow.future);
      t.cancel();
      await expectLater(raced, throwsA(isA<OperationCancelledException>()));
      // Underlying work still completes in the background (cooperative).
      slow.complete('late');
    });

    test('guard meneruskan error asli saat tidak dibatalkan', () async {
      final t = CancellationToken();
      await expectLater(
        t.guard(Future<void>.error(StateError('boom'))),
        throwsA(isA<StateError>()),
      );
    });

    test('guard menolak segera bila token sudah dibatalkan', () async {
      final t = CancellationToken()..cancel();
      await expectLater(
        t.guard(Future.value('never')),
        throwsA(isA<OperationCancelledException>()),
      );
    });
  });

  group('CancellationRegistry', () {
    test('begin membuat token baru; cancel membatalkan yang hidup', () {
      final r = CancellationRegistry();
      final t1 = r.begin('s1');
      expect(r.cancel('s1'), isTrue);
      expect(t1.isCancelled, isTrue);
      expect(r.cancel('s1'), isFalse);
    });

    test('begin mengganti token lama dengan yang baru', () {
      final r = CancellationRegistry();
      final t1 = r.begin('s1');
      r.cancel('s1');
      final t2 = r.begin('s1');
      expect(t2.isCancelled, isFalse);
      expect(identical(t1, t2), isFalse);
    });

    test('tokenOf mengembalikan token hidup, cancelAll membatalkan semua',
        () {
      final r = CancellationRegistry();
      final a = r.begin('a');
      final b = r.begin('b');
      expect(r.tokenOf('a'), same(a));
      r.cancelAll();
      expect(a.isCancelled, isTrue);
      expect(b.isCancelled, isTrue);
      expect(r.tokenOf('a'), isNull);
    });
  });

  group('ToolContext.cancelToken', () {
    test('token terlihat oleh tool lewat context', () async {
      final t = CancellationToken();
      final ctx = ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: '.',
        cancelToken: t,
      );
      expect(ctx.cancelToken, same(t));
      t.cancel();
      expect(ctx.cancelToken!.isCancelled, isTrue);
    });
  });

  group('TeamOrchestrator cancellation', () {
    AgentRegistry registry() {
      final r = AgentRegistry()
        ..register(const AgentSpec(
          id: 'planner',
          role: AgentRole.planner,
          systemPrompt: 'pecah tujuan jadi langkah',
        ))
        ..register(const AgentSpec(
          id: 'coder',
          role: AgentRole.coder,
          systemPrompt: 'tulis kode',
        ));
      return r;
    }

    TaskGraph graph() => TaskGraph()
      ..add(const TaskNode(id: 'plan', prompt: 'rencana', agentId: 'planner'))
      ..add(const TaskNode(
        id: 'code',
        prompt: 'implementasi',
        agentId: 'coder',
        dependsOn: ['plan'],
      ));

    test('node yang berjalan saat cancel dihentikan dan dependen dilewati',
        () async {
      final token = CancellationToken();
      final orch = TeamOrchestrator(
        registry: registry(),
        executor: (agent, node, blackboard) async {
          if (node.id == 'plan') {
            token.cancel();
            // Node keeps working briefly (cooperative drain), but the
            // orchestrator must stop waiting for it.
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return 'output-${node.id}';
        },
      );
      final result = await orch.run(graph(), goal: 'g', cancelToken: token);
      final plan = result.results.firstWhere((r) => r.taskId == 'plan');
      final code = result.results.firstWhere((r) => r.taskId == 'code');
      expect(plan.success, isFalse);
      expect(plan.error, contains('cancel'));
      expect(code.success, isFalse);
      expect(code.error, contains('cancel'));
    });

    test('token yang sudah dibatalkan menjalankan nol node', () async {
      final token = CancellationToken()..cancel();
      var executed = 0;
      final orch = TeamOrchestrator(
        registry: registry(),
        executor: (agent, node, blackboard) async {
          executed++;
          return 'x';
        },
      );
      final result = await orch.run(graph(), goal: 'g', cancelToken: token);
      expect(executed, 0);
      expect(result.results.every((r) => r.success == false), isTrue);
    });

    test('tanpa cancelToken perilaku tidak berubah', () async {
      final orch = TeamOrchestrator(
        registry: registry(),
        executor: (agent, node, blackboard) async => 'output-${node.id}',
      );
      final result = await orch.run(graph(), goal: 'g');
      expect(result.results.every((r) => r.success), isTrue);
    });
  });
}
