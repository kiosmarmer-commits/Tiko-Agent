import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:agent_gateway/src/messaging_gateways.dart';
import 'package:test/test.dart';

class _FakeGateway implements MessagingGateway {
  _FakeGateway(this.name, {this.failNext = 0, this.throwNext = false});
  @override
  final String name;
  int failNext;
  bool throwNext;
  final List<(String, String)> sent = [];
  int calls = 0;

  @override
  Future<bool> sendMessage(String chatId, String text,
      {List<String>? attachments}) async {
    calls++;
    if (throwNext) throw Exception('gateway down');
    if (failNext > 0) {
      failNext--;
      return false;
    }
    sent.add((chatId, text));
    return true;
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('delivery_ledger_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  DeliveryLedger ledger(
    String path, {
    DateTime Function()? clock,
    int? ownerPid,
    int maxAttempts = 5,
    Duration staleAfter = const Duration(hours: 24),
    int maxTextChars = 8000,
  }) =>
      DeliveryLedger(
        persistPath: path,
        clock: clock,
        ownerPid: ownerPid,
        maxAttempts: maxAttempts,
        staleAfter: staleAfter,
        maxTextChars: maxTextChars,
      );

  test('state machine: pending → attempting → delivered', () async {
    final l = ledger('${tmp.path}/ledger.json');
    final e = await l.enqueue(gateway: 'telegram', chatId: 'c1', text: 'halo');
    expect(e, isNotNull);
    expect(e!.state, DeliveryState.pending);
    await l.beginAttempt(e.id, ownerPid: 111);
    expect(l.entry(e.id)!.state, DeliveryState.attempting);
    expect(l.entry(e.id)!.attempts, 1);
    expect(l.entry(e.id)!.ownerPid, 111);
    await l.markDelivered(e.id);
    expect(l.entry(e.id)!.state, DeliveryState.delivered);
    expect(l.readyForRedelivery(), isEmpty);
  });

  test('markFailed lalu retry kembali ke pending (batas retry)', () async {
    final l = ledger('${tmp.path}/ledger.json');
    final e = await l.enqueue(gateway: 'slack', chatId: 'c1', text: 'x');
    await l.beginAttempt(e!.id, ownerPid: 1);
    await l.markFailed(e.id);
    expect(l.entry(e.id)!.state, DeliveryState.failed);
    expect(l.readyForRedelivery(), isEmpty,
        reason: 'failed tidak di-redeliver otomatis');
    await l.retry(e.id);
    expect(l.entry(e.id)!.state, DeliveryState.pending);
    expect(l.readyForRedelivery().single.id, e.id);
  });

  test('persist durabel: entry terbaca ulang dari disk', () async {
    final path = '${tmp.path}/ledger.json';
    final l = ledger(path);
    final e = await l.enqueue(gateway: 'telegram', chatId: 'c9', text: 'survive');
    await l.beginAttempt(e!.id, ownerPid: pid);

    final l2 = ledger(path);
    await l2.load();
    expect(l2.entry(e.id), isNotNull);
    expect(l2.entry(e.id)!.state, DeliveryState.attempting);
    expect(l2.entry(e.id)!.text, 'survive');
  });

  test('crash saat attempting milik proses lain → recovered marker', () async {
    final path = '${tmp.path}/ledger.json';
    final l = ledger(path);
    final e = await l.enqueue(gateway: 'telegram', chatId: 'c1', text: 'vital');
    await l.beginAttempt(e!.id, ownerPid: 999999);

    final l2 = ledger(path, ownerPid: 4242);
    final n = await l2.recoverOrphans();
    expect(n, 1);
    final r = l2.entry(e.id)!;
    expect(r.state, DeliveryState.pending);
    expect(r.recovered, isTrue);
    expect(l2.effectiveText(r), startsWith('[dipulihkan]'));
    expect(l2.readyForRedelivery(), isNotEmpty);
  });

  test('crash saat pending milik proses lain → redeliver polos tanpa marker',
      () async {
    final path = '${tmp.path}/ledger.json';
    final l = ledger(path);
    final e = await l.enqueue(gateway: 'telegram', chatId: 'c1', text: 'plain');
    expect(e!.ownerPid, isNull);

    final l2 = ledger(path, ownerPid: 4242);
    await l2.recoverOrphans();
    final r = l2.entry(e.id)!;
    expect(r.state, DeliveryState.pending);
    expect(r.recovered, isFalse);
    expect(l2.effectiveText(r), 'plain');
  });

  test('attempting milik proses yang sama tidak dianggap orphan', () async {
    final l = ledger('${tmp.path}/ledger.json');
    final e = await l.enqueue(gateway: 'tg', chatId: 'c', text: 'x');
    await l.beginAttempt(e!.id);
    final n = await l.recoverOrphans();
    expect(n, 0);
    expect(l.entry(e.id)!.state, DeliveryState.attempting);
  });

  test('sweep: melebihi maxAttempts → abandoned', () async {
    final l = ledger('${tmp.path}/ledger.json', maxAttempts: 2);
    final e = await l.enqueue(gateway: 'tg', chatId: 'c', text: 'x');
    await l.beginAttempt(e!.id, ownerPid: 1);
    await l.beginAttempt(e.id, ownerPid: 1);
    expect(e.attempts, 2);
    final n = await l.sweep();
    expect(n, 1);
    expect(l.entry(e.id)!.state, DeliveryState.abandoned);
    expect(l.readyForRedelivery(), isEmpty);
  });

  test('sweep: melewati staleAfter → abandoned', () async {
    var now = DateTime.utc(2026, 1, 1);
    final l = ledger('${tmp.path}/ledger.json',
        clock: () => now, staleAfter: const Duration(hours: 24));
    final e = await l.enqueue(gateway: 'tg', chatId: 'c', text: 'old');
    now = now.add(const Duration(hours: 30));
    final n = await l.sweep();
    expect(n, 1);
    expect(l.entry(e!.id)!.state, DeliveryState.abandoned);
  });

  test('LedgeredGateway: sukses → delivered; gagal → failed', () async {
    final l = ledger('${tmp.path}/ledger.json');
    final fake = _FakeGateway('telegram');
    final g = LedgeredGateway(inner: fake, ledger: l);

    expect(await g.sendMessage('c1', 'hai'), isTrue);
    final ok = l.all.single;
    expect(ok.state, DeliveryState.delivered);

    fake.failNext = 1;
    expect(await g.sendMessage('c1', 'hai lagi'), isFalse);
    final bad = l.all.last;
    expect(bad.state, DeliveryState.failed);
    expect(bad.attempts, 1);
  });

  test('LedgeredGateway: exception tetap dicatat failed dan rethrow', () async {
    final l = ledger('${tmp.path}/ledger.json');
    final fake = _FakeGateway('telegram', throwNext: true);
    final g = LedgeredGateway(inner: fake, ledger: l);

    await expectLater(g.sendMessage('c1', 'boom'), throwsException);
    expect(l.all.single.state, DeliveryState.failed);
  });

  test('teks terpotong sesuai maxTextChars', () async {
    final l = ledger('${tmp.path}/ledger.json', maxTextChars: 10);
    final e = await l.enqueue(
        gateway: 'tg', chatId: 'c', text: '0123456789ABCDEFGHIJ');
    expect(e!.text.length, 11); // 10 char + ellipsis
    expect(e.text.endsWith('…'), isTrue);
  });
}
