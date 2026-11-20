import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko/settings_menu.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late Directory tmp;
  late String configPath;
  late String revisionsDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko-settings');
    configPath = p.join(tmp.path, 'agent.yaml');
    await File(configPath).writeAsString(
      TikoConfig.setupYaml(provider: 'mock', workspace: tmp.path),
    );
    revisionsDir = p.join(tmp.path, 'revisions');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('panel dirender dengan judul dan nomor field', () async {
    final buf = StringBuffer();
    await runSettingsMenu(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: buf,
      scriptedLines: ['q'],
      color: false,
    );
    final out = buf.toString();
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.any((i) => i.fatal), isFalse);
    expect(out, contains('Pengaturan Tiko'));
    expect(out, contains('1  Provider utama: ${cfg.defaultProvider}'));
    expect(out, contains('Mode keamanan'));
    expect(out, contains('tiko config rollback'));
  });

  test('ubah model dan fitur disimpan ber-revisi via ConfigStore', () async {
    final buf = StringBuffer();
    await runSettingsMenu(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: buf,
      scriptedLines: ['2', 'gpt-5-mini', '8', 'true', 'q'],
      color: false,
    );
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.any((i) => i.fatal), isFalse);
    expect(cfg.providers[cfg.defaultProvider]?.model, 'gpt-5-mini');
    expect(cfg.enableImageGeneration, isTrue);
    final store = ConfigStore(
      configPath: configPath,
      revisionsDir: revisionsDir,
    );
    expect(await store.currentRevision(), 2);
    expect(buf.toString(), contains('OK providers.chat'));
  });

  test('input tidak valid tidak mengubah config', () async {
    final buf = StringBuffer();
    await runSettingsMenu(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: buf,
      scriptedLines: ['99', 'x', '6', '99999', 'q'],
      color: false,
    );
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.any((i) => i.fatal), isFalse);
    expect(cfg.apiPort, 8787);
    final store = ConfigStore(
      configPath: configPath,
      revisionsDir: revisionsDir,
    );
    expect(await store.currentRevision(), 0);
    expect(buf.toString(), contains('Pilihan tidak valid.'));
    expect(buf.toString(), contains('harus integer 1 sampai 65535'));
  });

  test('pilih provider disabled ditolak dengan pesan jelas', () async {
    final buf = StringBuffer();
    await runSettingsMenu(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: buf,
      scriptedLines: ['1', 'ollama_local', 'q'],
      color: false,
    );
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.any((i) => i.fatal), isFalse);
    expect(cfg.providers['ollama_local']?.enabled, anyOf(isFalse, isNull));
    final store = ConfigStore(
      configPath: configPath,
      revisionsDir: revisionsDir,
    );
    expect(await store.currentRevision(), 0);
    expect(buf.toString(), contains('disabled'));
  });

  test('input kosong membatalkan perubahan', () async {
    final buf = StringBuffer();
    await runSettingsMenu(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: buf,
      scriptedLines: ['6', '', 'q'],
      color: false,
    );
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.any((i) => i.fatal), isFalse);
    expect(cfg.apiPort, 8787);
    expect(buf.toString(), contains('(batal'));
  });
}
