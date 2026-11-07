import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tiko_sessions_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FileSessionStore open() => FileSessionStore(path: '${tmp.path}/sessions.json');

  test('history survives restart (PRD acceptance #12)', () async {
    final a = open();
    await a.getOrCreate('cli:1', channel: 'cli', userKey: 'u');
    await a.appendTurn('cli:1', user: 'halo', assistant: 'hai');
    await a.appendTurn('cli:1', user: 'hitung', assistant: '6');

    final b = open(); // simulates a new process
    final msgs = await b.recent('cli:1', limit: 10);
    expect(msgs.map((m) => '${m.role}:${m.content}').toList(),
        ['user:halo', 'assistant:hai', 'user:hitung', 'assistant:6']);
    final info = (await b.list()).single;
    expect(info.turns, 2);
    expect(info.title, 'halo');
  });

  test('recent respects limit and order', () async {
    final s = open();
    await s.getOrCreate('s', channel: 'cli', userKey: 'u');
    for (var i = 0; i < 5; i++) {
      await s.appendTurn('s', user: 'u$i', assistant: 'a$i');
    }
    final msgs = await s.recent('s', limit: 2);
    expect(msgs.map((m) => m.content).toList(), ['u4', 'a4']);
  });

  test('sessions are isolated and deletable', () async {
    final s = open();
    await s.getOrCreate('a', channel: 'cli', userKey: 'u');
    await s.getOrCreate('b', channel: 'cli', userKey: 'u');
    await s.appendTurn('a', user: 'x', assistant: 'y');
    expect(await s.recent('b'), isEmpty);
    expect(await s.delete('a'), isTrue);
    expect(await s.delete('a'), isFalse);
    expect((await open().list()).map((e) => e.id), ['b']);
  });

  test('corrupt file is quarantined and store starts clean', () async {
    File('${tmp.path}/sessions.json').writeAsStringSync('{not json');
    final s = open();
    expect(await s.list(), isEmpty);
    expect(
      tmp.listSync().any((e) => e.path.contains('sessions.json.corrupt-')),
      isTrue,
    );
  });

  test('message cap per session', () async {
    final s = FileSessionStore(path: '${tmp.path}/s.json', maxMessagesPerSession: 4);
    await s.getOrCreate('s', channel: 'cli', userKey: 'u');
    for (var i = 0; i < 5; i++) {
      await s.appendTurn('s', user: 'u$i', assistant: 'a$i');
    }
    expect((await s.recent('s', limit: 100)).length, 4);
  });
}
