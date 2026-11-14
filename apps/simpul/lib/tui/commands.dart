import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simpul_core/simpul_core.dart';
import 'package:tiko_tui/tiko_tui.dart';

/// Executes TUI slash-commands against a vault. Pure-ish (I/O only on the
/// vault itself) so the command surface is unit-testable without a tty.
class TuiCommands {
  TuiCommands({required this.vault, this.embedder = 'hashing'});

  String vault;
  String embedder;
  final List<String> history = [];

  static const commands = [
    '/help',
    '/open',
    '/search',
    '/links',
    '/health',
    '/ask',
    '/stats',
    '/history',
    '/clear',
    '/quit',
  ];

  static const helpLines = [
    'Perintah:',
    '  /help                        bantuan ini',
    '  /open <vault>                ganti vault aktif',
    '  /search <kueri>              pencarian leksikal (tag:, path:, prop:, -)',
    '  /links <catatan>             backlink sebuah catatan',
    '  /health                      laporan kesehatan vault',
    '  /ask <pertanyaan>            RAG dengan sitasi (tanpa --llm: ekstraktif)',
    '  /stats                       jumlah catatan, tautan, tag',
    '  /history                     riwayat perintah sesi ini',
    '  /clear                       bersihkan layar',
    '  /quit                        keluar (atau Ctrl+D)',
    'Multiline: akhiri baris dengan \\ untuk lanjut, atau blok /begin … /end.',
    'Tab melengkapi perintah dan path catatan; ↑/↓ menelusuri riwayat.',
    'Teks apa pun tanpa "/" diperlakukan sebagai /ask.',
  ];

  /// Completes slash-commands and note paths inside the vault.
  List<String> complete(String prefix, String token) {
    if (prefix.isEmpty && token.startsWith('/')) {
      return [
        for (final command in commands)
          if (command.startsWith(token)) command,
      ];
    }
    if (token.startsWith('/')) {
      return [
        for (final command in commands)
          if (command.startsWith(token)) command,
      ];
    }
    return _notePaths()
        .where((path) => path.toLowerCase().contains(token.toLowerCase()))
        .toList();
  }

