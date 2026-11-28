import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<(Directory, ContextPager, FileSessionStore)> _setup({
  int keepRecent = 10,
}) async {
  final temp = await Directory.systemTemp.createTemp('context_pager_');
  final memory = LayeredMemory();
  final store = FileSessionStore(path: p.join(temp.path, 'sessions.json'));
  final pager = ContextPager(
    store: store,
    memory: memory,
    statePath: p.join(temp.path, 'paging_state.json'),
    keepRecent: keepRecent,
  );
  return (temp, pager, store);
}

void main() {
  test('PAGE-1: page-out di luar window + idempoten', () async {
    final (temp, pager, store) = await _setup();
    addTearDown(() => temp.delete(recursive: true));
    await store.getOrCreate('s-1', channel: 'test', userKey: 'u');
    for (var i = 1; i <= 30; i++) {
      await store.appendTurn(
        's-1',
        user: 'pertanyaan nomor $i tentang topik $i',
        assistant: 'jawaban nomor $i',
      );
    }
    final report = await pager.pageOut(sessionId: 's-1', userKey: 'u');
    expect(report.error, isNull);
    expect(report.pagedMessages, 50,
        reason: '60 pesan (2/turn) - keepRecent 10');
    expect(report.pagedPages, greaterThanOrEqualTo(1));
    expect(report.charsPaged, greaterThan(0));

    final second = await pager.pageOut(sessionId: 's-1', userKey: 'u');
    expect(second.pagedMessages, 0, reason: 'idempoten via fingerprint');

    final status = pager.status(sessionId: 's-1');
    expect(status['paged_session'], report.pagedPages);
  });

  test('PAGE-2: page-in hanya halaman paged, terikat sesi', () async {
    final (temp, pager, store) = await _setup(keepRecent: 4);
    addTearDown(() => temp.delete(recursive: true));
    await store.getOrCreate('s-a', channel: 'test', userKey: 'u');
    await store.getOrCreate('s-b', channel: 'test', userKey: 'u');
    for (var i = 1; i <= 20; i++) {
      await store.appendTurn(
        's-a',
        user: 'resep rendang santan rempah langkah $i',
        assistant: 'ok $i',
      );
    }
    await store.appendTurn(
      's-b',
      user: 'topik lain jaringan neural',
      assistant: 'ok lain',
    );
    await pager.pageOut(sessionId: 's-a', userKey: 'u');
    await pager.pageOut(sessionId: 's-b', userKey: 'u');

    final hits = pager.pageIn(
      query: 'resep rendang santan',
      sessionId: 's-a',
      userKey: 'u',
    );
    expect(hits, isNotEmpty);
    for (final h in hits) {
      expect(h.tags, contains('paged'));
      expect(h.tags, contains('session:s-a'));
      expect(h.sourceSession, 's-a');
    }

    final scoped = pager.pageIn(query: 'jaringan neural', sessionId: 's-a');
    expect(scoped, isEmpty, reason: 'halaman sesi lain tidak bocor');
  });

  test('PAGE-3: sejarah pendek — tidak ada paging', () async {
    final (temp, pager, store) = await _setup();
    addTearDown(() => temp.delete(recursive: true));
    await store.getOrCreate('s-2', channel: 'test', userKey: 'u');
    await store.appendTurn('s-2', user: 'halo', assistant: 'hai');
    final report = await pager.pageOut(sessionId: 's-2', userKey: 'u');
    expect(report.pagedMessages, 0);
    expect(report.pagedPages, 0);
  });

  test('PAGE-4: store gagal → report error, never-raises', () async {
    final temp = await Directory.systemTemp.createTemp('context_pager_err_');
    addTearDown(() => temp.delete(recursive: true));
    final memory = LayeredMemory();
    final pager = ContextPager(
      store: _BrokenStore(),
      memory: memory,
      statePath: p.join(temp.path, 'st.json'),
    );
    final report = await pager.pageOut(sessionId: 's-x', userKey: 'u');
    expect(report.error, isNotNull);
    expect(report.pagedMessages, 0);
    final st = pager.status();
    expect(st['paged_total'], 0);
  });

  test('PAGE-5: tool memory_page — page_out/page_in/status + validasi',
      () async {
    final (temp, pager, store) = await _setup(keepRecent: 4);
    addTearDown(() => temp.delete(recursive: true));
    await store.getOrCreate('s-tool', channel: 'test', userKey: 'u');
    for (var i = 1; i <= 12; i++) {
      await store.appendTurn(
        's-tool',
        user: 'skema database migrasi tahap $i',
        assistant: 'dikerjakan $i',
      );
    }
    final tool = MemoryPageTool(pager);
    final ctx = ToolContext(
      session: Session(id: 's-tool', channel: 'test', userKey: 'u'),
      workspacePath: temp.path,
    );

    final noAction = await tool.run({}, ctx);
    expect(noAction.isError, isTrue);

    final out = await tool.run({'action': 'page_out'}, ctx);
    expect(out.isError, isFalse, reason: out.content);
    expect(out.content, contains('"paged_messages": 20'),
        reason: '24 pesan - keepRecent 4');

    final badIn = await tool.run({'action': 'page_in'}, ctx);
    expect(badIn.isError, isTrue);

    final inHit = await tool.run(
      {'action': 'page_in', 'query': 'skema database migrasi'},
      ctx,
    );
    expect(inHit.isError, isFalse, reason: inHit.content);
    expect(inHit.content, contains('[paged s-tool]'));

    final st = await tool.run({'action': 'status'}, ctx);
    expect(st.content, contains('"paged_session":'));
  });
}

class _BrokenStore {
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20}) async {
    throw StateError('store mati');
  }
}
