import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class RecordingPlugin extends Plugin {
  RecordingPlugin(this.name, {this.failOn = ''});

  @override
  final String name;
  final String failOn;
  final List<String> calls = [];

  @override
  Future<void> init() async {
    if (failOn == 'init') throw StateError('init boom');
    calls.add('init');
  }

  @override
  Future<HookVerdict> beforeToolCall(ToolHookInput input) async {
    calls.add('before:${input.toolName}');
    if (failOn == 'before') throw StateError('before boom');
    if (input.toolName == 'dangerous') {
      return HookVerdict.deny(reason: 'blokir oleh ${name}');
    }
    if (input.toolName == 'rewritable') {
      return HookVerdict.modify({'rewritten': true});
    }
    return const HookVerdict.allow();
  }

  @override
  Future<void> afterToolCall(ToolHookInput input, String result,
      bool isError) async {
    calls.add('after:${input.toolName}:$isError');
  }
}

class CountingMemoryProvider implements MemoryProvider {
  final Map<String, MemoryRecord> store = {};

  @override
  String get name => 'counting';

  @override
  Future<void> upsert(MemoryRecord record) async {
    store[record.id] = record;
  }

  @override
  Future<List<MemoryRecord>> search(String query,
      {int k = 8, String? ownerKey}) async {
    final hits = store.values
        .where((r) => r.text.toLowerCase().contains(query.toLowerCase()))
        .take(k)
        .toList();
    return hits;
  }

  @override
  Future<void> forget(String id) async => store.remove(id);
}

void main() {
  test('register calls init and replaces same-name plugins', () async {
    final registry = PluginRegistry();
    final first = RecordingPlugin('dup');
    final second = RecordingPlugin('dup');
    await registry.register(first);
    await registry.register(second);
    expect(registry.length, 1);
    expect(first.calls, ['init']);
    expect(registry.has('dup'), isTrue);
  });

  test('init failure is isolated and plugin still registered', () async {
    final registry = PluginRegistry();
    final broken = RecordingPlugin('broken', failOn: 'init');
    await registry.register(broken);
    expect(registry.length, 1);
    expect(registry.events, hasLength(1));
    expect(registry.events.first.error, isA<StateError>());
  });

  test('beforeToolCall chain: first denial wins', () async {
    final registry = PluginRegistry()
      ..register(RecordingPlugin('a'))
      ..register(RecordingPlugin('b'));
    final verdict = await registry.dispatchBeforeToolCall(
      const ToolHookInput(
          toolName: 'dangerous', args: {}, sessionId: 's1'),
    );
    expect(verdict.allowed, isFalse);
    expect(verdict.reason, contains('blokir oleh a'));
  });

  test('arg modification chains through hooks', () async {
    final registry = PluginRegistry()..register(RecordingPlugin('a'));
    final verdict = await registry.dispatchBeforeToolCall(
      const ToolHookInput(
          toolName: 'rewritable', args: {'x': 1}, sessionId: 's1'),
    );
    expect(verdict.allowed, isTrue);
    expect(verdict.modifiedArgs, {'rewritten': true});
  });

  test('hook exception does not break dispatch', () async {
    final registry = PluginRegistry()
      ..register(RecordingPlugin('broken', failOn: 'before'))
      ..register(RecordingPlugin('healthy'));
    final verdict = await registry.dispatchBeforeToolCall(
      const ToolHookInput(toolName: 'safe', args: {}, sessionId: 's1'),
    );
    expect(verdict.allowed, isTrue);
    expect(registry.events, hasLength(1));
    expect(
        (registry.get('healthy') as RecordingPlugin).calls,
        contains('before:safe'));
  });

  test('lifecycle and message dispatch reach all plugins', () async {
    final registry = PluginRegistry();
    final a = RecordingPlugin('a');
    final b = RecordingPlugin('b');
    await registry.register(a);
    await registry.register(b);
    await registry.dispatchSessionStart('s1');
    await registry.dispatchMessage('s1', 'halo', fromUser: true);
    await registry.dispatchAfterToolCall(
      const ToolHookInput(toolName: 't', args: {}, sessionId: 's1'),
      'ok',
      false,
    );
    await registry.disposeAll();
    for (final plugin in [a, b]) {
      expect(plugin.calls, containsAll(['init', 'after:t:false']));
    }
    expect(registry.length, 0);
  });

  test('unregister disposes and removes', () async {
    final registry = PluginRegistry();
    final plugin = RecordingPlugin('temp');
    await registry.register(plugin);
    await registry.unregister('temp');
    expect(registry.length, 0);
  });

  test('MemoryRecord json round trip', () {
    const record = MemoryRecord(
      id: 'm1',
      text: 'preferensi user',
      score: 0.8,
      ownerKey: 'u1',
      tags: ['pref'],
    );
    final back = MemoryRecord.fromJson(record.toJson());
    expect(back.id, 'm1');
    expect(back.score, 0.8);
    expect(back.tags, ['pref']);
  });

  test('CountingMemoryProvider search filters by text', () async {
    final provider = CountingMemoryProvider();
    await provider.upsert(const MemoryRecord(id: '1', text: 'suka kopi'));
    await provider.upsert(const MemoryRecord(id: '2', text: 'suka teh'));
    final hits = await provider.search('kopi');
    expect(hits, hasLength(1));
    expect(hits.single.id, '1');
    await provider.forget('1');
    expect(provider.store, hasLength(1));
  });

  group('PluginManifest', () {
    test('valid manifest passes structural validation', () {
      final manifest = PluginManifest(
        name: 'my-plugin',
        version: '1.2.3',
        permissions: const [PluginPermission.memoryRead],
        dependencies: const ['other-plugin'],
      );
      expect(manifest.validate(), isEmpty);
    });

    test('rejects bad names, versions and unknown permissions', () {
      final manifest = PluginManifest.fromJson({
        'name': 'Bad Name!',
        'version': '1.0',
        'permissions': ['memory.read', 'root.shell'],
      });
      final problems = manifest.validate();
      expect(problems, hasLength(3));
      expect(problems.any((p) => p.contains('nama plugin')), isTrue);
      expect(problems.any((p) => p.contains('versi')), isTrue);
      expect(problems.any((p) => p.contains('root.shell')), isTrue);
    });

    test('self-dependency and duplicates are rejected', () {
      final manifest = PluginManifest(
        name: 'a',
        version: '0.1.0',
        dependencies: const ['a', 'b', 'b'],
      );
      final problems = manifest.validate();
      expect(problems.any((p) => p.contains('dirinya sendiri')), isTrue);
      expect(problems.any((p) => p.contains('duplikat')), isTrue);
    });

    test('validateAgainst requires all dependencies registered', () {
      final registry = PluginRegistry();
      final manifest = PluginManifest(
        name: 'child',
        version: '0.1.0',
        dependencies: const ['parent'],
      );
      expect(manifest.validateAgainst(registry), isNotEmpty);
    });

    test('JSON roundtrip keeps permissions and dependencies', () {
      final manifest = PluginManifest(
        name: 'round-trip',
        version: '2.0.1',
        permissions: [PluginPermission.networkFetch, PluginPermission.toolsExecute],
        dependencies: ['base'],
        description: 'uji',
      );
      final restored = PluginManifest.fromJson(manifest.toJson());
      expect(restored.name, 'round-trip');
      expect(restored.version, '2.0.1');
      expect(restored.permissions, manifest.permissions);
      expect(restored.dependencies, ['base']);
    });
  });
}
