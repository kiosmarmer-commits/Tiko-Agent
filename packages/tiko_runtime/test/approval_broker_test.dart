import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('ApprovalBroker', () {
    late Directory temp;
    late ApprovalBroker broker;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tiko_approval_');
      broker = ApprovalBroker('${temp.path}/approvals.json');
    });

    tearDown(() async {
      await broker.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Session session() => Session(
          id: 'session-1',
          channel: 'http',
          userKey: 'flutter-user',
        );

    ToolCall call() => ToolCall(
          id: 'call-1',
          name: 'write_file',
          args: {'path': 'notes.txt', 'content': 'hello', '_internal': 'secret'},
        );

    test('one request is persisted and external approval resolves its waiter',
        () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'medium',
      );
      expect(request.channel, 'http');
      expect(request.args, {'path': 'notes.txt', 'content': 'hello'});
      expect(request.argsHash, isNotEmpty);

      final waiting = broker.wait(request.id);
      final decided = await broker.decide(
        request.id,
        approve: true,
        actor: 'flutter',
      );

      expect(decided?.state, ApprovalState.approved);
      expect(await waiting, isTrue);
      expect(await broker.decide(request.id, approve: false), isNull);
      expect((await broker.all()).single.state, ApprovalState.approved);
    });

    test('deny resolves the same waiter as false', () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      final waiting = broker.wait(request.id);
      final decided = await broker.decide(
        request.id,
        approve: false,
        actor: 'api',
        reason: 'user denied',
      );

      expect(decided?.state, ApprovalState.denied);
      expect(await waiting, isFalse);
    });

    test('expired approvals cannot be approved', () async {
      final shortLived = ApprovalBroker(
        '${temp.path}/short.json',
        requestTtl: const Duration(milliseconds: 20),
      );
      addTearDown(shortLived.close);
      final request = await shortLived.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(
        await shortLived.decide(request.id, approve: true, actor: 'late'),
        isNull,
      );
      expect((await shortLived.all()).single.state, ApprovalState.expired);
    });

    test('a separate CLI reader does not expire a live daemon request', () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      final cliReader = ApprovalBroker('${temp.path}/approvals.json');
      addTearDown(cliReader.close);
      await cliReader.load();
      final restored = (await cliReader.all()).single;
      expect(restored.id, request.id);
      expect(restored.state, ApprovalState.pending);
      expect((await cliReader.pending()).single.id, request.id);
    });

    test('only daemon startup expires approvals left by its previous run', () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      final restarted = ApprovalBroker('${temp.path}/approvals.json');
      addTearDown(restarted.close);
      await restarted.expirePendingOnStartup();
      final restored = (await restarted.all()).single;
      expect(restored.id, request.id);
      expect(restored.state, ApprovalState.expired);
      expect(await restarted.pending(), isEmpty);
    });

    test('concurrent first reads share one load operation', () async {
      await broker.create(session: session(), call: call(), risk: 'high');
      final reader = ApprovalBroker('${temp.path}/approvals.json');
      addTearDown(reader.close);
      final snapshots = await Future.wait(
        List.generate(32, (_) => reader.all()),
      );
      expect(snapshots.every((snapshot) => snapshot.length == 1), isTrue);
      expect(snapshots.every((snapshot) => snapshot.single.state == ApprovalState.pending), isTrue);
    });

    test('decision before wait is not lost', () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'medium',
      );
      await broker.decide(request.id, approve: true, actor: 'race-test');
      expect(await broker.wait(request.id), isTrue);
    });

    test('unknown approval fails closed', () async {
      expect(await broker.wait('not-found'), isFalse);
      expect(await broker.decide('not-found', approve: true), isNull);
    });
    test('expired request is reflected in approval history without a waiter',
        () async {
      final shortLived = ApprovalBroker(
        '${temp.path}/history.json',
        requestTtl: const Duration(milliseconds: 15),
      );
      addTearDown(shortLived.close);
      final request = await shortLived.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect((await shortLived.all()).single.state, ApprovalState.expired);
      expect(await shortLived.pending(), isEmpty);
      expect(await shortLived.decide(request.id, approve: true), isNull);
    });

    test('failed persistence does not leave a false in-memory approval',
        () async {
      final request = await broker.create(
        session: session(),
        call: call(),
        risk: 'high',
      );
      final ledger = File('${temp.path}/approvals.json');
      await ledger.delete();
      await ledger.create();
      // Replace the ledger path with a directory so the atomic rename fails.
      await ledger.delete();
      await Directory(ledger.path).create();
      await expectLater(
        broker.decide(request.id, approve: true),
        throwsA(isA<FileSystemException>()),
      );
      expect((await broker.all()).single.state, ApprovalState.pending);
    });

  });
}
