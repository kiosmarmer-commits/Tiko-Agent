// Fase 25 (Hermes `170d9637` gateway idle compaction): sesi idle melewati
// ambang dikompaksi di latar per channel — latch per aktivitas, skip sesi
// sibuk, override channel (0 = off), default config off, gate admission.
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Fake [SessionStore] dengan `updatedAt` terkontrol penuh via clock test.
class _FakeSessions extends SessionStore {
  final Map<String, ({String channel, String userKey, DateTime updatedAt})>
      _sessions = {};
  final Map<String, List<ChatMessage>> _messages = {};
  DateTime Function() clock;

  _FakeSessions(this.clock);

  @override
  Future<Session> getOrCreate(
    String sessionId, {
    required String channel,
    required String userKey,
  }) async {
    _sessions.putIfAbsent(
      sessionId,
      () => (channel: channel, userKey: userKey, updatedAt: clock()),
    );
    return Session(id: sessionId, channel: channel, userKey: userKey);
  }

  void touch(String sessionId) {
    final s = _sessions[sessionId]!;
    _sessions[sessionId] = (
      channel: s.channel,
      userKey: s.userKey,
      updatedAt: clock(),
    );
  }

  @override
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20}) async =>
      _messages[sessionId] ?? const <ChatMessage>[];

  @override
  Future<bool> delete(String sessionId) async =>
      _sessions.remove(sessionId) != null;

  @override
  Future<void> appendTurn(
    String sessionId, {
    required String user,
    required String assistant,
    List<String> tools = const [],
    String? provider,
    String? model,
  }) async {
    touch(sessionId);
    _messages.putIfAbsent(sessionId, () => <ChatMessage>[]);
    _messages[sessionId]!.addAll([
      ChatMessage(role: 'user', content: user),
      ChatMessage(role: 'assistant', content: assistant),
    ]);
  }

  @override
  Future<List<SessionInfo>> list() async => [
        for (final e in _sessions.entries)
          SessionInfo(
            id: e.key,
            channel: e.value.channel,
            userKey: e.value.userKey,
            updatedAt: e.value.updatedAt,
          ),
      ];
}

