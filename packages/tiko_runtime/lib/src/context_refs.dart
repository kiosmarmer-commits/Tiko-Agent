import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Hermes-parity P3: ekspansi `@` context references di pesan chat.
///
/// Sintaks (satu token, tanpa spasi):
/// - `@file:<rel>`   — isi file teks dari workspace.
/// - `@folder:<rel>` — listing folder (bounded).
/// - `@git-diff`     — `git diff HEAD` workspace.
/// - `@url:<http(s)://…>` — GET URL (bounded).
///
/// Keamanan (fail-closed):
/// - Path harus relatif, di dalam workspace, tanpa `..`/`~` (divalidasi
///   ulang setelah normalisasi).
/// - Seluruh sumber dibatasi ukuran; format biner ditolak.
/// - Referensi invalid DILOMPATI dengan penanda error eksplisit inline —
///   pesan tetap terkirim dan agent/user melihat alasannya; tidak ada
///   konten yang diam-diam bocor ke luar workspace.
/// - Maksimum 8 referensi per pesan dan budget total gabungan.
class ContextExpansion {
  ContextExpansion(this.text, this.refs);

  final String text;
  final List<Map<String, dynamic>> refs;
}

class _ContextRefLimits {
  static const maxRefs = 8;
  static const maxFileBytes = 64 * 1024;
  static const maxFolderEntries = 200;
  static const maxFolderDepth = 3;
  static const maxTotalBytes = 96 * 1024;
}

class _RefResult {
  _RefResult(this.text, {this.bytes, this.error});

  final String text;
  final int? bytes;
  final String? error;
}

Future<ContextExpansion> expandContextRefs(
  String input, {
  required String workspace,
}) async {
  final wsAbs = p.normalize(p.absolute(workspace));
  final refs = <Map<String, dynamic>>[];
  var totalBytes = 0;
  var outsideFence = true;

  final buf = StringBuffer();
  for (final line in input.split('\n')) {
    final isFence = line.trimLeft().startsWith('```');
    if (isFence) {
      outsideFence = !outsideFence;
      buf.writeln(line);
      continue;
    }
    if (!outsideFence || !line.contains('@')) {
      buf.writeln(line);
      continue;
    }
    final re = RegExp(r'@(file|folder|url):([^\s`]+)|@git-diff\b');
    var last = 0;
    for (final match in re.allMatches(line)) {
      buf.write(line.substring(last, match.start));
      last = match.end;
      final literal = match.group(0)!;
      if (refs.length >= _ContextRefLimits.maxRefs) {
        refs.add({
          'ref': literal,
          'kind': 'unknown',
          'status': 'error',
          'error': 'maks ${_ContextRefLimits.maxRefs} referensi per pesan',
        });
        buf.write(literal);
        continue;
      }
      final kind =
          literal.startsWith('@git-diff') ? 'git-diff' : match.group(1)!;
      final arg = match.group(2);
      String replacement;
      if (kind == 'file') {
        final r = _expandFile(arg!, wsAbs);
        _record(refs, r, kind, literal);
        totalBytes += r.bytes ?? 0;
        replacement = totalBytes > _ContextRefLimits.maxTotalBytes
            ? '[@$kind:$arg gagal: budget context penuh]'
            : r.text;
      } else if (kind == 'folder') {
        final r = _expandFolder(arg!, wsAbs);
        _record(refs, r, kind, literal);
        totalBytes += r.bytes ?? 0;
        replacement = totalBytes > _ContextRefLimits.maxTotalBytes
            ? '[@$kind:$arg gagal: budget context penuh]'
            : r.text;
      } else if (kind == 'url') {
        final r = await _expandUrl(arg!);
        _record(refs, r, kind, literal);
        totalBytes += r.bytes ?? 0;
        replacement = totalBytes > _ContextRefLimits.maxTotalBytes
            ? '[@$kind:$arg gagal: budget context penuh]'
            : r.text;
      } else {
        final r = await _expandGitDiff(wsAbs);
        _record(refs, r, kind, literal);
        totalBytes += r.bytes ?? 0;
        replacement = totalBytes > _ContextRefLimits.maxTotalBytes
            ? '[@git-diff gagal: budget context penuh]'
            : r.text;
      }
      buf.write(replacement);
    }
    buf.write(line.substring(last));
    buf.writeln();
  }

  final expanded = buf.toString();
  // split('\n') + writeln menambah newline trailing saat input tidak
  // diakhiri newline; normalisasi agar tidak mengubah panjang pesan.
  return ContextExpansion(
    input.endsWith('\n')
        ? expanded
        : expanded.substring(0, expanded.length - 1),
    refs,
  );
}

