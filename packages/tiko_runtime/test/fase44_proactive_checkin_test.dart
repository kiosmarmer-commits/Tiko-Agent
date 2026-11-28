import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ProactiveCheckinTarget _target(String id, {int idleMinutes = 60}) =>
    ProactiveCheckinTarget(
      sessionId: id,
      channel: 'test',
      userKey: 'user-$id',
      lastActivity: DateTime.now().toUtc().subtract(Duration(minutes: idleMinutes)),
    );

void main() {
  late String dataDir;

  setUp(() async {
    dataDir = await Directory.systemTemp
        .createTemp('checkin_test')
        .then((d) => d.path);
  });

  tearDown(() async {
    await Directory(dataDir).delete(recursive: true);
  });

  test('CHECKIN-1: sesi idle melewati ambang \u2192 check-in terkirim + state', () async {
    final events = <Map<String, dynamic>>[];
    final sent = <String>[];
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      listIdleSessions: () async => [_target('s1')],
      send: (t, msg) async {
        sent.add(t.sessionId);
        return true;
      },
      emitEvent: (type, data) => events.add({'type': type, ...data}),
    );
    final report = await engine.tick();
    expect(sent, ['s1']);
    expect(report.proposed, ['s1']);
    expect(report.errors, 0);
    expect(events.where((e) => e['type'] == 'checkin.proposed'), hasLength(1));
  });

  test('CHECKIN-2: budget per sesi per hari \u2014 tick kedua di-skip', () async {
    var sends = 0;
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      maxPerSessionPerDay: 1,
      listIdleSessions: () async => [_target('s1')],
      send: (t, msg) async {
        sends++;
        return true;
      },
    );
    await engine.tick();
    final second = await engine.tick();
    expect(sends, 1);
    expect(second.proposed, isEmpty);
    expect(second.skipped, 1);
  });

  test('CHECKIN-3: sesi belum idle cukup lama \u2192 tidak di-check-in', () async {
    var sends = 0;
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      listIdleSessions: () async => [_target('s1', idleMinutes: 5)],
      send: (t, msg) async {
        sends++;
        return true;
      },
    );
    final report = await engine.tick();
    expect(sends, 0);
    expect(report.proposed, isEmpty);
  });

  test('CHECKIN-4: pengiriman gagal \u2192 dihitung error, tidak masuk proposed',
      () async {
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      listIdleSessions: () async => [_target('s1')],
      send: (t, msg) async => false,
    );
    final report = await engine.tick();
    expect(report.proposed, isEmpty);
    expect(report.errors, 1);
  });

  test('CHECKIN-5: state persist \u2014 engine baru tetap hormati budget harian',
      () async {
    var sends = 0;
    ProactiveCheckinEngine newEngine() => ProactiveCheckinEngine(
          dataDir: dataDir,
          idleMinutes: 30,
          maxPerSessionPerDay: 1,
          listIdleSessions: () async => [_target('s1')],
          send: (t, msg) async {
            sends++;
            return true;
          },
        );
    await newEngine().tick();
    await newEngine().tick();
    expect(sends, 1);
  });

  test('CHECKIN-6: send null \u2192 event checkin.proposed delivered=false',
      () async {
    final events = <Map<String, dynamic>>[];
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      listIdleSessions: () async => [_target('s1')],
      send: null,
      emitEvent: (type, data) => events.add({...data}),
    );
    final report = await engine.tick();
    expect(report.proposed, ['s1']);
    expect(report.errors, 0);
    expect(events.single['delivered'], false);
    expect(events.single['message'], contains('Check-in otomatis'));
  });

  test('CHECKIN-7: cap sesi per tick \u2014 sisanya di-skip', () async {
    var sends = 0;
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      maxSessionsPerTick: 1,
      listIdleSessions: () async => [_target('s1'), _target('s2')],
      send: (t, msg) async {
        sends++;
        return true;
      },
    );
    final report = await engine.tick();
    expect(sends, 1);
    expect(report.proposed, hasLength(1));
    expect(report.skipped, 1);
  });

  test('CHECKIN-8: tool status + tick', () async {
    final engine = ProactiveCheckinEngine(
      dataDir: dataDir,
      idleMinutes: 30,
      listIdleSessions: () async => const [],
      send: null,
    );
    final tool = ProactiveCheckinTool(engine: engine);
    final ctx = ToolContext(
      session: Session(id: 's', channel: 'test', userKey: 'u'),
      workspacePath: dataDir,
    );
    final status = await tool.run({'action': 'status'}, ctx);
    expect(status.isError, isFalse);
    expect(status.content, contains('"enabled_sessions": 0'));
    final tick = await tool.run({'action': 'tick'}, ctx);
    final decoded = jsonDecode(tick.content) as Map;
    expect(decoded['idle_sessions'], 0);
  });
}
