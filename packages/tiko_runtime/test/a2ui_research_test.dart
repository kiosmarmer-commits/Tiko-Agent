import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

ResearchRunRecord record({
  String runId = 'rlx1abc',
  String status = 'ok',
  String? error,
  List<String> queries = const ['apa itu a2ui', 'katalog tiko'],
}) =>
    ResearchRunRecord(
      runId: runId,
      question: 'Ringkas ekosistem a2ui?',
      status: status,
      startedAt: DateTime.utc(2026, 11, 22, 10),
      finishedAt: DateTime.utc(2026, 11, 22, 10, 5),
      summary: 'ringkasan',
      reportName: 'riset-rlx1abc.md',
      kanbanTaskId: 'task-1',
      queries: queries,
      tokensUsed: 1234,
      toolCallCount: 7,
      error: error,
    );

void main() {
  test('surface riset valid: parse + apply ke A2uiSurfaceSet', () {
    final msgs = researchRunSurfaceMessages(record());
    expect(msgs, hasLength(1));
    final set = A2uiSurfaceSet()..apply(msgs);
    final surface = set.surface('research-rlx1abc');
    expect(surface, isNotNull);
    expect(
      surface!.components['head']!.properties['text'],
      'Riset: Ringkas ekosistem a2ui?',
    );
    expect(surface.components['m-status']!.properties['value'], 'ok');
    expect(
        surface.components.containsKey('m-status') &&
            surface.components['m-status']!.properties.containsKey('tone'),
        isFalse);
    expect(surface.components['m-tokens']!.properties['value'], 1234);
    expect(surface.components['q0']!.properties['text'], '1. apa itu a2ui');
    expect(
      surface.components['rep']!.properties['text'],
      'data/research/reports/riset-rlx1abc.md',
    );
    expect(surface.components.containsKey('err'), isFalse);
  });

  test('run gagal: metric status tone error + teks error muncul', () {
    final msgs = researchRunSurfaceMessages(
      record(status: 'failed', error: 'planner timeout'),
    );
    final set = A2uiSurfaceSet()..apply(msgs);
    final surface = set.surface('research-rlx1abc')!;
    expect(
      surface.components['m-status']!.properties['tone'],
      'error',
    );
    expect(surface.components['err']!.properties['text'], 'Gagal: planner timeout');
  });

  test('runId dengan karakter liar disanitasi; surfaceId tetap valid', () {
    final msgs = researchRunSurfaceMessages(record(runId: 'r/..b c'));
    final set = A2uiSurfaceSet()..apply(msgs);
    expect(set.surface('research-r_..b_c'), isNotNull);
  });

  test('question panjang dipotong; queries hanya 6 pertama', () {
    final msgs = researchRunSurfaceMessages(ResearchRunRecord(
      runId: 'rr',
      question: 'x' * 500,
      status: 'ok',
      startedAt: DateTime.utc(2026, 11, 22, 10),
      finishedAt: DateTime.utc(2026, 11, 22, 10, 5),
      summary: 'ringkasan',
      reportName: 'riset-rr.md',
      kanbanTaskId: 'task-1',
      queries: [for (var i = 0; i < 9; i++) 'q$i'],
      tokensUsed: 1,
      toolCallCount: 1,
    ));
    final set = A2uiSurfaceSet()..apply(msgs);
    final surface = set.surface('research-rr')!;
    final head = surface.components['head']!.properties['text'] as String;
    expect(head, startsWith('Riset: '));
    expect(head.length, 127);
    expect(surface.components.containsKey('q6'), isFalse);
    for (var i = 0; i < 6; i++) {
      expect(surface.components['q$i'], isNotNull);
    }
  });

  test('ingest bridge menerima surface riset + snapshot tersimpan', () async {
    final dir = await Directory.systemTemp.createTemp('tiko-a2ui-research');
    addTearDown(() => dir.delete(recursive: true));
    final bridge = A2uiToolBridge(dataDir: dir.path);
    final changes = bridge.ingest('demo:sesi', researchRunSurfaceMessages(record()));
    expect(changes.single.event, 'surface.created');
    expect(
      bridge
          .sessionSet('demo:sesi')
          .surface('research-rlx1abc')!
          .components,
      containsPair('head', isNotNull),
    );
  });
}
