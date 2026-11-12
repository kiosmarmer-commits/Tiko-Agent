import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String boardPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko-kanban');
    boardPath = '${temp.path}/kanban.json';
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('add/list/claim/complete/fail/delete lifecycle', () async {
    final board = KanbanBoard(boardPath);
    final task = await board.add('deploy produksi', createdBy: 'alice');
    expect(task.state, KanbanState.backlog);
    expect(task.id, startsWith('kb-'));

    final claimed = await board.claim(task.id, claimer: 'worker-1');
    expect(claimed, isNotNull);
    expect(claimed!.state, KanbanState.doing);
    expect(claimed.claimedBy, 'worker-1');

    final done = await board.complete(task.id, result: 'selesai');
    expect(done, isNotNull);
    expect(done!.state, KanbanState.done);
    expect(done.result, 'selesai');

    expect(await board.delete(task.id), isTrue);
    expect(await board.list(), isEmpty);
  });

  test('claim atomik: hanya satu instance yang menang', () async {
    final boardA = KanbanBoard(boardPath);
    final boardB = KanbanBoard(boardPath);
    final task = await boardA.add('tugas ganda');

    final results = await Future.wait([
      boardA.claim(task.id, claimer: 'worker-A'),
      boardB.claim(task.id, claimer: 'worker-B'),
    ]);
    final winners = results.whereType<KanbanTask>().toList();
    expect(winners, hasLength(1));
    expect(winners.first.state, KanbanState.doing);

    final board = KanbanBoard(boardPath);
    final doing = await board.list(state: KanbanState.doing);
    expect(doing, hasLength(1));
    expect(
      ['worker-A', 'worker-B'].contains(doing.first.claimedBy),
      isTrue,
    );
  });

  test('durability: board baru membaca ulang dari disk', () async {
    final board1 = KanbanBoard(boardPath);
    final t1 = await board1.add('tugas A');
    await board1.add('tugas B');

    final board2 = KanbanBoard(boardPath);
    final all = await board2.list();
    expect(all, hasLength(2));

    await board2.claim(t1.id, claimer: 'w');
    final board3 = KanbanBoard(boardPath);
    final doing = await board3.list(state: KanbanState.doing);
    expect(doing, hasLength(1));
    expect(doing.first.title, 'tugas A');
  });

  test('state transition invalid ditolak', () async {
    final board = KanbanBoard(boardPath);
    final task = await board.add('tugas C');
    expect(await board.complete(task.id), isNull);
    expect(await board.fail(task.id), isNull);
    final claimed = await board.claim(task.id);
    expect(claimed, isNotNull);
    expect(await board.claim(task.id), isNull);
  });

  test('tool kanban e2e', () async {
    final board = KanbanBoard(boardPath);
    final tool = KanbanTool(board);
    final ctx = ToolContext(
      session: Session(id: 's1', channel: 'cli', userKey: 'user-1'),
      workspacePath: temp.path,
    );

    final added = await tool.run({'action': 'add', 'title': 'tulis laporan'}, ctx);
    expect(added.isError, isFalse);
    final id = added.content.split(' ').firstWhere((w) => w.startsWith('kb-'));

    final listed = await tool.run({'action': 'list'}, ctx);
    expect(listed.content, contains('tulis laporan'));
    expect(listed.content, contains('[backlog]'));

    final claimed = await tool.run({'action': 'claim', 'id': id}, ctx);
    expect(claimed.content, contains('[doing]'));

    final completed =
        await tool.run({'action': 'complete', 'id': id, 'result': 'ok'}, ctx);
    expect(completed.content, startsWith('done'));

    final badAction = await tool.run({'action': 'hocus'}, ctx);
    expect(badAction.isError, isTrue);
  });
}
