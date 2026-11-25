import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Mission Control (swarm mode) — registri live run orkestra tim: lifecycle
/// event → snapshot JSON, pembatalan kooperatif per run, evict bounded, dan
/// truncation tail output node.
void main() {
  group('SwarmControl', () {
    test('lifecycle penuh: planning → running → node → finished', () {
      final sc = SwarmControl();
      sc.startRun(runId: 'r1', teamId: 'paket-ui', goal: 'Buat fitur X');
      expect(sc.get('r1')!.status, 'planning');

      sc.setPlanned(runId: 'r1', nodeIds: const ['n1', 'n2']);
      expect(sc.get('r1')!.status, 'running');
      expect(sc.get('r1')!.nodes.map((n) => n.id), containsAll(['n1', 'n2']));

      sc.nodeStarted('r1', 'n1', 'coder');
      sc.nodeFinished('r1', 'n1', ok: true, output: 'selesai koding');
      final node1 = sc.get('r1')!.nodes.first;
      expect(node1.status, 'ok');
      expect(node1.agentId, 'coder');
      expect(node1.outputTail, 'selesai koding');
      expect(node1.finishedAt, isNotNull);

      sc.nodeFinished('r1', 'n2', ok: false, error: 'boom');
      expect(sc.get('r1')!.nodes.last.status, 'failed');
      expect(sc.get('r1')!.nodes.last.error, 'boom');

      sc.runFinished('r1', success: false);
      expect(sc.get('r1')!.status, 'failed');
      expect(sc.get('r1')!.finishedAt, isNotNull);

      final snap = sc.snapshot();
      expect(snap, hasLength(1));
      expect(snap.first['run_id'], 'r1');
      expect(snap.first['status'], 'failed');
    });

    test('setPlanned menyusun ulang node sesuai urutan DAG planner', () {
      final sc = SwarmControl();
      sc.startRun(runId: 'r1', teamId: 't', goal: 'g');
      sc.setPlanned(runId: 'r1', nodeIds: const ['n1', 'n2']);
      sc.nodeStarted('r1', 'n1', 'coder');
      // Replan: node yang sudah berjalan tidak direset saat disusun ulang.
      sc.setPlanned(runId: 'r1', nodeIds: const ['b', 'n1']);
      final run = sc.get('r1')!;
      expect(run.nodes.map((n) => n.id).toList(), ['b', 'n1']);
      expect(run.nodes[0].status, 'pending');
      expect(run.nodes[1].status, 'running');
      expect(run.nodes[1].agentId, 'coder');
    });

    test('runFinished menandai node stale sebagai cancelled', () {
      final sc = SwarmControl();
      sc.startRun(runId: 'r1', teamId: 't', goal: 'g');
      sc.setPlanned(runId: 'r1', nodeIds: const ['n1', 'n2', 'n3']);
      sc.nodeStarted('r1', 'n1', 'coder');
      sc.runFinished('r1', success: false, cancelled: true);
      expect(sc.get('r1')!.status, 'cancelled');
      expect(sc.get('r1')!.nodes.map((n) => n.status), everyElement('cancelled'));
    });

    test('cancelRun: hanya run aktif, mengembalikan sessionIds', () {
      final sc = SwarmControl();
      sc.startRun(runId: 'r1', teamId: 't', goal: 'g');
      sc.setPlanned(runId: 'r1', nodeIds: const ['n1']);
      sc.trackSession('r1', 'team:paket-ui:coder:1');
      sc.trackSession('r1', 'team:paket-ui:planner:2');

      expect(sc.cancelRun('tidak-ada'), isNull);

      final sessions = sc.cancelRun('r1');
      expect(sessions, containsAll(['team:paket-ui:coder:1']));
      expect(sc.get('r1')!.status, 'cancelling');

      // Idempoten: pengulangan tetap aman (sesi sama dikembalikan lagi).
      expect(sc.cancelRun('r1'), sessions);
    });

    test('output tail dipotong ke maxNodeOutputTail karakter terakhir', () {
      final sc = SwarmControl(maxNodeOutputTail: 10);
      sc.startRun(runId: 'r1', teamId: 't', goal: 'g');
      sc.setPlanned(runId: 'r1', nodeIds: const ['n1']);
      final long = [for (var i = 0; i < 100; i++) i.toString()].join();
      sc.nodeFinished('r1', 'n1', ok: true, output: long);
      expect(sc.get('r1')!.nodes.first.outputTail!.length, 10);
    });

    test('evict: run non-aktif tertua diusir saat registri penuh', () {
      final sc = SwarmControl(maxRuns: 3);
      sc.startRun(runId: 'r1', teamId: 't', goal: 'g');
      sc.startRun(runId: 'r2', teamId: 't', goal: 'g');
      sc.runFinished('r2', success: true); // r2 selesai → kandidat evict
      sc.startRun(runId: 'r3', teamId: 't', goal: 'g');
      sc.startRun(runId: 'r4', teamId: 't', goal: 'g');
      // r1 masih planning (aktif) bertahan; r2 selesai tertua diusir.
      expect(sc.get('r1'), isNotNull);
      expect(sc.get('r2'), isNull);
      expect(sc.get('r3'), isNotNull);
      expect(sc.get('r4'), isNotNull);
    });

    test('activeRuns hanya running/cancelling, snapshot terbaru dulu', () {
      final sc = SwarmControl();
      sc.startRun(runId: 'a', teamId: 't', goal: 'g');
      sc.runFinished('a', success: true);
      sc.startRun(runId: 'b', teamId: 't', goal: 'g');
      sc.setPlanned(runId: 'b', nodeIds: const ['n']);
      expect(sc.activeRuns.map((r) => r.runId), ['b']);
      expect(sc.snapshot().map((r) => r['run_id']).toList(), ['b', 'a']);
    });
  });
}
