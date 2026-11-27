// Hermes fase-9 (C6): wiring `account_usage_cache` ke runtime — snapshot
// usage langganan akun dirender di `/usage` secara jujur (basah = usang,
// kosong = tidak pernah disimpan).
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 4
''');
  return config.path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase9_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('/usage tanpa snapshot: baris jujur "belum ada snapshot"', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/usage');
    expect(out, contains('Usage akun provider: belum ada snapshot.'));
  });

  test('snapshot fresh dirender; snapshot basah ditandai usang', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    rt.accountUsage.remember(
      'mock',
      AccountUsageSnapshot(
        provider: 'mock',
        source: 'api',
        fetchedAt: DateTime.now(),
        plan: 'pro',
        windows: [
          const AccountUsageWindow(label: 'harian', usedPercent: 37.5),
        ],
      ),
    );
    var out = await rt.chat('/usage');
    expect(out, contains('Usage akun provider:'));
    expect(out, contains('mock (api)'));
    expect(out, contains('harian: 37.5%'));

    rt.accountUsage.remember(
      'mock',
      AccountUsageSnapshot(
        provider: 'mock',
        source: 'api',
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 20)),
        windows: [
          const AccountUsageWindow(label: 'harian', usedPercent: 99),
        ],
      ),
    );
    out = await rt.chat('/usage');
    // remember menolak snapshot basah? Tidak — remember menolak snapshot
    // TANPA window; snapshot basah tetap disimpan tapi dirender usang.
    expect(out, contains('usang — tidak diketahui'));
  });

  test('fetch gagal tidak menghapus snapshot lama (integritas cache)',
      () async {
    final cache = AccountUsageCache();
    final fresh = AccountUsageSnapshot(
      provider: 'p',
      source: 'api',
      fetchedAt: DateTime.now(),
      windows: [const AccountUsageWindow(label: 'w', usedPercent: 5)],
    );
    cache.remember('p', fresh, startedMonotonic: 100);
    // Fetch lama yang terlambat tiba tidak boleh menggantikan.
    final stale = AccountUsageSnapshot(
      provider: 'p',
      source: 'api',
      fetchedAt: DateTime.now(),
      windows: [const AccountUsageWindow(label: 'w', usedPercent: 80)],
    );
    cache.remember('p', stale, startedMonotonic: 50);
    expect(cache.cached('p')!.windows.first.usedPercent, 5);
  });
}