void _record(
  List<Map<String, dynamic>> refs,
  _RefResult r,
  String kind,
  String literal,
) {
  refs.add({
    'ref': literal,
    'kind': kind,
    'status': r.error == null ? 'ok' : 'error',
    if (r.error != null) 'error': r.error,
    if (r.bytes != null) 'bytes': r.bytes,
  });
}

_RefResult _expandFile(String arg, String wsAbs) {
  String abs;
  try {
    abs = _resolveWithin(arg, wsAbs);
  } on ArgumentError catch (e) {
    return _RefResult('[@file:$arg gagal: ${e.message}]', error: e.message);
  }
  final type = FileSystemEntity.typeSync(abs, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return _RefResult('[@file:$arg gagal: file tidak ditemukan]',
        error: 'not_found');
  }
  if (type == FileSystemEntityType.directory) {
    return _RefResult(
      '[@file:$arg gagal: path adalah direktori, gunakan @folder]',
      error: 'is_directory',
    );
  }
  final file = File(abs);
  if (file.lengthSync() > _ContextRefLimits.maxFileBytes) {
    return _RefResult(
      '[@file:$arg gagal: melebihi ${_ContextRefLimits.maxFileBytes} byte]',
      error: 'too_large',
    );
  }
  final bytes = file.readAsBytesSync();
  if (bytes.contains(0x00)) {
    return _RefResult('[@file:$arg gagal: file biner]', error: 'binary');
  }
  final content = utf8.decode(bytes, allowMalformed: true);
  return _RefResult(
    '\n[context: file $arg (${bytes.length} byte)]\n```\n$content\n```\n',
    bytes: bytes.length,
  );
}

_RefResult _expandFolder(String arg, String wsAbs) {
  String abs;
  try {
    abs = _resolveWithin(arg, wsAbs);
  } on ArgumentError catch (e) {
    return _RefResult('[@folder:$arg gagal: ${e.message}]', error: e.message);
  }
  final type = FileSystemEntity.typeSync(abs, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return _RefResult('[@folder:$arg gagal: folder tidak ditemukan]',
        error: 'not_found');
  }
  if (type != FileSystemEntityType.directory) {
    return _RefResult('[@folder:$arg gagal: bukan direktori]',
        error: 'not_directory');
  }
  final lines = <String>[];
  var count = 0;
  var truncated = false;
  void walk(String dir, int depth) {
    if (depth > _ContextRefLimits.maxFolderDepth) return;
    final entries = Directory(dir).listSync(
      recursive: false,
      followLinks: false,
    )..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (count >= _ContextRefLimits.maxFolderEntries) {
        truncated = true;
        return;
      }
      final name = p.basename(e.path);
      final rel =
          p.isWithin(wsAbs, e.path) ? p.relative(e.path, from: wsAbs) : name;
      if (e is Directory) {
        lines.add('$rel/');
        count++;
        walk(e.path, depth + 1);
      } else if (e is File) {
        lines.add('$rel (${e.lengthSync()} byte)');
        count++;
      }
    }
  }

  walk(abs, 1);
  final body = lines.isEmpty ? '(kosong)' : lines.join('\n');
  return _RefResult(
    '\n[context: folder $arg${truncated ? ' (dipotong pada '
        '${_ContextRefLimits.maxFolderEntries} entri)' : ''}]\n'
    '$body\n',
    bytes: body.length,
  );
}

