import 'dart:io';

import 'package:path/path.dart' as p;

/// Operasi kurasi memori yang diminta model via blok ```memory-ops.
enum CuratedMemoryFile { memory, user }

enum CuratedMemoryOpKind { add, replace, remove }

class CuratedMemoryOp {
  CuratedMemoryOp({
    required this.kind,
    required this.file,
    this.find,
    this.text = '',
  });

  final CuratedMemoryOpKind kind;
  final CuratedMemoryFile file;
  final String? find;
  final String text;
}

class CuratedMemoryReport {
  CuratedMemoryReport({
    List<String>? applied,
    List<String>? rejected,
    this.cleanedReply,
    List<CuratedMemoryOp>? ops,
  })  : applied = List.of(applied ?? const <String>[]),
        rejected = List.of(rejected ?? const <String>[]),
        _ops = ops;

  final List<String> applied;
  final List<String> rejected;
  final String? cleanedReply;
  final List<CuratedMemoryOp>? _ops;

  bool get hasBlock => cleanedReply != null;
  bool get allRejected => applied.isEmpty && rejected.isNotEmpty;
}

/// Protokol teks satu-baris agar model dapat mengkurasi memori tanpa tool:
///
/// ```memory-ops
/// ADD MEMORY: fakta baru
/// ADD USER: preferensi pengguna
/// REPLACE MEMORY: teks lama => teks baru
/// REMOVE USER: teks yang dihapus
/// ```
class CuratedMemoryOps {
  static final _line = RegExp(r'^(ADD|REPLACE|REMOVE)\s+(MEMORY|USER):\s*(.*)$');
  static const blockMarker = 'memory-ops';

  /// Mengambil blok ```memory-ops pertama dari balasan model dan hasilkan
  /// daftar operasi. Baris tidak valid diabaikan. [cleanedReply] adalah
  /// balasan tanpa blok (untuk ditampilkan ke pengguna).
  static CuratedMemoryReport extract(String reply) {
    final pattern = RegExp(
      '```$blockMarker\\s*\\n(.*?)\\n?```',
      dotAll: true,
    );
    final match = pattern.firstMatch(reply);
    if (match == null) return CuratedMemoryReport();
    final ops = <CuratedMemoryOp>[];
    for (final raw in match.group(1)!.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = _line.firstMatch(line);
      if (m == null) continue;
      final kind = CuratedMemoryOpKind.values.firstWhere(
        (k) => k.name == m.group(1)!.toLowerCase(),
      );
      final file = m.group(2)!.toLowerCase() == 'user'
          ? CuratedMemoryFile.user
          : CuratedMemoryFile.memory;
      var rest = m.group(3)!.trim();
      String? find;
      if (kind == CuratedMemoryOpKind.replace) {
        final idx = rest.lastIndexOf(' => ');
        if (idx <= 0) continue;
        find = rest.substring(0, idx).trim();
        rest = rest.substring(idx + 4).trim();
        if (find.isEmpty || rest.isEmpty) continue;
      } else if (kind == CuratedMemoryOpKind.add && rest.isEmpty) {
        continue;
      }
      ops.add(CuratedMemoryOp(kind: kind, file: file, find: find, text: rest));
    }
    final cleaned =
        reply.replaceRange(match.start, match.end, '').trimRight();
    return CuratedMemoryReport(cleanedReply: cleaned.trim(), ops: ops);
  }

  static String encode(List<CuratedMemoryOp> ops) {
    final buf = StringBuffer('```$blockMarker\n');
    for (final op in ops) {
      final file = op.file == CuratedMemoryFile.user ? 'USER' : 'MEMORY';
      switch (op.kind) {
        case CuratedMemoryOpKind.add:
          buf.writeln('ADD $file: ${op.text}');
        case CuratedMemoryOpKind.replace:
          buf.writeln('REPLACE $file: ${op.find} => ${op.text}');
        case CuratedMemoryOpKind.remove:
          buf.writeln('REMOVE $file: ${op.find ?? op.text}');
      }
    }
    buf.write('```');
    return buf.toString();
  }
}

/// Memori terkurasi ala Hermes: dua file Markdown kecil (MEMORY.md fakta
/// durabel, USER.md profil pengguna) yang di-inject ke system prompt setiap
/// sesi. Budget karakter ketat memaksa kurasi, bukan akumulasi.
class CuratedMemoryStore {
  CuratedMemoryStore({
    required String dataDir,
    this.charBudget = 3575,
  })  : memoryPath = p.join(dataDir, 'memories', 'MEMORY.md'),
        userPath = p.join(dataDir, 'memories', 'USER.md');

