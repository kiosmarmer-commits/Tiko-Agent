import 'dart:convert';
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

  group('Hermes S9 — TUI settings layar penuh', () {
    const down = [0x1B, 0x5B, 0x42];
    const right = [0x1B, 0x5B, 0x43];
    const left = [0x1B, 0x5B, 0x44];
    const enter = [0x0D];

    List<List<int>> chunk(Object item) {
      if (item is List<int>) return [item];
      return [utf8.encode(item as String)];
    }

    test('render awal: sidebar kategori, panel detail, dan shortcut footer',
        () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable(chunk('q')),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('Pengaturan Tiko'));
      expect(out, contains('KATEGORI'));
      expect(out, contains('Provider utama'));
      expect(out, contains('Kategori: Provider'));
      expect(out, contains('←/→/Tab/Shift-Tab kategori'));
      expect(out, contains('/ cari · p preview · s simpan · r reset · q keluar'));
    });

    test('navigasi kategori kanan/kiri dan Tab berpindah grup', () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk(right),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('Kategori: Keamanan'));
      expect(out, contains('Mode keamanan'));

      final buf2 = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf2,
        inputStream: Stream.fromIterable([
          chunk(right),
          chunk(left),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      expect(buf2.toString(), contains('Kategori: Provider'));
    });

    test('pencarian / memfilter setting lintas kategori', () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk('/'),
          chunk('port'),
          chunk(enter),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('Cari: port'));
      expect(out, contains('Port API daemon'));
      expect(out, contains('Kategori: Provider'));
    });

    test('edit masuk daftar perubahan (dirty-state) lalu preview dan simpan',
        () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk(down),
          chunk(enter),
          chunk('gpt-9-tui'),
          chunk(enter),
          chunk('p'),
          chunk('s'),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('● 1 perubahan belum disimpan'));
      expect(out, contains('Provider *'));
      expect(out, contains('→ gpt-9-tui'));
      expect(out, contains('PREVIEW'));
      expect(out, contains('providers.chat.mock.model: (default) → gpt-9-tui'));
      expect(out, contains('OK: 1 perubahan tersimpan (revision 1)'));

      final (cfg, issues) = TikoConfig.load(configPath);
      expect(issues.any((i) => i.fatal), isFalse);
      expect(cfg.providers[cfg.defaultProvider]?.model, 'gpt-9-tui');
      final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
      expect(await store.currentRevision(), 1);
    });

    test('nilai tidak valid ditolak dan tidak masuk daftar perubahan',
        () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk(right),
          chunk(right),
          chunk(enter),
          chunk('99999'),
          chunk(enter),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('Kategori: Runtime'));
      expect(out, contains('harus integer 1 sampai 65535'));
      final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
      expect(await store.currentRevision(), 0);
    });

    test('r reset membuang perubahan; q saat dirty ditahan sekali', () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk(down),
          chunk(enter),
          chunk('draft-1'),
          chunk(enter),
          chunk('r'),
          chunk(enter),
          chunk('draft-2'),
          chunk(enter),
          chunk('q'),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('Perubahan tertunda dibuang.'));
      expect(out, contains('belum disimpan — s simpan, r buang'));
      final (cfg, issues) = TikoConfig.load(configPath);
      expect(issues.any((i) => i.fatal), isFalse);
      expect(cfg.providers[cfg.defaultProvider]?.model, isNot('draft-1'));
      final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
      expect(await store.currentRevision(), 0);
    });

    test('edit kosong membatalkan perubahan', () async {
      final buf = StringBuffer();
      await runSettingsMenu(
        configPath: configPath,
        revisionsDir: revisionsDir,
        out: buf,
        inputStream: Stream.fromIterable([
          chunk(down),
          chunk(enter),
          chunk(enter),
          chunk('q'),
        ].expand((e) => e)),
        color: false,
      );
      final out = buf.toString();
      expect(out, contains('(edit dibatalkan — kosong)'));
      final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
      expect(await store.currentRevision(), 0);
    });
  });
}