Future<_RefResult> _expandUrl(String arg) async {
  final uri = Uri.tryParse(arg);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return _RefResult('[@url:$arg gagal: URL http(s) tidak valid]',
        error: 'invalid_url');
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final sb = StringBuffer();
    var received = 0;
    var truncated = false;
    final sub = res.listen((chunk) {
      if (truncated) return;
      received += chunk.length;
      if (received > _ContextRefLimits.maxFileBytes) {
        truncated = true;
        return;
      }
      sb.write(utf8.decode(chunk, allowMalformed: true));
    });
    try {
      await sub.asFuture<void>();
    } catch (_) {
      await sub.cancel();
      return _RefResult('[@url:$arg gagal: koneksi putus saat membaca respons]',
          error: 'stream_error');
    }
    if (truncated) {
      await sub.cancel();
      return _RefResult(
        '[@url:$arg gagal: melebihi ${_ContextRefLimits.maxFileBytes} byte]',
        error: 'too_large',
      );
    }
    if (res.statusCode >= 400) {
      return _RefResult('[@url:$arg gagal: HTTP ${res.statusCode}]',
          error: 'http_${res.statusCode}');
    }
    final contentType = res.headers.value('content-type') ?? '';
    final binary =
        contentType.startsWith('image/') ||
        contentType.startsWith('audio/') ||
        contentType.startsWith('video/');
    if (binary) {
      return _RefResult('[@url:$arg gagal: konten biner ($contentType)]',
          error: 'binary');
    }
    return _RefResult(
      '\n[context: url $arg ($received byte; HTTP ${res.statusCode})]\n'
      '${sb.toString()}\n',
      bytes: received,
    );
  } on TimeoutException {
    return _RefResult('[@url:$arg gagal: timeout 15s]', error: 'timeout');
  } on SocketException catch (e) {
    return _RefResult('[@url:$arg gagal: ${e.message}]', error: 'socket');
  } finally {
    client.close(force: true);
  }
}

Future<_RefResult> _expandGitDiff(String wsAbs) async {
  try {
    final result = await Process.run(
      'git',
      ['-C', wsAbs, 'diff', 'HEAD', '--no-color'],
      encoding: utf8,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      return _RefResult(
        '[@git-diff gagal: bukan repo git atau git gagal (exit '
        '${result.exitCode})]',
        error: 'git_exit_${result.exitCode}',
      );
    }
    var diff = '${result.stdout}';
    if (diff.trim().isEmpty) {
      return _RefResult('\n[context: git diff HEAD (kosong)]\n', bytes: 0);
    }
    var truncatedNote = '';
    if (diff.length > _ContextRefLimits.maxFileBytes) {
      diff = diff.substring(0, _ContextRefLimits.maxFileBytes);
      truncatedNote =
          ' (dipotong pada ${_ContextRefLimits.maxFileBytes} byte)';
    }
    return _RefResult(
      '\n[context: git diff HEAD$truncatedNote]\n```\n$diff\n```\n',
      bytes: diff.length,
    );
  } on ProcessException catch (e) {
    return _RefResult('[@git-diff gagal: ${e.message}]', error: 'process');
  }
}

String _resolveWithin(String arg, String wsAbs) {
  if (arg.isEmpty) {
    throw ArgumentError('path kosong');
  }
  if (arg.startsWith('/') || arg.startsWith('~')) {
    throw ArgumentError('path absolut tidak diizinkan');
  }
  if (arg.split('/').contains('..')) {
    throw ArgumentError('path tidak boleh keluar workspace');
  }
  final abs = p.normalize(p.join(wsAbs, arg));
  if (!p.isWithin(wsAbs, abs)) {
    throw ArgumentError('path di luar workspace');
  }
  return abs;
}
