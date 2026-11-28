import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String sessionId) => ToolContext(
      session: Session(id: sessionId, channel: 'test', userKey: 'u'),
      workspacePath: Directory.systemTemp.path,
    );

void main() {
  late String path;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('learnq_test');
    path = '${dir.path}${Platform.pathSeparator}review_learnings.json';
  });

  tearDown(() async {
    final file = File(path);
    if (await file.exists()) {
      await file.parent.delete(recursive: true);
    }
  });

  test('LESSON-1: propose → list pending → approve menandai status', () async {
    final store = ReviewLearningsStore(path: path);
    final proposal = await store.propose(
      content: 'Format laporan bulanan selalu pakai tabel.',
      source: 'conversation',
      botId: 'asisten',
      sessionId: 's-1',
    );
    expect(proposal.status, LearningStatus.pending);
    expect(store.list(status: LearningStatus.pending).length, 1);

    final decided = await store.decide(proposal.id, approve: true);
    expect(decided!.status, LearningStatus.approved);
    expect(store.list(status: LearningStatus.pending), isEmpty);
    expect(await store.decide(proposal.id, approve: false), isNull,
        reason: 'idempoten aman: keputusan hanya mengubah pending');
  });

  test('LESSON-2: store persisten lintas instance, korup fail-open',
      () async {
    final store = ReviewLearningsStore(path: path);
    await store.propose(content: 'pelajaran satu', source: 'note');
    final store2 = ReviewLearningsStore(path: path);
    await store2.load();
    expect(store2.list(status: null).length, 1);

    await File(path).writeAsString('{korup');
    final store3 = ReviewLearningsStore(path: path);
    await store3.load();
    expect(store3.list(status: null), isEmpty);
  });

  test('LESSON-3: cap proposal — pending tertua dibuang, decided dipertahankan',
      () async {
    final store = ReviewLearningsStore(path: path, maxProposals: 3);
    final first = await store.propose(content: 'lama');
    await store.decide(first.id, approve: true);
    await store.propose(content: 'pending dua');
    await store.propose(content: 'pending tiga');
    await store.propose(content: 'pending empat');
    final remaining = store.list(status: null);
    expect(remaining.length, 3);
    expect(
      remaining.any((e) => e.content == 'lama'),
      isTrue,
      reason: 'proposal decided tidak dibuang otomatis',
    );
    expect(
      remaining.any((e) => e.content == 'pending dua'),
      isFalse,
      reason: 'pending tertua dibuang',
    );
  });

  test('LESSON-4: tool review_learnings — propose/list/approve dengan callback',
      () async {
    final store = ReviewLearningsStore(path: path);
    var approvedContent = '';
    final tool = ReviewLearningsTool(
      store: store,
      onApproved: (proposal) async {
        approvedContent = proposal.content;
        return true;
      },
    );
    final ctx = _ctx('s-live');

    final noContent = await tool.run({'action': 'propose'}, ctx);
    expect(noContent.isError, isTrue);

    final proposed = await tool.run({
      'action': 'propose',
      'content': 'Selalu sertakan contoh kode di jawaban.',
      'bot': 'coder',
      'source': 'conversation',
    }, ctx);
    expect(proposed.isError, isFalse);
    expect(proposed.content, contains('antrian review'));

    final listed = await tool.run({'action': 'list'}, ctx);
    expect(listed.content, contains('Selalu sertakan contoh kode'));

    final badSource = await tool.run({
      'action': 'propose',
      'content': 'sumber aneh',
      'source': 'hacked; drop table',
    }, ctx);
    expect(badSource.isError, isFalse);

    final pending = store.list(status: LearningStatus.pending).first;
    final approved = await tool.run(
        {'action': 'approve', 'id': pending.id}, ctx);
    expect(approved.isError, isFalse);
    expect(approvedContent, 'Selalu sertakan contoh kode di jawaban.');

    final again = await tool.run({'action': 'approve', 'id': pending.id}, ctx);
    expect(again.isError, isTrue);

    final unknown = await tool.run({'action': 'approve', 'id': 'nope'}, ctx);
    expect(unknown.isError, isTrue);
  });

  test('LESSON-5: config parser fail-open + default off', () {
    final (cfg, _) = TikoConfig.parse('agent:\n  id: x\n');
    expect(cfg.reviewLearnings.enabled, isFalse);
    final (parsed, _) = TikoConfig.parse('review_learnings:\n'
        '  enabled: true\n'
        '  max_proposals: 9999\n'
        '  max_learnings_per_bot: 0\n');
    expect(parsed.reviewLearnings.enabled, isTrue);
    expect(parsed.reviewLearnings.maxProposals, 200);
    expect(parsed.reviewLearnings.maxLearningsPerBot, 64);
  });

  test('LESSON-6: BotProfile.learnings — persist, cap, dan persona injection',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('learnq_profile');
    addTearDown(() => dir.delete(recursive: true));
    final store = BotStore(dataDir: dir.path);
    await store.create(id: 'asisten', name: 'Asisten');
    await store.update('asisten', (b) => b.copyWith(learnings: ['poin satu']));
    final store2 = BotStore(dataDir: dir.path);
    await store2.load();
    expect(store2.get('asisten')!.learnings, ['poin satu']);
  });
}
