import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'doc_extract.dart';

/// A.2/A.3 — Ingest lampiran penuh (superset dari ekspansi C2 yang lama):
///
/// 1. **Teks biasa** (text/ dan subset application/*): dibaca inline dengan
///    budget 64 KiB/file dan 128 KiB total — perilaku C2 dipertahankan.
/// 2. **Zip** (`application/zip` / `.zip`): DIEKSTRAK ke
///    `<uploads>/<nama-tanpa-ekstensi>/` dengan sanitasi entry (tanpa
///    path traversal, tanpa absolut, tanpa symlink), batas jumlah entry dan
///    total ukuran ter-ekspansi — seperti cara coding agent lain menangani
///    "user upload proyek cetak". Agent menerima folder hasil ekstraksi
///    sebagai path yang bisa dijelajah dengan tool file/grep.
/// 3. **Dokumen** (PDF/DOCX/ODT/XLSX/PPTX): teks diekstrak (A.3) dan inline
///    bila muat budget; file mentah selalu juga DISIMPAN ke uploads agar
///    agent bisa bekerja dengan path-nya (pola Files API Claude).
/// 4. **Biner lain** (gambar/audio/video): metadata saja; file mentah juga
///    disimpan ke uploads (gambar dibawa terpisah ke provider vision).
///
/// Semua fail-closed: kegagalan per-file menjadi blok inline berstatus
/// `error` dan pesan tetap terkirim. Fungsi ini tidak pernah throw.
class IngestedAttachments {
  IngestedAttachments(this.text, this.stats);

  /// Blok konteks `[lampiran: ...]` untuk prompt (sama kontraknya dengan
  /// `AttachmentExpansion.text` dari ekspansi C2).
  final String text;

  /// Ringkasan per-lampiran: `name`, `status` (ok|metadata|stored|error),
  /// `bytes`, dan opsional `path`/`extracted_dir`/`entries`.
  final List<Map<String, dynamic>> stats;
}

class _IngestLimits {
  static const perFileTextBytes = 64 * 1024;
  static const totalTextBytes = 128 * 1024;
  static const zipMaxEntries = 500;
  static const zipMaxTotalBytes = 64 * 1024 * 1024;
  static const zipMaxPerEntryBytes = 16 * 1024 * 1024;
  static const listingEntries = 30;
}

bool _isZipAttachment(String name, String? mime) {
  final m = (mime ?? '').toLowerCase().trim();
  final lname = name.toLowerCase();
  return m == 'application/zip' || m == 'application/x-zip-compressed' ||
      lname.endsWith('.zip');
}

/// Sanitasi nama file/segmen path lampiran: buang kontrol char, separator,
/// dan.trim(); hasil selalu non-kosong dan aman sebagai satu komponen.
String sanitizeSegmentName(String raw, {String fallback = 'lampiran'}) {
  var s = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  // `:` (drive-letter Windows), `..` (traversal-ish), dan separator path
  // semuanya diganti `_` agar nama aman disimpan lintas platform.
  s = s.replaceAll(RegExp(r'[:/\\]+'), '_');
  s = s.replaceAll(RegExp(r'\.{2,}'), '_');
  if (s.isEmpty || RegExp(r'^[_. ]+$').hasMatch(s)) s = fallback;
  return s;
}

/// Unik-kan path target: `a.pdf` → `a(2).pdf`, `a(2).pdf`, dst. bila ada.
File _uniqueTarget(Directory dir, String fileName) {
  var candidate = p.join(dir.path, fileName);
  final ext = p.extension(fileName);
  final stem = p.basenameWithoutExtension(fileName);
  var n = 2;
  while (File(candidate).existsSync()) {
    candidate = p.join(dir.path, '$stem($n)$ext');
    n++;
  }
  return File(candidate);
}

