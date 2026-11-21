import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

/// C2 Chat-UX: ekspansi attachment yang dikirim pengguna (inline base64 via
/// gateway atau byte langsung) menjadi blok konteks teks di prompt.
///
/// Prinsip (mengikuti P3/@ context refs):
/// - Dokumen teks (text/* dan subset application/*) dibaca sebagai konteks
///   inline `[lampiran: <name>] … [/lampiran]`, dibatasi 64 KiB per file dan
///   128 KiB total — sisanya dipotong dengan penanda jujur.
/// - Gambar/biner/audio TIDAK dapat dibaca sebagai teks oleh runtime ini:
///   disisipkan metadata saja (nama, ukuran, mime, checksum FNV-1a) tanpa
///   mengarang isi; dukungan vision provider belum ada.
/// - Ekspansi tidak pernah throw: file bermasalah menjadi penanda error
///   inline sehingga pesan tetap terkirim.
class AttachmentExpansion {
  AttachmentExpansion(this.text, this.stats);

  final String text;

  /// Ringkasan per-lampiran: `name`, `status` (ok|metadata|error), `bytes`.
  final List<Map<String, dynamic>> stats;
}

class _AttachmentLimits {
  static const perFileBytes = 64 * 1024;
  static const totalBytes = 128 * 1024;
}

/// Mime yang isinya bisa didekode sebagai teks oleh runtime. Harus subset
/// dari allowlist gateway (yang sudah membatasi upload) — di sini kita hanya
/// memutuskan teks vs metadata.
bool attachmentMimeIsText(String? mime) {
  if (mime == null) return false;
  final m = mime.toLowerCase().trim();
  if (m.isEmpty) return false;
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

String _fnv1aHex(List<int> bytes) {
  var hash = 0x811c9dc5;
  final stride = bytes.length < 256 ? 1 : bytes.length ~/ 256;
  for (var i = 0; i < bytes.length; i += stride) {
    hash ^= bytes[i];
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

AttachmentExpansion expandAttachments(List<Attachment> attachments) {
  final stats = <Map<String, dynamic>>[];
  if (attachments.isEmpty) return AttachmentExpansion('', const []);
  final buf = StringBuffer()
    ..writeln(
      '[lampiran: pengguna menyertakan ${attachments.length} file berikut]',
    );
  var remaining = _AttachmentLimits.totalBytes;
  for (final a in attachments) {
    final name =
        (a.name ?? 'lampiran').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    final mime = a.mime ?? 'tidak diketahui';
    final entry = <String, dynamic>{'name': name, 'mime': mime};
    try {
      final rawBytes = a.urlOrBytes;
      if (rawBytes is Uint8List) {
        if (attachmentMimeIsText(a.mime)) {
          final clipped = rawBytes.length > _AttachmentLimits.perFileBytes
              ? Uint8List.sublistView(rawBytes, 0, _AttachmentLimits.perFileBytes)
              : rawBytes;
          final usable = clipped.length > remaining
              ? Uint8List.sublistView(clipped, 0, remaining)
              : clipped;
          final content = utf8.decode(usable, allowMalformed: true);
          final truncated =
              usable.length < rawBytes.length || usable.length < clipped.length;
          buf.writeln('[lampiran: $name ($mime, ${rawBytes.length} byte)]');
          buf.writeln(content);
          if (truncated) {
            buf.writeln(
              '[lampiran: $name dipotong — runtime hanya membaca '
              '${usable.length} dari ${rawBytes.length} byte; sisanya tidak '
              'disertakan (budget ukuran).]',
            );
          }
          buf.writeln('[/lampiran: $name]');
          remaining -= usable.length;
          entry['status'] = 'ok';
          entry['bytes'] = usable.length;
        } else {
          buf.writeln(
            '[lampiran $name: ${a.type} ($mime, ${rawBytes.length} byte, '
            'checksum fnv1a:${_fnv1aHex(rawBytes)}) — isi tidak dapat dibaca '
            'sebagai teks oleh runtime ini (vision/biner belum didukung); '
            'tanyakan detailnya kepada pengguna bila diperlukan.]',
          );
          entry['status'] = 'metadata';
          entry['bytes'] = rawBytes.length;
        }
      } else {
        buf.writeln(
          '[lampiran $name: bentuk data tidak dapat dibaca oleh runtime '
          '(bukan byte raw) — hanya akan aktif lewat jalur gateway yang '
          'mendekode base64.]',
        );
        entry['status'] = 'error';
      }
    } catch (error) {
      buf.writeln(
        '[lampiran $name: gagal dibaca ($error) — lewati file ini.]',
      );
      entry['status'] = 'error';
    }
    stats.add(entry);
  }
  buf.writeln('[akhir lampiran]');
  return AttachmentExpansion(buf.toString(), stats);
}

/// Normalisasi base64 (whitespace dibuang; padding ditambahkan bila kurang)
/// lalu dekode fail-closed — lempar [FormatException] bila tetap invalid.
Uint8List decodeAttachmentBase64(String raw) {
  var s = raw.replaceAll(RegExp(r'\s'), '');
  final mod = s.length % 4;
  if (mod == 1) throw const FormatException('panjang base64 tidak valid');
  if (mod == 2) s = '$s==';
  if (mod == 3) s = '$s=';
  final decoded = base64.decode(s);
  return Uint8List.fromList(decoded);
}
