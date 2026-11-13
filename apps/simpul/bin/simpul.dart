import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simpul_core/simpul_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(2);
  }
  final command = args.first;
  final rest = args.sublist(1);
  try {
    switch (command) {
      case 'generate':
        await _generate(rest);
      case 'index':
        await _index(rest);
      case 'search':
        await _search(rest);
      case 'health':
        await _health(rest);
      case 'links':
        await _links(rest);
      case 'bench':
        await _bench(rest);
      case '--help' || 'help' || '-h':
        _usage();
      default:
        stderr.writeln('perintah tidak dikenal: $command');
        _usage();
        exit(2);
    }
  } on ArgumentError catch (e) {
    stderr.writeln('argumen tidak valid: ${e.message}');
    exit(2);
  } catch (e) {
    stderr.writeln('gagal: $e');
    exit(1);
  }
}

void _usage() {
  stderr.writeln('''
Simpul — indeks vault Markdown lokal-first (kompatibel Obsidian).

Penggunaan:
  simpul generate --notes N --seed S --out DIR [--attachments N]
      Buat vault sintetis deterministik untuk benchmark (BM-01).
  simpul index <vault> [--out DIR]
      Indeks seluruh vault (default: <vault>/.simpul). Backend SQLite bila
      tersedia, otomatis fallback ke JSON.
  simpul search <vault> "kueri" [--limit N]
      Cari catatan. Dukungan: kata (AND), "frasa", tag:a/b, path:folder,
      prop:kunci=nilai, -kecualikan.
  simpul health <vault>
      Laporan kesehatan: catatan, tautan, tautan rusak, orphan, judul ganda.
  simpul links <vault> <path-catatan>
      Daftar backlink ke sebuah catatan.
  simpul bench <vault> [--iterations N]
      Benchmark scan/index/search/backlink/CSR (BM-01..BM-06).
''');
}

Map<String, String> _options(List<String> args, Set<String> flags) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final key = arg.substring(2);
    if (flags.contains(key)) {
      values[key] = 'true';
      continue;
    }
    if (i + 1 >= args.length) {
      throw ArgumentError('opsi --$key butuh nilai');
    }
    values[key] = args[++i];
  }
  return values;
}

String _positional(List<String> args) =>
    args.where((a) => !a.startsWith('--')).firstOrNull ??
    (throw ArgumentError('path vault wajib diisi'));

File _resolveIndexFile(String vault, String? outDir) {
  final dir = outDir ?? p.join(vault, '.simpul');
  final sqlite = p.join(dir, 'index.db');
  final json = p.join(dir, 'index.json');
  if (File(sqlite).existsSync()) return File(sqlite);
  if (File(json).existsSync()) return File(json);
  return File(sqlite);
}

Future<VaultIndex> _openIndex(String vault, String? outDir) async {
  final file = _resolveIndexFile(vault, outDir);
  if (p.extension(file.path) == '.json') {
    return JsonVaultIndex(file.path);
  }
  final sqlite = SqliteVaultIndex.tryOpen(file.path);
  if (sqlite != null) return sqlite;
  return JsonVaultIndex(p.setExtension(file.path, '.json'));
}

Future<void> _generate(List<String> args) async {
  final opts = _options(args, {});
  final notes = int.parse(opts['notes'] ?? '100');
  final seed = int.parse(opts['seed'] ?? '42');
  final out = opts['out'] ??
      (throw ArgumentError('opsi --out wajib diisi, contoh: --out vault-demo'));
  final attachments = int.parse(opts['attachments'] ?? '0');
  final manifest = await VaultGenerator(seed: seed).generate(
    out,
    notes,
    attachments: attachments,
  );
  stdout.writeln(jsonEncode(manifest.toJson()));
}

Future<void> _index(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final outDir = opts['out'];
  final watch = Stopwatch()..start();
  final notes = await VaultScanner.scan(vault);
  final scanned = watch.elapsedMilliseconds;
  final file = _resolveIndexFile(vault, outDir);
  final sqlite = SqliteVaultIndex.tryOpen(file.path);
  final index = sqlite ??
      JsonVaultIndex(p.setExtension(file.path, '.json'));
  try {
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
  } finally {
    await index.close();
  }
  watch.stop();
  stdout.writeln(jsonEncode({
    'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
    'index_file': index is SqliteVaultIndex ? file.path : p.setExtension(file.path, '.json'),
    'notes': notes.length,
    'scan_ms': scanned,
    'index_ms': watch.elapsedMilliseconds - scanned,
  }));
}

Future<void> _search(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul search <vault> "kueri"');
  }
  final vault = positional[0];
  final query = positional[1];
  final opts = _options(args, {});
  final limit = int.parse(opts['limit'] ?? '20');
  final index = await _openIndex(vault, opts['out']);
  try {
    final hits = await index.search(query, limit: limit);
    stdout.writeln(jsonEncode({
      'query': query,
      'hits': hits
          .map((h) => {
                'path': h.path,
                'title': h.title,
                'score': h.score,
                'heading_path': h.headingPath,
                'snippet': h.snippet,
              })
          .toList(),
    }));
  } finally {
    await index.close();
  }
}

Future<void> _health(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final index = await _openIndex(vault, opts['out']);
  try {
    final health = await index.health();
    stdout.writeln(jsonEncode({
      'note_count': health.noteCount,
      'link_count': health.linkCount,
      'broken_links': health.brokenLinks,
      'orphans': health.orphans,
      'duplicate_titles': health.duplicateTitles,
    }));
  } finally {
    await index.close();
  }
}

Future<void> _links(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul links <vault> <path-catatan>');
  }
  final vault = positional[0];
  var target = positional[1];
  if (target.startsWith('./')) target = target.substring(2);
  if (target.endsWith('.md')) target = target.substring(0, target.length - 3);
  final opts = _options(args, {});
  final index = await _openIndex(vault, opts['out']);
  try {
    final links = await index.backlinks(target);
    stdout.writeln(jsonEncode({'note': target, 'backlinks': links}));
  } finally {
    await index.close();
  }
}

Future<void> _bench(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final iterations = int.parse(opts['iterations'] ?? '50');
  final report = await BenchmarkRunner().run(
    vault,
    searchIterations: iterations,
  );
  stdout.writeln(jsonEncode(report));
}