void main() {
  group('IdleCompactionConfig parse', () {
    test('default: off dengan nilai aman', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
      expect(issues, isEmpty);
      expect(cfg.idleCompaction.enabled, isFalse);
      expect(cfg.idleCompaction.afterSec, 3600);
      expect(cfg.idleCompaction.tickSec, 60);
      expect(cfg.idleCompaction.minMessages, 8);
      expect(cfg.idleCompaction.minTokens, 1000);
      expect(cfg.idleCompaction.channelOverrides, isEmpty);
    });

    test('parse penuh + override channel (0 = off)', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
idle_compaction:
  enabled: true
  after_sec: 900
  tick_sec: 30
  min_messages: 4
  min_tokens: 500
  channel_overrides:
    cli: 120
    telegram: 0
''');
      expect(issues, isEmpty);
      expect(cfg.idleCompaction.enabled, isTrue);
      expect(cfg.idleCompaction.afterSec, 900);
      expect(cfg.idleCompaction.tickSec, 30);
      expect(cfg.idleCompaction.minMessages, 4);
      expect(cfg.idleCompaction.minTokens, 500);
      expect(cfg.idleCompaction.channelOverrides['cli'], 120);
      expect(cfg.idleCompaction.channelOverrides['telegram'], 0);
    });

    test('override invalid non-fatal + scalar invalid ke default', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
idle_compaction:
  enabled: true
  after_sec: bukan-angka
  channel_overrides:
    web: "bukan-int"
    cli: 60
''');
      expect(issues.where((i) => i.fatal), isEmpty);
      expect(
        issues.any((i) =>
            i.path == 'idle_compaction.channel_overrides.web' && !i.fatal),
        isTrue,
      );
      expect(cfg.idleCompaction.afterSec, 3600);
      expect(cfg.idleCompaction.channelOverrides.keys, ['cli']);
    });
  });

  group('IdleCompactionEngine', () {
    late EventBus bus;
    late _FakeSessions sessions;
    late List<String> compacted;
    late Set<String> busy;
    DateTime now = DateTime.utc(2026, 12, 1, 12);

    setUp(() {
      bus = EventBus();
      now = DateTime.utc(2026, 12, 1, 12);
      sessions = _FakeSessions(() => now);
      compacted = <String>[];
      busy = <String>{};
    });

    tearDown(() async {
      await bus.close();
    });

    IdleCompactionEngine engine(
      IdleCompactionConfig cfg, {
      Future<bool> Function(
        String sid, {
        required String channel,
        required String userKey,
      })? compactOf,
    }) =>
        IdleCompactionEngine(
          config: cfg,
          events: bus,
          sessions: sessions,
          busyOf: busy.contains,
          compactOf: compactOf ??
              (sid, {required channel, required userKey}) async {
                compacted.add('$sid@$channel@$userKey');
                return true;
              },
          clock: () => now,
        );

    test('sesi idle melewati ambang dikompaksi; latch mencegah ulang',
        () async {
      await sessions.getOrCreate('s1', channel: 'cli', userKey: 'u');
      final t0 = now;
      now = t0.add(const Duration(hours: 2));
      final eng = engine(const IdleCompactionConfig(
        enabled: true,
        afterSec: 3600,
      ));
      await eng.runTick();
      expect(compacted, ['s1@cli@u']);
      expect(eng.compacted, 1);

      // Tick berikut tanpa aktivitas baru: tidak diulang (latched).
      now = now.add(const Duration(minutes: 30));
      await eng.runTick();
      expect(compacted, hasLength(1));

      // Aktivitas baru -> latch basi -> layak lagi.
      now = now.add(const Duration(minutes: 30));
      sessions.touch('s1');
      now = now.add(const Duration(hours: 2));
      await eng.runTick();
      expect(compacted, hasLength(2));
    });

    test('sesi sibuk dilewati tanpa latch', () async {
      await sessions.getOrCreate('s-busy', channel: 'cli', userKey: 'u');
      now = now.add(const Duration(hours: 2));
      busy.add('s-busy');
      final eng = engine(const IdleCompactionConfig(
        enabled: true,
        afterSec: 3600,
      ));
      await eng.runTick();
      expect(compacted, isEmpty);
      expect(eng.attempted, 0);
      // Lepas busy -> tick berikut jalan.
      busy.clear();
      await eng.runTick();
      expect(compacted, ['s-busy@cli@u']);
    });

    test('override channel: 0 = off channel itu, channel lain global',
        () async {
      await sessions.getOrCreate('s-cli', channel: 'cli', userKey: 'u');
      await sessions.getOrCreate('s-web', channel: 'web', userKey: 'u');
      now = now.add(const Duration(hours: 2));
      final eng = engine(const IdleCompactionConfig(
        enabled: true,
        afterSec: 3600,
        channelOverrides: {'cli': 0},
      ));
      await eng.runTick();
      expect(compacted, contains('s-web@web@u'));
      expect(compacted, isNot(contains('s-cli@cli@u')));
    });

    test('gagal kompaksi ter-latch (tidak retry tanpa aktivitas) + event jujur',
        () async {
      await sessions.getOrCreate('s-f', channel: 'cli', userKey: 'u');
      now = now.add(const Duration(hours: 2));
      final events = <Map<String, dynamic>>[];
      bus.stream
          .where((e) => e.type == 'compaction.idle')
          .listen((e) => events.add(Map<String, dynamic>.from(e.data)));
      final eng = engine(
        const IdleCompactionConfig(enabled: true, afterSec: 3600),
        compactOf: (
          _, {
          required String channel,
          required String userKey,
        }) async =>
            false,
      );
      await eng.runTick();
      expect(eng.failed, 1);
      now = now.add(const Duration(minutes: 10));
      await eng.runTick();
      expect(eng.attempted, 1);
      expect(events.single['outcome'], 'failed');
    });

    test('disabled / after_sec 0: tick tidak melakukan apa pun', () async {
      await sessions.getOrCreate('s-off', channel: 'cli', userKey: 'u');
      now = now.add(const Duration(hours: 5));
      final off = engine(const IdleCompactionConfig(enabled: false));
      await off.runTick();
      final zero =
          engine(const IdleCompactionConfig(enabled: true, afterSec: 0));
      await zero.runTick();
      expect(compacted, isEmpty);
      expect(off.attempted, 0);
      expect(zero.attempted, 0);
    });

    test('throw kompaksi tertelan (never-raises) — latch tetap terpasan',
        () async {
      await sessions.getOrCreate('s-x', channel: 'cli', userKey: 'u');
      now = now.add(const Duration(hours: 2));
      final eng = engine(
        const IdleCompactionConfig(enabled: true, afterSec: 3600),
        compactOf: (
          _, {
          required String channel,
          required String userKey,
        }) async =>
            throw StateError('provider meledak'),
      );
      await eng.runTick();
      expect(eng.failed, 1);
      expect(eng.compacted, 0);
      // Gagal tetap latch: tick berikut tanpa aktivitas baru tidak retry.
      now = now.add(const Duration(minutes: 10));
      await eng.runTick();
      expect(eng.attempted, 1);
    });
  });

  group('runtime wiring idle compaction', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('fase25_rt_');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Future<String> _prepare(String idleSection) async {
      final ws = temp.path;
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
$idleSection
''');
      return config.path;
    }

    test('enabled: engine terpasang + snapshot terekspos', () async {
      final configPath = await _prepare('''
idle_compaction:
  enabled: true
  after_sec: 600
  channel_overrides:
    cli: 120
''');
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      expect(rt.idleCompaction, isNotNull);
      final snap = rt.idleCompactionSnapshot();
      expect(snap['enabled'], isTrue);
      expect(snap['after_sec'], 600);
      expect((snap['channel_overrides'] as Map)['cli'], 120);
    });

    test('default: engine null + snapshot jujur disabled', () async {
      final configPath = await _prepare('');
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      expect(rt.idleCompaction, isNull);
      expect(rt.idleCompactionSnapshot(), {'enabled': false});
    });
  });

}
