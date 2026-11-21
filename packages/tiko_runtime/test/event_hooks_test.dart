import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 700));

Future<void> _waitUntil(bool Function() cond) async {
  for (var i = 0; i < 50; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('kondisi tidak tercapai dalam 5s');
}

void main() {
  group('hooks config (P1 Hermes-parity)', () {
    test('aturan valid ter-parse; invalid dilompati dengan issue WARN', () {
      final (cfg, issues) = TikoConfig.parse('''
hooks:
  - event: model.switched
    webhook: https://hook.example/induk
    timeout_sec: 10
    env:
      WHO: tiko
  - event: approval.denied
    script: scripts/on_event.sh
  - event: tanpa.target.event
  - event: model.switched
    script: ../escape.sh
  - event: model.switched
    webhook: ftp://nope.example/hook
  - event: model.switched
    timeout_sec: 500
''');
      expect(issues.where((i) => i.fatal), isEmpty);
      final hookIssues =
          issues.where((i) => i.path.startsWith('hooks')).toList();
      expect(hookIssues, hasLength(4));
      expect(cfg.hooks, hasLength(2));
      expect(cfg.hooks[0].event, 'model.switched');
      expect(cfg.hooks[0].webhookUrl, 'https://hook.example/induk');
      expect(cfg.hooks[0].timeoutSec, 10);
      expect(cfg.hooks[0].env['WHO'], 'tiko');
      expect(cfg.hooks[1].script, 'scripts/on_event.sh');
    });

    test('hooks bukan daftar -> issue; tanpa section -> kosong tanpa issue',
        () {
      final (bad, badIssues) = TikoConfig.parse('hooks: 42\n');
      expect(badIssues.where((i) => i.path == 'hooks'), isNotEmpty);
      expect(bad.hooks, isEmpty);

      final (cfg, issues) = TikoConfig.parse('profile: default\n');
      expect(cfg.hooks, isEmpty);
      expect(issues.where((i) => i.path.startsWith('hooks')), isEmpty);
    });
  });

  group('HookExecutor', () {
    late Directory temp;
    late EventBus events;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tiko_hooks_');
      events = EventBus();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('script hook menulis file pada event yang cocok', () async {
      File(p.join(temp.path, 'on_event.sh')).writeAsStringSync(
        r'printf "%s\n" "$TIKO_EVENT" >> out.txt',
      );
      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(event: 'model.switched', script: 'on_event.sh'),
        ],
        workspace: temp.path,
      )..start();

      events.emit('model.switched', {'provider': 'gemini'});
      final file = File(p.join(temp.path, 'out.txt'));
      await _waitUntil(() => file.existsSync());
      await _pump();
      expect(file.readAsStringSync(), contains('model.switched'));
      final stats = exec.snapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:script'] as Map<String, dynamic>;
      expect(s['fires'], 1);
      expect(s['failures'], 0);
      await exec.dispose();
    });

    test('event tidak cocok atau hook.* tidak memicu apa pun', () async {
      File(p.join(temp.path, 'on_event.sh')).writeAsStringSync(
        r'printf "%s\n" "$TIKO_EVENT" >> out.txt',
      );
      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(event: 'model.switched', script: 'on_event.sh'),
        ],
        workspace: temp.path,
      )..start();

      events.emit('approval.denied', {'tool': 'shell'});
      events.emit('hook.executed', {'rule': 'x', 'outcome': 'ok'});
      await _pump();
      expect(File(p.join(temp.path, 'out.txt')).existsSync(), isFalse);
      await exec.dispose();
    });

    test('script gagal (exit non-zero) -> error tercatat + hook.executed',
        () async {
      File(p.join(temp.path, 'bad.sh')).writeAsStringSync('exit 3');
      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(event: 'model.switched', script: 'bad.sh'),
        ],
        workspace: temp.path,
      )..start();
      final executed = <TikoEvent>[];
      final sub = events.stream.listen(executed.add);

      events.emit('model.switched', {'provider': 'gemini'});
      await _pump();
      final stats = exec.snapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:script'] as Map<String, dynamic>;
      expect(s['fires'], 1);
      expect(s['failures'], 1);
      expect(s['last_error'], contains('exit code 3'));
      final hookEvents =
          executed.where((e) => e.type == 'hook.executed').toList();
      expect(hookEvents, hasLength(1));
      expect(hookEvents.first.data['outcome'], 'error');
      expect(hookEvents.first.data['error'], contains('exit code 3'));
      await sub.cancel();
      await exec.dispose();
    });

    test('script tidak ada -> error jelas, tanpa crash', () async {
      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(event: 'model.switched', script: 'hilang.sh'),
        ],
        workspace: temp.path,
      )..start();
      final executed = <TikoEvent>[];
      final sub = events.stream.listen(executed.add);

      events.emit('model.switched', {'provider': 'gemini'});
      await _pump();
      final stats = exec.snapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:script'] as Map<String, dynamic>;
      expect(s['failures'], 1);
      final hookEvents =
          executed.where((e) => e.type == 'hook.executed').toList();
      expect(hookEvents, hasLength(1));
      expect(hookEvents.first.data['outcome'], 'error');
      expect(hookEvents.first.data['error'], contains('tidak ditemukan'));
      await sub.cancel();
      await exec.dispose();
    });

    test('wildcard * tidak memicu pada event hook.* sendiri', () async {
      File(p.join(temp.path, 'on_event.sh')).writeAsStringSync(
        r'printf "%s\n" "$TIKO_EVENT" >> out.txt',
      );
      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(event: '*', script: 'on_event.sh'),
        ],
        workspace: temp.path,
      )..start();

      events.emit('hook.executed', {'rule': 'x', 'outcome': 'ok'});
      await _pump();
      expect(File(p.join(temp.path, 'out.txt')).existsSync(), isFalse);

      events.emit('sembarang.event', {'who': 'tiko'});
      final file = File(p.join(temp.path, 'out.txt'));
      await _waitUntil(() => file.existsSync());
      expect(file.readAsStringSync(), contains('sembarang.event'));
      await exec.dispose();
    });

    test('webhook POST event sebagai JSON + data', () async {
      final bodies = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(body) as Map<String, dynamic>);
        await req.response.close();
      });

      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(
            event: 'approval.denied',
            webhookUrl: 'http://127.0.0.1:${server.port}/hook',
            timeoutSec: 5,
          ),
        ],
        workspace: temp.path,
      )..start();
      final executed = <TikoEvent>[];
      final sub = events.stream.listen(executed.add);

      events.emit('approval.denied', {'tool': 'shell'});
      await _waitUntil(() => bodies.isNotEmpty);
      await _pump();
      expect(bodies, hasLength(1));
      expect(bodies.first['event'], 'approval.denied');
      expect((bodies.first['data'] as Map<String, dynamic>)['tool'], 'shell');
      final stats = exec.snapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:webhook'] as Map<String, dynamic>;
      expect(s['fires'], 1);
      expect(s['failures'], 0);
      final hookEvents =
          executed.where((e) => e.type == 'hook.executed').toList();
      expect(hookEvents, isNotEmpty);
      expect(hookEvents.last.data['outcome'], 'ok');
      await sub.cancel();
      await exec.dispose();
      await server.close(force: true);
    });

    test('webhook respons 5xx tercatat gagal', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 503;
        await req.response.close();
      });

      final exec = HookExecutor(
        events: events,
        rules: [
          HookRuleConfig(
            event: 'approval.denied',
            webhookUrl: 'http://127.0.0.1:${server.port}/hook',
            timeoutSec: 5,
          ),
        ],
        workspace: temp.path,
      )..start();

      events.emit('approval.denied', {'tool': 'shell'});
      await _pump();
      final stats = exec.snapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:webhook'] as Map<String, dynamic>;
      expect(s['fires'], 1);
      expect(s['failures'], 1);
      expect(s['last_error'], contains('503'));
      await exec.dispose();
      await server.close(force: true);
    });
  });

  group('runtime wiring hooks', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tiko_hooks_rt_');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Future<String> _prepare(String hooksSection) async {
      final ws = temp.path;
      final hookDir = Directory(p.join(ws, 'hooks'))..createSync();
      File(p.join(hookDir.path, 'on_event.sh')).writeAsStringSync(
        r'printf "%s\n" "$TIKO_EVENT" >> hooks/fired.txt',
      );
      final configDir = Directory(p.join(ws, 'config'))..createSync();
      final config = File(p.join(configDir.path, 'agent.yaml'));
      await config.writeAsString('''
profile: default
workspace: $ws
storage:
  data_dir: ${p.join(ws, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 4
$hooksSection
''');
      return config.path;
    }

    test('runtime memasang HookExecutor bila aturan ada', () async {
      final configPath = await _prepare('''
hooks:
  - event: "*"
    script: hooks/on_event.sh
    timeout_sec: 10
''');
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      expect(rt.hookExecutor, isNotNull);
      final snap = rt.hookSnapshot();
      expect(snap['rules'] as List<dynamic>, hasLength(1));

      rt.events.emit('model.switched', {'provider': 'gemini'});
      final fired = File(p.join(temp.path, 'hooks', 'fired.txt'));
      await _waitUntil(() => fired.existsSync());
      expect(fired.readAsStringSync(), contains('model.switched'));
      final stats = rt.hookSnapshot()['stats'] as Map<String, dynamic>;
      final s = stats['hooks[0]:script'] as Map<String, dynamic>;
      expect(s['fires'], 1);
    });

    test('tanpa section hooks -> executor null, snapshot kosong', () async {
      final configPath = await _prepare('');
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      expect(rt.hookExecutor, isNull);
      final snap = rt.hookSnapshot();
      expect(snap['rules'] as List<dynamic>, isEmpty);
      expect(snap['stats'] as Map<String, dynamic>, isEmpty);
    });

    test('hooks invalid (warn) tetap boot runtime', () async {
      final configPath = await _prepare('hooks: 42\n');
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      expect(rt.hookExecutor, isNull);
    });
  });
}
