import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tiko_sesssearch_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FileSessionStore open() =>
      FileSessionStore(path: '${tmp.path}/sessions.json');

  Future<FileSessionStore> seeded() async {
    final s = open();
    await s.getOrCreate('cli:deploy', channel: 'cli', userKey: 'u');
    await s.appendTurn(
      'cli:deploy',
      user: 'bagaimana cara deploy ke server produksi?',
      assistant: 'Gunakan docker compose up -d lalu cek health check.',
    );
    await s.getOrCreate('tg:k8s', channel: 'telegram', userKey: 'u');
    await s.appendTurn(
      'tg:k8s',
      user: 'jelaskan strategi deploy kubernetes rolling update',
      assistant: 'Rolling update mengganti pod bertahap tanpa downtime.',
    );
    await s.getOrCreate('cli:lain', channel: 'cli', userKey: 'u');
    await s.appendTurn('cli:lain', user: 'cuaca hari ini', assistant: 'cerah');
    return s;
  }

  test('search finds hits across multiple sessions', () async {
    final s = await seeded();
    final hits = await s.searchSessions('deploy');
    expect(hits, isNotEmpty);
    final sessions = hits.map((h) => h.sessionId).toSet();
    expect(sessions, containsAll(['cli:deploy', 'tg:k8s']));
    expect(sessions, isNot(contains('cli:lain')));
  });

  test('all query terms must match (AND semantics)', () async {
    final s = await seeded();
    final hits = await s.searchSessions('deploy kubernetes');
    for (final h in hits) {
      expect(h.sessionId, 'tg:k8s');
    }
    expect(hits, isNotEmpty);
  });

  test('ranking puts more frequent matches first', () async {
    final s = open();
    await s.getOrCreate('a', channel: 'cli', userKey: 'u');
    await s.appendTurn('a', user: 'docker', assistant: 'docker docker docker');
    await s.getOrCreate('b', channel: 'cli', userKey: 'u');
    await s.appendTurn('b', user: 'docker sekilas', assistant: 'oke');
    final hits = await s.searchSessions('docker');
    expect(hits.length, greaterThanOrEqualTo(2));
    expect(hits.first.sessionId, 'a');
    expect(hits.first.score, greaterThan(hits.last.score));
  });

  test('snippet contains the match and is bounded', () async {
    final s = open();
    await s.getOrCreate('s', channel: 'cli', userKey: 'u');
    final filler = List.filled(200, 'kata').join(' ');
    await s.appendTurn('s', user: '${filler}SECRET_TOKEN$filler', assistant: 'ok');
    final hits = await s.searchSessions('SECRET_TOKEN');
    expect(hits, hasLength(1));
    expect(hits.first.snippet, contains('SECRET_TOKEN'));
    expect(hits.first.snippet.length, lessThan(200));
  });

  test('limit caps the result count', () async {
    final s = open();
    for (var i = 0; i < 5; i++) {
      await s.getOrCreate('s$i', channel: 'cli', userKey: 'u');
      await s.appendTurn('s$i', user: 'topik alpha $i', assistant: 'alpha lagi');
    }
    final hits = await s.searchSessions('alpha', limit: 2);
    expect(hits, hasLength(2));
  });

  test('empty query and no-match return empty list', () async {
    final s = await seeded();
    expect(await s.searchSessions(''), isEmpty);
    expect(await s.searchSessions('   '), isEmpty);
    expect(await s.searchSessions('zzznothing'), isEmpty);
  });

  test('search reflects on-disk state from another process', () async {
    final writer = open();
    await writer.getOrCreate('w', channel: 'cli', userKey: 'u');
    await writer.appendTurn('w', user: 'rahasia projek x', assistant: 'ok');

    final reader = open();
    final hits = await reader.searchSessions('projek');
    expect(hits, hasLength(1));
    expect(hits.first.sessionId, 'w');
  });

  test('default SessionStore.searchSessions is empty (no implementor break)',
      () async {
    final hits = await _NoSearchStore().searchSessions('apa pun');
    expect(hits, isEmpty);
  });
}

class _NoSearchStore extends SessionStore {
  @override
  Future<Session> getOrCreate(
    String sessionId, {
    required String channel,
    required String userKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20}) =>
      throw UnimplementedError();

  @override
  Future<void> appendTurn(
    String sessionId, {
    required String user,
    required String assistant,
    List<String> tools = const [],
  }) =>
      throw UnimplementedError();

  @override
  Future<List<SessionInfo>> list() => throw UnimplementedError();

  @override
  Future<bool> delete(String sessionId) => throw UnimplementedError();
}
