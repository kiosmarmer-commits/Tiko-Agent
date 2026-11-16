import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_tools/agent_tools.dart';

import 'bot_mode.dart';

/// Impor character card SillyTavern (B5) menjadi [BotProfile].
///
/// Mendukung JSON mentah dan PNG dengan kartu tersemat:
/// - V1: field langsung di root tanpa wrapper spec;
/// - V2: `spec: 'chara_card_v2'` dengan blok `data`;
/// - V3: `spec: 'chara_card_v3'` (backward-compatible V2) — chunk PNG
///   `ccv3` diprioritaskan di atas `chara`.
///
/// Semua input tidak tepercaya: ukuran dibatasi, teks dibersihkan dan
/// dipotong, id di-slugify mengikuti [BotProfile.isValidId], dan path file
/// dijail ke workspace via [PathSafety.resolveInRoot]. Allowlist tool sengaja
/// kosong — bot hasil impor fail-closed sampai operator mengaturnya.
class CharacterCardImporter {
  CharacterCardImporter._();

  static const int maxJsonChars = 2 * 1024 * 1024;
  static const int maxPngBytes = 32 * 1024 * 1024;
  static const int maxPersonaChars = 20000;
  static const int maxGreetingChars = 8000;

  /// Parse kartu dari objek JSON yang sudah didekode.
  static BotProfile parse(Map<String, dynamic> json) {
    final data = _dataBlock(json);
    final name = _cleanText(data['name']);
    if (name.isEmpty) {
      throw const FormatException('character card tanpa nama');
    }
    return BotProfile(
      id: slugify(name),
      name: name,
      persona: _composePersona(data),
      greeting: _cap(_cleanText(data['first_mes']), maxGreetingChars),
    );
  }

  /// Baca kartu dari file JSON (`*.json`) atau PNG (`*.png`) di dalam
  /// [workspaceRoot]. Path di luar workspace ditolak.
  static Future<BotProfile> fromFile(
    String filePath, {
    required String workspaceRoot,
  }) async {
    final resolved = PathSafety.resolveInRoot(workspaceRoot, filePath);
    if (resolved == null) {
      throw ArgumentError('path character card harus di dalam workspace');
    }
    final file = File(resolved);
    if (!await file.exists()) {
      throw FileSystemException('character card tidak ditemukan', resolved);
    }
    final stat = await file.stat();
    if (resolved.toLowerCase().endsWith('.png')) {
      if (stat.size > maxPngBytes) {
        throw const FormatException('PNG character card terlalu besar');
      }
      return parse(fromPngBytes(await file.readAsBytes()));
    }
    final text = await file.readAsString();
    if (text.length > maxJsonChars) {
      throw const FormatException('JSON character card terlalu besar');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('character card bukan objek JSON');
    }
    return parse(decoded);
  }

  /// Ekstrak JSON kartu dari chunk `tEXt` PNG (`ccv3` V3 diprioritaskan,
  /// fallback `chara` V2).
  static Map<String, dynamic> fromPngBytes(Uint8List bytes) {
    const signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length + 12) {
      throw const FormatException('bukan PNG valid');
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) {
        throw const FormatException('bukan PNG valid');
      }
    }
    String? v3;
    String? v2;
    var offset = signature.length;
    while (offset + 12 <= bytes.length) {
      final length = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final type = latin1.decode(bytes.sublist(offset + 4, offset + 8));
      final dataStart = offset + 8;
      if (length < 0 || dataStart + length + 4 > bytes.length) {
        throw const FormatException('PNG character card terpotong');
      }
      if (type == 'tEXt') {
        final chunk = bytes.sublist(dataStart, dataStart + length);
        final zero = chunk.indexOf(0);
        if (zero > 0) {
          final keyword = latin1.decode(chunk.sublist(0, zero));
          final text = latin1.decode(chunk.sublist(zero + 1));
          if (keyword == 'ccv3') {
            v3 = text;
          } else if (keyword == 'chara') {
            v2 = text;
          }
        }
      }
      if (type == 'IEND') break;
      offset = dataStart + length + 4;
    }
    final raw = v3 ?? v2;
    if (raw == null) {
      throw const FormatException(
        'PNG tanpa character card (chunk chara/ccv3 tidak ditemukan)',
      );
    }
    if (raw.length > maxJsonChars * 2) {
      throw const FormatException('character card terlalu besar');
    }
    final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('character card bukan objek JSON');
    }
    return decoded;
  }

  /// Nama karakter → id bot valid (`[a-z0-9][a-z0-9_-]{0,63}`).
  static String slugify(String name) {
    var slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.length > 64) slug = slug.substring(0, 64);
    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'character' : slug;
  }

  /// Id unik di [store]: tambah sufiks `-2`, `-3`, ... bila sudah dipakai.
  static String uniqueId(BotStore store, String base) {
    final trimmed = base.length > 56 ? base.substring(0, 56) : base;
    if (store.get(trimmed) == null) return trimmed;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$trimmed-$i';
      if (store.get(candidate) == null) return candidate;
    }
    throw const FormatException('tidak ada slot id bot yang tersedia');
  }

  static Map<String, dynamic> _dataBlock(Map<String, dynamic> json) {
    final spec = json['spec'];
    if (spec is String && spec.startsWith('chara_card_v')) {
      final data = json['data'];
      if (data is Map<String, dynamic>) return data;
      throw const FormatException('character card V2/V3 tanpa blok data');
    }
    return json;
  }

  static String _composePersona(Map<String, dynamic> data) {
    final parts = <String>[];
    void add(String label, Object? raw) {
      final text = _cleanText(raw);
      if (text.isNotEmpty) {
        parts.add(label.isEmpty ? text : '$label: $text');
      }
    }

    add('', data['description']);
    add('Kepribadian', data['personality']);
    add('Skenario', data['scenario']);
    add('Instruksi sistem', data['system_prompt']);
    return _cap(parts.join('\n\n'), maxPersonaChars);
  }

  static String _cleanText(Object? raw) =>
      raw is String ? raw.trim() : '';

  static String _cap(String text, int max) =>
      text.length > max ? text.substring(0, max) : text;
}