  List<String> _notePaths() {
    final dir = Directory(vault);
    if (!dir.existsSync()) return const [];
    final paths = <String>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final relative = p.relative(entity.path, from: vault).replaceAll('\\', '/');
      if (relative.split('/').any((s) => s.startsWith('.'))) continue;
      paths.add(relative);
    }
    return paths;
  }

  Future<TuiOutcome> run(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const TuiOutcome([]);
    if (trimmed.startsWith('/')) {
      history.add(trimmed);
      final space = trimmed.indexOf(' ');
      final command = space == -1 ? trimmed : trimmed.substring(0, space);
      final argument = space == -1 ? '' : trimmed.substring(space + 1).trim();
      return _runCommand(command, argument);
    }
    history.add(trimmed);
    return _ask(trimmed);
  }

  Future<TuiOutcome> _runCommand(String command, String argument) async {
    switch (command) {
      case '/help':
        return const TuiOutcome(helpLines);
      case '/quit' || '/exit':
        return const TuiOutcome(['sampai jumpa.'], exit: true);
      case '/clear':
        return const TuiOutcome([], clear: true);
      case '/history':
        return TuiOutcome([
          for (var i = 0; i < history.length; i++)
            '${(i + 1).toString().padLeft(3)}  ${history[i]}',
        ]);
      case '/open':
        if (argument.isEmpty) {
          return const TuiOutcome(['pakai: /open <vault>']);
        }
        if (!Directory(argument).existsSync()) {
          return TuiOutcome(['vault tidak ditemukan: $argument']);
        }
        vault = argument;
        return TuiOutcome(['vault aktif: $vault']);
      case '/search':
        if (argument.isEmpty) {
          return const TuiOutcome(['pakai: /search <kueri>']);
        }
        return _search(argument);
      case '/links':
        if (argument.isEmpty) {
          return const TuiOutcome(['pakai: /links <catatan>']);
        }
        return _links(argument);
      case '/health':
        return _health();
      case '/stats':
        return _stats();
      case '/ask':
        if (argument.isEmpty) {
          return const TuiOutcome(['pakai: /ask <pertanyaan>']);
        }
        return _ask(argument);
      default:
        return TuiOutcome([
          'perintah tidak dikenal: $command (coba /help)',
        ]);
    }
  }

  Future<TuiOutcome> _search(String query) async {
    final index = await _openIndex();
    try {
      final hits = await index.search(query, limit: 10);
      if (hits.isEmpty) return const TuiOutcome(['tidak ada hasil.']);
      return TuiOutcome([
        for (final hit in hits)
          '${hit.path}  (skor ${hit.score.toStringAsFixed(3)}) '
              '${hit.snippet.replaceAll('\n', ' ')}',
      ]);
    } finally {
      await index.close();
    }
  }

  Future<TuiOutcome> _links(String notePath) async {
    final index = await _openIndex();
    try {
      final backlinks = await index.backlinks(_normalize(notePath));
      if (backlinks.isEmpty) {
        return TuiOutcome(['tidak ada backlink ke $notePath']);
      }
      return TuiOutcome([
        'backlink ke $notePath:',
        for (final backlink in backlinks) '  ← $backlink',
      ]);
    } finally {
      await index.close();
    }
  }

  Future<TuiOutcome> _health() async {
    final index = await _openIndex();
    try {
      final health = await index.health();
      return TuiOutcome([
        'catatan: ${health.noteCount}, tautan: ${health.linkCount}, '
            'rusak: ${health.brokenLinks.length}, '
            'orphan: ${health.orphans.length}, '
            'judul ganda: ${health.duplicateTitles.length}',
        for (final entry in health.brokenLinks.entries.take(10))
          '  rusak: ${entry.key} ×${entry.value}',
        for (final orphan in health.orphans.take(10)) '  orphan: $orphan',
        for (final entry in health.duplicateTitles.entries.take(10))
          '  ganda: ${entry.key} ×${entry.value}',
      ]);
    } finally {
      await index.close();
    }
  }

  Future<TuiOutcome> _stats() async {
    final notes = await VaultScanner.scan(vault);
    final tags = <String, int>{};
    var links = 0;
    for (final note in notes) {
      links += note.parsed.links.length;
      for (final tag in note.parsed.tags) {
        tags[tag] = (tags[tag] ?? 0) + 1;
      }
    }
    final top = tags.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return TuiOutcome([
      'vault: $vault',
      'catatan: ${notes.length}, tautan: $links, tag unik: ${tags.length}',
      for (final entry in top.take(10))
        '  #${entry.key} ×${entry.value}',
    ]);
  }

  Future<TuiOutcome> _ask(String question) async {
    final index = await _openIndex();
    try {
      final vectorsFile = File(p.join(vault, '.simpul', 'vectors.json'));
      final EmbeddingProvider embedder = HashingEmbedder();
      InMemorySemanticIndex? semantic;
      if (vectorsFile.existsSync()) {
        semantic = InMemorySemanticIndex(
          embedder,
          filePath: vectorsFile.path,
        );
      }
      try {
        final answer = await VaultAnswerer(
          index: index,
          embedder: embedder,
          semantic: semantic,
        ).ask(question);
        return TuiOutcome([
          answer.answer,
          if (answer.citations.isNotEmpty)
            for (var i = 0; i < answer.citations.length; i++)
              '  [${i + 1}] ${answer.citations[i].path} '
                  '${answer.citations[i].headingPath}',
        ]);
      } finally {
        await semantic?.close();
      }
    } finally {
      await index.close();
    }
  }

  Future<VaultIndex> _openIndex() async {
    final dir = p.join(vault, '.simpul');
    final sqlite = File(p.join(dir, 'index.db'));
    final json = File(p.join(dir, 'index.json'));
    final file = sqlite.existsSync() ? sqlite : json;
    if (!file.existsSync()) {
      throw StateError(
        'vault belum diindeks — jalankan: simpul index $vault',
      );
    }
    if (p.extension(file.path) == '.json') {
      return JsonVaultIndex(file.path);
    }
    final opened = SqliteVaultIndex.tryOpen(file.path);
    if (opened == null) {
      throw StateError(
        'backend sqlite tidak tersedia di perangkat ini '
        '(indeks: ${file.path})',
      );
    }
    return opened;
  }

  String _normalize(String notePath) {
    var path = notePath.replaceAll('\\', '/');
    if (!path.endsWith('.md')) path = '$path.md';
    return path;
  }
}