  final String memoryPath;
  final String userPath;

  /// Total anggaran karakter kedua file (default setara Hermes).
  final int charBudget;

  String memoryText = '';
  String userText = '';

  int get usedChars => memoryText.length + userText.length;
  bool get isEmpty => memoryText.trim().isEmpty && userText.trim().isEmpty;

  Future<void> load() async {
    memoryText = await _read(memoryPath);
    userText = await _read(userPath);
  }

  Future<void> reload() => load();

  /// Blok system prompt; kosong (string kosong) bila belum ada memori.
  String snapshotPromptBlock() {
    if (isEmpty) return '';
    final buf = StringBuffer();
    if (memoryText.trim().isNotEmpty) {
      buf.writeln('Memori kurasi (MEMORY.md):');
      buf.writeln(memoryText.trim());
    }
    if (userText.trim().isNotEmpty) {
      buf.writeln('Profil pengguna (USER.md):');
      buf.writeln(userText.trim());
    }
    return buf.toString().trim();
  }

  /// Menerapkan operasi satu per satu; operasi yang membuat total karakter
  /// melebihi [charBudget] atau lolos filter [reject] ditolak, bukan
  /// memotong konten lama.
  CuratedMemoryReport apply(
    CuratedMemoryReport report, {
    String? Function(CuratedMemoryOp op)? reject,
  }) {
    for (final op in _opsOf(report)) {
      final external = reject?.call(op);
      if (external != null) {
        report.rejected.add('${_describe(op)} — $external');
        continue;
      }
      final reason = _applyOne(op);
      if (reason == null) {
        report.applied.add(_describe(op));
      } else {
        report.rejected.add('${_describe(op)} — $reason');
      }
    }
    return report;
  }

  List<CuratedMemoryOp> _opsOf(CuratedMemoryReport report) =>
      report._ops ?? const [];

  String? _applyOne(CuratedMemoryOp op) {
    final current = op.file == CuratedMemoryFile.user ? userText : memoryText;
    String next;
    switch (op.kind) {
      case CuratedMemoryOpKind.add:
        next = current.isEmpty ? op.text : '$current\n${op.text}';
      case CuratedMemoryOpKind.replace:
        final idx = current.indexOf(op.find!);
        if (idx < 0) return 'teks tidak ditemukan';
        next = current.replaceRange(idx, idx + op.find!.length, op.text);
      case CuratedMemoryOpKind.remove:
        final idx = current.indexOf(op.find ?? op.text);
        if (idx < 0) return 'teks tidak ditemukan';
        final end = idx + (op.find ?? op.text).length;
        next = (current.substring(0, idx) + current.substring(end))
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
    }
    final projected = (op.file == CuratedMemoryFile.user
            ? memoryText.length + next.length
            : next.length + userText.length)
        .clamp(0, 1 << 31);
    if (projected > charBudget) {
      return 'melebihi anggaran $charBudget karakter';
    }
    if (op.file == CuratedMemoryFile.user) {
      userText = next;
    } else {
      memoryText = next;
    }
    return null;
  }

  String _describe(CuratedMemoryOp op) {
    final file = op.file == CuratedMemoryFile.user ? 'USER' : 'MEMORY';
    final preview = (op.kind == CuratedMemoryOpKind.replace
            ? op.text
            : (op.find ?? op.text))
        .replaceAll('\n', ' ');
    final short = preview.length > 40 ? '${preview.substring(0, 40)}…' : preview;
    return '${op.kind.name.toUpperCase()} $file: $short';
  }

  Future<void> save() async {
    await _writeAtomic(memoryPath, memoryText);
    await _writeAtomic(userPath, userText);
  }

  Future<void> clear() async {
    memoryText = '';
    userText = '';
    await save();
  }

  static Future<String> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on PathNotFoundException {
      return '';
    }
  }

  static Future<void> _writeAtomic(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = '$path.${DateTime.now().microsecondsSinceEpoch}.tmp';
    await File(tmp).writeAsString(content, flush: true);
    try {
      await File(tmp).rename(path);
    } on FileSystemException {
      await File(tmp).copy(path);
      await File(tmp).delete();
    }
  }
}

