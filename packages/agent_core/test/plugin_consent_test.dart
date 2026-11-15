import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String consentPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko-consent-');
    consentPath = '${tmp.path}/plugins/consents.json';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('fail-closed: permission belum ditanyakan dianggap ditolak', () async {
    final store = PluginConsentStore(path: consentPath);
    await store.load();
    expect(store.allGranted('plug-a', ['tools.read']), isFalse);
    expect(store.hasAnyGrant('plug-a'), isFalse);
  });

  test('grant + persist + reload dari file', () async {
    final store = PluginConsentStore(path: consentPath);
    await store.load();
    await store.grant('plug-a', ['tools.read', 'memory.read']);

    expect(await File(consentPath).exists(), isTrue);
    final onDisk =
        jsonDecode(await File(consentPath).readAsString()) as Map<String, dynamic>;
    expect(onDisk['plug-a'], isA<List<dynamic>>());

    final reloaded = PluginConsentStore(path: consentPath);
    await reloaded.load();
    expect(reloaded.allGranted('plug-a', ['tools.read', 'memory.read']), isTrue);
    expect(reloaded.allGranted('plug-a', ['tools.read', 'network.fetch']), isFalse);
    expect(reloaded.grantsOf('plug-a'), unorderedEquals(['memory.read', 'tools.read']));
  });

  test('revoke menghapus permission dan entri kosong', () async {
    final store = PluginConsentStore(path: consentPath);
    await store.load();
    await store.grant('plug-a', ['tools.read', 'memory.read']);

    await store.revoke('plug-a', permissions: ['memory.read']);
    expect(store.allGranted('plug-a', ['memory.read']), isFalse);
    expect(store.allGranted('plug-a', ['tools.read']), isTrue);

    await store.revoke('plug-a');
    expect(store.hasAnyGrant('plug-a'), isFalse);
    expect(store.grantsOf('plug-a'), isEmpty);
  });

  test('consentGuard registry: register ditolak lalu diterima setelah grant',
      () async {
    final store = PluginConsentStore(path: consentPath);
    await store.load();
    final registry = PluginRegistry()
      ..consentGuard = (name, requested) =>
          requested.isEmpty || store.allGranted(name, requested);

    final plugin = _NoopPlugin('plug-a');
    final denied = await registry.register(
      plugin,
      requestedPermissions: ['tools.read'],
    );
    expect(denied, isFalse);
    expect(registry.has('plug-a'), isFalse);
    expect(registry.events.last.detail, 'consent denied');

    await store.grant('plug-a', ['tools.read']);
    final allowed = await registry.register(
      plugin,
      requestedPermissions: ['tools.read'],
    );
    expect(allowed, isTrue);
    expect(registry.has('plug-a'), isTrue);
  });

  test('consentGuard: permission kosong otomatis diizinkan', () async {
    final store = PluginConsentStore(path: consentPath);
    await store.load();
    final registry = PluginRegistry()
      ..consentGuard = (name, requested) =>
          requested.isEmpty || store.allGranted(name, requested);

    final ok = await registry.register(_NoopPlugin('plug-b'));
    expect(ok, isTrue);
    expect(registry.has('plug-b'), isTrue);
  });
}

class _NoopPlugin extends Plugin {
  _NoopPlugin(this.name);

  @override
  final String name;
}
