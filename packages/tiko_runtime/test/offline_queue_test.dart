import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late Directory temp;
  late OfflineQueue queue;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tiko_offline_');
    queue = OfflineQueue(temp.path, leaseDuration: const Duration(seconds: 10));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('claim does not delete; ack removes from pending count', () async {
    await queue.enqueue(text: 'first', sessionId: 's1', channel: 'telegram');
    final claimed = await queue.claim();
    expect(claimed, hasLength(1));
    expect(claimed.single['channel'], 'telegram');
    expect(await queue.length(), 1);
    expect(await queue.peek(), isEmpty);
    expect(await queue.ack('${claimed.single['id']}', claimToken: '${claimed.single['claim_token']}'), isTrue);
    expect(await queue.length(), 0);
  });

  test('pending work cannot be acknowledged before a claim', () async {
    await queue.enqueue(text: 'pending');
    final pending = await queue.peek();
    expect(pending, hasLength(1));
    expect(await queue.ack('${pending.single['id']}', claimToken: 'not-a-lease'), isFalse);
    expect(await queue.length(), 1);
  });

  test('failed work can be retried and claimed again', () async {
    await queue.enqueue(text: 'retry me');
    final first = (await queue.claim()).single;
    expect(await queue.retry('${first['id']}', claimToken: '${first['claim_token']}', error: 'provider timeout'), isTrue);
    final second = (await queue.claim()).single;
    expect(second['id'], first['id']);
    expect(second['attempts'], 2);
  });

  test('expired worker cannot acknowledge before a replacement claim', () async {
    final shortLease = OfflineQueue(
      temp.path,
      leaseDuration: const Duration(milliseconds: 10),
    );
    await shortLease.enqueue(text: 'expired lease');
    final stale = (await shortLease.claim()).single;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      await shortLease.ack('${stale['id']}', claimToken: '${stale['claim_token']}'),
      isFalse,
    );
    expect(await shortLease.length(), 1);
  });

  test('expired worker cannot acknowledge a lease reclaimed by another worker', () async {
    final shortLease = OfflineQueue(
      temp.path,
      leaseDuration: const Duration(milliseconds: 10),
    );
    await shortLease.enqueue(text: 'lease race');
    final stale = (await shortLease.claim()).single;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final current = (await shortLease.claim()).single;
    expect(current['claim_token'], isNot(stale['claim_token']));
    expect(
      await shortLease.ack('${stale['id']}', claimToken: '${stale['claim_token']}'),
      isFalse,
    );
    expect(
      await shortLease.ack('${current['id']}', claimToken: '${current['claim_token']}'),
      isTrue,
    );
  });

  test('legacy JSONL entries are migrated as pending', () async {
    await File('${temp.path}/offline_queue.jsonl').writeAsString(
      '${jsonEncode({'id': 'legacy-1', 'text': 'old item', 'session_id': 'old', 'channel': 'cli'})}\n',
    );
    final claimed = await queue.claim();
    expect(claimed.single['id'], 'legacy-1');
    expect(claimed.single['status'], 'in_flight');
  });

  test('expired in-flight lease can be claimed after restart', () async {
    final shortLease = OfflineQueue(
      temp.path,
      leaseDuration: const Duration(milliseconds: 10),
    );
    await shortLease.enqueue(text: 'lease');
    final first = (await shortLease.claim()).single;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = await shortLease.claim();
    expect(second, hasLength(1));
    expect(second.single['id'], first['id']);
  });
}
