import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simpul/tui/commands.dart';
import 'package:tiko_tui/tiko_tui.dart';
import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-tui-test');
    vault = p.join(tmp.path, 'vault');
    final alpha = File(p.join(vault, 'alpha.md'));
    await alpha.parent.create(recursive: true);
    await alpha.writeAsString('# Alpha\n\nIsi alpha menyebut [[beta]].\n');
    await File(p.join(vault, 'beta.md'))
        .writeAsString('---\ntags: [proyek]\n---\n# Beta\n\nIsi beta.\n');
    final index = JsonVaultIndex(p.join(vault, '.simpul', 'index.json'));
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll([for (final n in notes) n.toIndexed()]);
    await index.close();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  TuiCommands make() => TuiCommands(vault: vault);

  test('/help mencantumkan semua perintah', () async {
    final outcome = await make().run('/help');
    expect(outcome.lines.join('\n'), contains('/search'));
    expect(outcome.lines.join('\n'), contains('/ask'));
  });

  test('/search mengembalikan hasil ber-path', () async {
    final outcome = await make().run('/search alpha');
    expect(outcome.lines.join(' '), contains('alpha.md'));
  });

  test('/links menampilkan backlink', () async {
    final outcome = await make().run('/links beta.md');
    expect(outcome.lines.join(' '), contains('alpha.md'));
  });

  test('/health dan /stats memakai indeks', () async {
    final health = await make().run('/health');
    expect(health.lines.first, contains('catatan: 2'));
    final stats = await make().run('/stats');
    expect(stats.lines.join(' '), contains('#proyek'));
  });

  test('/ask menjawab ekstraktif dengan sitasi', () async {
    final outcome = await make().run('/ask apa isi alpha');
    expect(outcome.lines, isNotEmpty);
  });

  test('/open berganti vault dan menolak path tak ada', () async {
    final commands = make();
    final bad = await commands.run('/open /tidak/ada');
    expect(bad.lines.first, contains('tidak ditemukan'));
    final ok = await commands.run('/open $vault');
    expect(ok.lines.first, contains('vault aktif'));
    expect(commands.vault, vault);
  });

  test('teks pola diperlakukan sebagai /ask', () async {
    final outcome = await make().run('isi alpha');
    expect(outcome.lines, isNotEmpty);
  });

  test('perintah tidak dikenal memberi saran /help', () async {
    final outcome = await make().run('/bukan');
    expect(outcome.lines.first, contains('/help'));
  });

  test('complete: slash command dan path catatan', () {
    final commands = make();
    expect(
      commands.complete('', '/s'),
      ['/search', '/stats'],
    );
    final paths = commands.complete('', 'alp');
    expect(paths, contains('alpha.md'));
  });

  test('TuiHistoryStore menyimpan dan memuat dengan batas', () async {
    final store = TuiHistoryStore(p.join(tmp.path, 'hist.txt'));
    await store.save(List.generate(600, (i) => 'cmd-$i'));
    final loaded = store.load(limit: 100);
    expect(loaded.length, 100);
    expect(loaded.last, 'cmd-599');
  });
}