/// Ekspansi lampiran via ingest penuh. [uploadsDirPath] biasanya
/// `data/uploads/<sesi-ter-sanitasi>` di bawah dataDir runtime; folder
/// dibuat bila perlu. Return blok teks + stats (bentuk sama dengan C2).
IngestedAttachments ingestAttachments(
  List<Attachment> attachments, {
  required String uploadsDirPath,
}) {
  if (attachments.isEmpty) return IngestedAttachments('', const []);
  final uploads = Directory(uploadsDirPath);
  try {
    uploads.createSync(recursive: true);
  } catch (_) {
    // Tanpa folder uploads, jalur simpan gagal per-file (tercatat jujur).
  }
  final buf = StringBuffer()
    ..writeln(
      '[lampiran: pengguna menyertakan ${attachments.length} file berikut]',
    );
  var remaining = _IngestLimits.totalTextBytes;
  final stats = <Map<String, dynamic>>[];

  for (final a in attachments) {
    final name = sanitizeSegmentName(a.name ?? 'lampiran');
    final mime = a.mime ?? 'tidak diketahui';
    final entry = <String, dynamic>{'name': name, 'mime': mime};
    try {
      final raw = a.urlOrBytes;
      if (raw is! Uint8List) {
        buf.writeln(
          '[lampiran $name: bentuk data tidak dapat dibaca oleh runtime '
          '(bukan byte raw) — hanya aktif lewat jalur gateway yang '
          'mendekode base64.]',
        );
        entry['status'] = 'error';
        stats.add(entry);
        continue;
      }
      final bytes = raw;

      // 1) Zip: simpan + ekstrak aman.
      if (_isZipAttachment(name, mime)) {
        final stored = _store(uploads, name, bytes);
        entry['path'] = stored.path;
        final extracted = File(stored.path).existsSync()
            ? _extractZipSafe(
                stored,
                Directory(p.withoutExtension(stored.path)),
              )
            : null;
        final dir = p.withoutExtension(stored.path);
        entry['extracted_dir'] = dir;
        if (extracted != null) {
          entry['entries'] = extracted.entries;
          entry['status'] = 'ok';
          buf.writeln(
            '[lampiran: $name (zip, ${bytes.length} byte) — diekstrak ke '
            '"$dir" (${extracted.entries}${extracted.truncated ? ' sampai batas' : ''} '
            'entry)${extracted.note}; jelajahi folder ini dengan tool '
            'list_dir/grep/read_file sebelum menjawab.]',
          );
          if (extracted.listing.isNotEmpty) {
            buf.writeln(
              'Isi teratas ${extracted.listing.length} entry:\n'
              '${extracted.listing.map((e) => '- $e').join('\n')}',
            );
          }
        } else {
          entry['status'] = 'error';
          buf.writeln(
            '[lampiran: $name (zip) tersimpan di "${stored.path}" tetapi '
            'ekstraksi gagal atau melebihi batas aman — minta file per-file '
            'atau perbaiki arsip lalu kirim ulang bila perlu.]',
          );
        }
        stats.add(entry);
        continue;
      }

      // 2) Dokumen: ekstrak teks + simpan mentah.
      final attempt = extractDocumentText(
        name: name,
        mime: mime,
        bytes: bytes,
        maxChars: _IngestLimits.perFileTextBytes.clamp(0, remaining).toInt(),
      );
      final isText = attempt.text != null && attempt.text!.isNotEmpty;
      if (isText) {
        final usable = attempt.text!.length > remaining
            ? attempt.text!.substring(0, remaining)
            : attempt.text!;
        final stored = _store(uploads, name, bytes);
        entry
          ..['status'] = 'ok'
          ..['bytes'] = bytes.length
          ..['path'] = stored.path;
        remaining -= usable.length;
        buf.writeln(
          '[lampiran: $name ($mime, ${bytes.length} byte) — teks diekstrak; '
          'file mentah juga disimpan di "${stored.path}"]',
        );
        buf.writeln(usable);
        if (usable.length < attempt.text!.length) {
          buf.writeln(
            '[lampiran: $name dipotong lewat budget konteks; file mentah '
            'tersedia di "${stored.path}" untuk dibaca dengan tool pada '
            'turn berikutnya.]',
          );
        }
        buf.writeln('[/lampiran: $name]');
        stats.add(entry);
        continue;
      }

      // 3) Teks mentah (kontrak C2 lama).
      if (_mimeIsText(mime)) {
        final clipped = bytes.length > _IngestLimits.perFileTextBytes
            ? Uint8List.sublistView(bytes, 0, _IngestLimits.perFileTextBytes)
            : bytes;
        final usable = clipped.length > remaining
            ? Uint8List.sublistView(clipped, 0, remaining)
            : clipped;
        final content = utf8.decode(usable, allowMalformed: true);
        final truncated =
            usable.length < bytes.length || usable.length < clipped.length;
        buf.writeln('[lampiran: $name ($mime, ${bytes.length} byte)]');
        buf.writeln(content);
        if (truncated) {
          buf.writeln(
            '[lampiran: $name dipotong — runtime hanya membaca '
            '${usable.length} dari ${bytes.length} byte (budget ukuran).]',
          );
        }
        buf.writeln('[/lampiran: $name]');
        remaining -= usable.length;
        entry['status'] = 'ok';
        entry['bytes'] = usable.length;
        stats.add(entry);
        continue;
      }

      // 4) Biner lain: metadata + simpan (vision membawa gambar terpisah).
      final stored = _store(uploads, name, bytes);
      entry
        ..['status'] = 'stored'
        ..['bytes'] = bytes.length
        ..['path'] = stored.path;
      buf.writeln(
        '[lampiran: $name — ${a.type} ($mime, ${bytes.length} byte) tersimpan '
        'di "${stored.path}". Isi biner tidak dibaca sebagai teks; '
        'gambar dilewatkan ke provider vision bila tersedia.]',
      );
      stats.add(entry);
    } catch (error) {
      buf.writeln(
        '[lampiran $name: gagal di-ingest ($error) — lewati file ini.]',
      );
      entry['status'] = 'error';
      stats.add(entry);
    }
  }
  buf.writeln('[akhir lampiran]');
  return IngestedAttachments(buf.toString(), stats);
}

