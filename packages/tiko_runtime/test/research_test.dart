import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Fase D — test riset otomatis: parser rencana, runner pipeline
/// (plan → gather → sintesis → review), cerminkan kanban, store run,
/// dan tool deep_research / schedule_research.

ChatRunResult _turn(String text, {bool success = true}) => ChatRunResult(
  text: text,
  success: success,
  tokensUsed: 7,
  toolCallCount: 2,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko-research-test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('parseResearchPlan', () {
    test('JSON murni valid → queries planner', () {
      final plan = parseResearchPlan(
        jsonEncode({
          'queries': ['sisir A', 'sisir B'],
        }),
      );
      expect(plan, isNotNull);
      expect(plan!.source, 'planner');
      expect(plan.queries, ['sisir A', 'sisir B']);
    });

    test('JSON dalam code fence + prose', () {
      final plan = parseResearchPlan(
        'Berikut rencananya:\n```json\n'
        '{"queries":[{"query":"q1"},{"query":"q2"}]}\n```\n',
      );
      expect(plan!.queries, ['q1', 'q2']);
    });

    test('fallback: tanpa JSON valid → null', () {
      expect(parseResearchPlan('hanya prose tanpa json'), isNull);
      expect(parseResearchPlan('{"queries":[]}'), isNull);
    });

    test('dedupe + kosong + cap 6', () {
      final plan = parseResearchPlan(
        jsonEncode({
          'queries': ['a', 'a', ' ', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
        }),
      );
      expect(plan!.queries.length, 6);
      expect(plan.queries, ['a', 'b', 'c', 'd', 'e', 'f']);
    });
  });

  group('ResearchRunner', () {
    test('pipeline penuh: plan → gather paralel → sintesis → review', () async {
      final events = <String>[];
      final runner = ResearchRunner(
        plannerTurn: (prompt) {
          expect(prompt, contains('Pertanyaan riset'));
          return Future.value(
            _turn('```json\n{"queries":["q1","q2","q3"]}\n```'),
          );
        },
        researcherTurn: (slot, prompt) {
          if (slot.startsWith('q')) {
            return Future.value(_turn('temuan $slot: [sumber web]'));
          }
          if (slot == '__synthesis') {
            expect(
              prompt,
              contains('temuan q1'),
              reason: 'prompt sintesis membawa temuan sub-riset',
            );
            expect(prompt, contains('temuan q3'));
            return Future.value(
              _turn(
                '## Ringkasan\n- inti riset\n\n## Temuan\n...\n\n'
                '## Kesimpulan\njawaban\n\n## Sumber\n- http://contoh\n',
              ),
            );
          }
          if (slot == '__review') return Future.value(_turn('LAPORAN_OK'));
          throw StateError('slot tidak dikenal: $slot');
        },
        maxConcurrency: 3,
        emitEvent: (type, data) => events.add(type),
      );
      final res = await runner.run(question: 'pertanyaan riset');
      expect(res.success, isTrue);
      expect(res.queries, ['q1', 'q2', 'q3']);
      expect(res.summary, contains('inti riset'));
      expect(res.report, contains('## Sumber'));
      expect(res.report.contains('## Catatan Review'), isFalse);
      expect(res.tokensUsed, 7 * 6);
      expect(res.toolCallCount, 12);
      expect(events.first, 'research.started');
      expect(events[1], 'research.planned');
      expect(events.where((e) => e == 'research.gather_done').length, 3);
      expect(events.where((e) => e == 'research.gather_started').length, 3);
      expect(events.contains('research.gather_failed'), isFalse);
      expect(events.last, 'research.finished');
      expect(events.contains('review_failed'), isFalse);
    });

    test('planner gagal → fallback satu query', () async {
      final runner = ResearchRunner(
        plannerTurn: (prompt) => Future.value(_turn('bukan json')),
        researcherTurn: (slot, prompt) async {
          if (slot == 'q1') return _turn('temuan umum');
          if (slot == '__synthesis') return _turn('## Ringkasan\nok');
          if (slot == '__review') return _turn('LAPORAN_OK');
          throw StateError(slot);
        },
      );
      final res = await runner.run(question: 'asal');
      expect(res.queries, ['asal']);
    });

    test('review memberi catatan → bagian Catatan Review', () async {
      final runner = ResearchRunner(
        plannerTurn: (prompt) => Future.value(_turn('{"queries":["q"]}')),
        researcherTurn: (slot, prompt) async {
          if (slot == '__synthesis') return _turn('## Ringkasan\nx');
          if (slot == '__review') return _turn('- klaim tanpa sumber: x');
          if (slot == 'q1') return _turn('t');
          throw StateError(slot);
        },
      );
      final res = await runner.run(question: 'asal');
      expect(res.success, isTrue);
      expect(res.report, contains('## Catatan Review'));
    });

    test('sintesis gagal → success false + error', () async {
      final runner = ResearchRunner(
        plannerTurn: (prompt) => Future.value(_turn('{"queries":["q"]}')),
        researcherTurn: (slot, prompt) async {
          if (slot == '__synthesis') throw StateError('boom');
          if (slot == 'q1') return _turn('t');
          throw StateError(slot);
        },
      );
      final res = await runner.run(question: 'asal');
      expect(res.success, isFalse);
      expect(res.error, contains('boom'));
      expect(res.summary, contains('sintesis gagal'));
    });
  });

  group('ResearchRunStore', () {
    test('append + get + readReport roundtrip', () async {
      final store = ResearchRunStore(dataDir: tmp.path);
      final record = ResearchRunRecord(
        runId: 'r1',
        question: 'pertanyaan',
        status: 'ok',
        startedAt: DateTime.now().toUtc(),
        finishedAt: DateTime.now().toUtc(),
        summary: 'ringkasan',
        reportName: 'riset-r1.md',
        kanbanTaskId: 'kb-1',
        jobId: 'job-9',
        queries: const ['q'],
      );
      await store.append(record);
      expect(
        File(store.reportPath('riset-r1.md')).existsSync(),
        isFalse,
        reason: 'laporan belum disimpan',
      );
      await store.saveReport('r1', 'pertanyaan', '# isi');
      final reloaded = ResearchRunStore(dataDir: tmp.path);
      final got = reloaded.get('r1')!;
      expect(got.question, 'pertanyaan');
      expect(got.jobId, 'job-9');
      expect(got.kanbanTaskId, 'kb-1');
      expect((await reloaded.readReport('riset-r1.md')), contains('# isi'));
    });

    test('indeks korup dilompati', () async {
      final dir = Directory('${tmp.path}/research');
      await dir.create(recursive: true);
      await File('${dir.path}/index.json').writeAsString('{rusak');
      final store = ResearchRunStore(dataDir: tmp.path);
      expect(store.runs, isEmpty);
    });

    test('traversal ditolak fail-closed', () async {
      final store = ResearchRunStore(dataDir: tmp.path);
      expect(await store.readReport('../secrets.md'), isNull);
    });
  });

  group('ResearchKanbanTracker', () {
    test('lifecycle complete: backlog → doing → done', () async {
      final board = KanbanBoard('${tmp.path}/kanban.json');
      final tracker = ResearchKanbanTracker(board);
      final id = await tracker.start('pertanyaan riset panjang');
      final doing = (await board.list(state: KanbanState.doing)).single;
      expect(doing.id, id);
      expect(doing.title, 'Riset: pertanyaan riset panjang');
      await tracker.complete(id, 'ringkasan jawaban', 'riset-x.md');
      final done = (await board.list(state: KanbanState.done)).single;
      expect(done.result, 'ringkasan jawaban');
    });

    test('lifecycle fail', () async {
      final board = KanbanBoard('${tmp.path}/kanban.json');
      final tracker = ResearchKanbanTracker(board);
      final id = await tracker.start('pertanyaan');
      await tracker.fail(id, 'boom');
      final failed = (await board.list(state: KanbanState.failed)).single;
      expect(failed.result, contains('boom'));
    });
  });

  group('prompt-prefix job riset', () {
    test('deteksi + ekstraksi pertanyaan', () {
      expect(isResearchJobPrompt('[RISET] siapa presiden'), isTrue);
      expect(isResearchJobPrompt('  [RISET]  siapa  '), isTrue);
      expect(isResearchJobPrompt('halo biasa'), isFalse);
      expect(isResearchJobPrompt('[RISET]x'), isFalse);
      expect(
        researchQuestionFromPrompt('  [RISET] siapa presiden '),
        'siapa presiden',
      );
    });
  });

  group('tool deep_research / schedule_research', () {
    test('deep_research sukses & gagal', () async {
      final session = Session(id: 's', channel: 'cli', userKey: 'u');
      final ctx = ToolContext(session: session, workspacePath: tmp.path);
      final okTool = DeepResearchTool(
        (question) async => ResearchRunRecord(
          runId: 'r2',
          question: question,
          status: 'ok',
          startedAt: DateTime.now().toUtc(),
          finishedAt: DateTime.now().toUtc(),
          summary: 'selesai',
          reportName: 'riset-r2.md',
          kanbanTaskId: 'kb',
          queries: const ['q'],
        ),
      );
      final ok = await okTool.run({'question': 'siapa'}, ctx);
      expect(ok.isError, isFalse);
      expect(ok.content, contains('Riset selesai'));

      final failTool = DeepResearchTool(
        (question) async => ResearchRunRecord(
          runId: 'r3',
          question: question,
          status: 'failed',
          startedAt: DateTime.now().toUtc(),
          finishedAt: DateTime.now().toUtc(),
          summary: '',
          reportName: '',
          kanbanTaskId: '',
          error: 'boom',
        ),
      );
      final failed = await failTool.run({'question': 'siapa'}, ctx);
      expect(failed.isError, isTrue);
      expect(failed.content, contains('boom'));

      final empty = await failTool.run({'question': '  '}, ctx);
      expect(empty.isError, isTrue);
    });

    test('schedule_research membuat job', () async {
      final session = Session(id: 's', channel: 'cli', userKey: 'u');
      final ctx = ToolContext(session: session, workspacePath: tmp.path);
      Job? captured;
      final tool = ScheduleResearchTool(({
        required String question,
        required String cron,
        required String timezone,
        required String channel,
        required String userKey,
      }) async {
        captured = Job(
          id: 'job-1',
          cron: cron,
          prompt: '$researchPromptPrefix $question',
          channel: channel,
          userKey: userKey,
          nextRun: DateTime.now().toUtc(),
          timezone: timezone,
        );
        return captured!;
      });
      final res = await tool.run({
        'cron': '0 8 * * *',
        'question': 'monitor pasar',
      }, ctx);
      expect(res.isError, isFalse);
      expect(captured!.userKey, 'u');
      expect(captured!.channel, 'cli');
      expect(isResearchJobPrompt(captured!.prompt), isTrue);
      expect(captured!.timezone, 'UTC');
    });
  });
}