File _store(Directory uploads, String name, Uint8List bytes) {
  if (!uploads.existsSync()) {
    // Folder uploads gagal dibuat tadi — coba sekali lagi sebelum gagal.
    uploads.createSync(recursive: true);
  }
  final target = _uniqueTarget(uploads, name);
  target.writeAsBytesSync(bytes, flush: true);
  return target;
}

class _ZipExtraction {
  _ZipExtraction({
    required this.entries,
    required this.listing,
    required this.truncated,
    required this.note,
  });
  final int entries;
  final List<String> listing;
  final bool truncated;
  final String note;
}

/// Ekstraksi zip yang aman: setiap entry disanitasi relatif ke folder tujuan;
/// absolute path, `..`, symlink, dan device-ish jelas ditolak; batas jumlah
/// entry, ukuran per-entry, dan total uncompressed ditegakkan (defend zip
/// bomb — arsip 2 MiB bisa menggembung ratusan MiB). Mengembalikan null
/// bila ekstraksi gagal total; catatan batas ada di [note].
_ZipExtraction? _extractZipSafe(File zipFile, Directory destDir) {
  try {
    final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
    final files = archive.where((e) => e.isFile).toList();
    if (files.isEmpty) {
      return _ZipExtraction(
        entries: 0, listing: const [], truncated: false, note: '(arsip kosong)',
      );
    }
    var total = 0;
    var truncated = false;
    final listing = <String>[];
    var written = 0;
    destDir.createSync(recursive: true);
    for (final entry in files) {
      if (written >= _IngestLimits.zipMaxEntries) {
        truncated = true;
        break;
      }
      final unsafe =
          entry.name.startsWith('/') || entry.name.startsWith(r'\') ||
          entry.name.contains('..') || p.isAbsolute(entry.name);
      if (unsafe) {
        listing.add('[DITOLAK: ${entry.name}]');
        continue;
      }
      final size = entry.size;
      if (size > _IngestLimits.zipMaxPerEntryBytes) {
        truncated = true;
        listing.add('[DILEWATI-KAPASITAS ${entry.name}]');
        continue;
      }
      total += size;
      if (total > _IngestLimits.zipMaxTotalBytes) {
        truncated = true;
        listing.add('[DILEWATI-KAPASITAS ${entry.name}]');
        continue;
      }
      final targetPath = p.normalize(p.join(destDir.path, entry.name));
      if (!p.isWithin(destDir.path, targetPath) &&
          targetPath != destDir.path) {
        truncated = true;
        listing.add('[DITOLAK: ${entry.name}]');
        continue;
      }
      final bytes = entry.content as List<int>;
      File(targetPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes, flush: true);
      written++;
      if (listing.length < _IngestLimits.listingEntries) {
        listing.add(entry.name);
      }
    }
    final note = truncated
        ? '(ekstraksi berhenti di batas aman: maks '
            '${_IngestLimits.zipMaxEntries} entry / '
            '${_IngestLimits.zipMaxTotalBytes ~/ (1024 * 1024)} MiB)'
        : '';
    return _ZipExtraction(
      entries: written,
      listing: listing.sublist(0, listing.length.clamp(0, _IngestLimits.listingEntries)),
      truncated: truncated,
      note: note,
    );
  } catch (e) {
    // Ekstraksi gagal — penelepon menuliskan note jujur.
    return null;
  }
}

bool _mimeIsText(String mime) {
  final m = mime.toLowerCase().trim();
  if (m.startsWith('text/')) return true;
  const extras = {
    'application/json',
    'application/x-ndjson',
    'application/yaml',
    'application/x-yaml',
    'application/toml',
    'application/xml',
    'application/javascript',
    'application/x-sh',
  };
  return extras.contains(m);
}

/// Sanitasi id sesi untuk nama folder uploads (`mcp:foo`, `acp:bar`,
/// `telegram:123/def`) menjadi satu nama folder aman.
String sanitizeSessionDirName(String sessionId) =>
    sanitizeSegmentName(sessionId, fallback: 'default');
