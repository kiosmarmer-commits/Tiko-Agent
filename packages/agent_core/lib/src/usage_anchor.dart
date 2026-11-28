// Hermes parity: `agent/usage_anchor.py` — akuntansi token ber-anchoring
// usage (`usage.prompt_tokens` provider adalah satu-satunya ukuran konteks
// yang otoritatif; estimasi lokal `bytes/4` hanya menutupi pesan yang
// ditambahkan SETELAH pengukuran tersebut).
//
// Anchor = usage nyata provider saat capture + snapshot posisi transcript
// yang dihargai: `baseCount` (jumlah pesan saat capture; balasan belum
// ditambahkan dan sudah tercakup `completionTokens`, sehingga delta walk
// melewati satu baris assistant di indeks itu), `baseLastRole` dan
// `baseLastFp` (fingerprint konten pesan terakhir yang dihargai),
// `basePrefixFp` (digest seluruh prefix yang dihargai — kompresi yang
// mempertahankan pesan terakhir tapi menulis-ulang prefix lebih awal harus
// membuat anchor gagal-closed).
//
// Fingerprint (bukan `id()`) adalah identitas: gateway membaca ulang
// transcript dari store tiap turn dan sesi yang dilanjutkan berjalan di
// instance loop baru, jadi identitas objek tidak pernah stabil. Anchor
// fail-closed: bila prefix tidak cocok, penuh estimasi kasar sampai bacaan
// nyata berikutnya (Hermes #99421, #104462).
//
// Never-raises: semua fungsi aman dipanggil pada data korup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// Harga token per-gambar default sebelum kalibrasi dari usage nyata
/// (Hermes `image_token_cost.DEFAULT_IMAGE_TOKEN_COST`).
const int defaultImageTokenCost = 1500;

/// Estimasi kasar token satu pesan: `content/4` + panggilan tool + gambar
/// pada harga per-gambar yang dipelajari (Hermes `image_token_cost`).
int estimateMessageTokensRough(
  ChatMessage m, {
  int imageCost = defaultImageTokenCost,
}) {
  var chars = m.content.length;
  final calls = m.toolCalls;
  if (calls != null) {
    for (final c in calls) {
      chars += c.name.length + c.id.length;
      c.args.forEach((k, v) => chars += k.length + '$v'.length);
    }
  }
  return chars ~/ 4 + (m.images?.length ?? 0) * imageCost;
}

/// Estimasi kasar token daftar pesan (pra-flight saja).
int estimateMessagesTokensRough(
  List<ChatMessage> messages, {
  int imageCost = defaultImageTokenCost,
}) {
  var total = 0;
  for (final m in messages) {
    total += estimateMessageTokensRough(m, imageCost: imageCost);
  }
  return total;
}

/// SHA-256 hex (deterministik lintas proses dan platform — termasuk
/// kompilasi Web; dart2js menolak literal integer 64-bit, jadi hash
/// per-geser seperti FNV-1a 64 tidak aman di sini).
String _stableHashHex(String input) =>
    sha256.convert(utf8.encode(input)).toString();

/// Digest stabil satu pesan atas field provider-visible yang di-round-trip
/// store sesi byte-per-byte. Metadata tampilan (timestamp, row id) sengaja
/// tidak diikutkan — hanya membuat match gagal-closed tanpa alasan.
String chatMessageFingerprint(ChatMessage m) {
  final payload = <String, dynamic>{
    'role': m.role,
    'content': m.content,
    if (m.toolCallId != null) 'tool_call_id': m.toolCallId,
    if (m.name != null) 'name': m.name,
    if (m.toolCalls != null)
      'tool_calls': m.toolCalls!
          .map((c) => {
                'id': c.id,
                'name': c.name,
                'args': c.args,
              })
          .toList(),
  };
  return _stableHashHex(json.encode(payload));
}

String _pricedPrefixFingerprint(List<ChatMessage> messages, int baseCount) {
  if (baseCount <= 0 || messages.length < baseCount) return '';
  final fps = <String>[
    for (var i = 0; i < baseCount; i++)
      '${messages[i].role}:${chatMessageFingerprint(messages[i])}',
  ];
  return _stableHashHex(json.encode(fps));
}

/// Usage anchor: pengukuran nyata provider + posisi transcript yang dihargai.
class UsageAnchor {
  const UsageAnchor({
    required this.promptTokens,
    required this.completionTokens,
    required this.baseCount,
    required this.baseLastRole,
    required this.baseLastFp,
    required this.basePrefixFp,
  });

  final int promptTokens;
  final int completionTokens;

  /// Jumlah pesan (bentuk request) saat capture — balasan belum termasuk.
  final int baseCount;
  final String? baseLastRole;
  final String baseLastFp;
  final String basePrefixFp;

  /// Bangun anchor dari usage provider, atau null bila usage tak bisa
  /// dipakai (endpoint tanpa usage — caller mempertahankan anchor lamanya).
  static UsageAnchor? capture(
    int promptTokens,
    int completionTokens,
    List<ChatMessage> messages,
  ) {
    if (promptTokens <= 0 || messages.isEmpty) return null;
    final last = messages.last;
    return UsageAnchor(
      promptTokens: promptTokens,
      completionTokens: completionTokens < 0 ? 0 : completionTokens,
      baseCount: messages.length,
      baseLastRole: last.role,
      baseLastFp: chatMessageFingerprint(last),
      basePrefixFp: _pricedPrefixFingerprint(messages, messages.length),
    );
  }

  /// True bila [messages] masih membawa prefix yang dihargai anchor ini:
  /// panjang cukup, role pesan terakhir cocok, fingerprint pesan terakhir
  /// cocok, DAN fingerprint seluruh prefix cocok.
  bool matches(List<ChatMessage> messages) {
    if (baseCount <= 0 || messages.length < baseCount) return false;
    final base = messages[baseCount - 1];
    if (base.role != baseLastRole) return false;
    if (baseLastFp.isEmpty || chatMessageFingerprint(base) != baseLastFp) {
      return false;
    }
    if (basePrefixFp.isEmpty) return false;
    return _pricedPrefixFingerprint(messages, baseCount) == basePrefixFp;
  }

  /// Prompt+completion token nyata ditambah estimasi kasar HANYA pesan yang
  /// ditambahkan sejak capture; null bila anchor kedaluwarsa terhadap
  /// [messages]. Balasan respons anchor sendiri dilewati (sudah ada di
  /// `completionTokens`).
  int? anchoredContextTokens(
    List<ChatMessage> messages, {
    int imageCost = defaultImageTokenCost,
  }) {
    if (!matches(messages)) return null;
    var total = promptTokens + completionTokens;
    var delta = messages.sublist(baseCount);
    if (delta.isNotEmpty && delta.first.role == 'assistant') {
      delta = delta.sublist(1);
    }
    if (delta.isNotEmpty) {
      total += estimateMessagesTokensRough(delta, imageCost: imageCost);
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'base_count': baseCount,
        'base_last_role': baseLastRole,
        'base_last_fp': baseLastFp,
        'base_prefix_fp': basePrefixFp,
      };

  /// Deserialize ketat: field int > 0 dan dua fingerprint string wajib ada,
  /// selain itu null (anchor korup = tanpa anchor, fail-closed).
  static UsageAnchor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pt = raw['prompt_tokens'];
    final ct = raw['completion_tokens'];
    final bc = raw['base_count'];
    final fp = raw['base_last_fp'];
    const pfp = 'base_prefix_fp';
    final prefixFp = raw[pfp];
    if (pt is! int || pt <= 0) return null;
    if (bc is! int || bc <= 0) return null;
    if (fp is! String || fp.isEmpty) return null;
    if (prefixFp is! String || prefixFp.isEmpty) return null;
    return UsageAnchor(
      promptTokens: pt,
      completionTokens: ct is int && ct > 0 ? ct : 0,
      baseCount: bc,
      baseLastRole: raw['base_last_role'] is String
          ? raw['base_last_role'] as String
          : null,
      baseLastFp: fp,
      basePrefixFp: prefixFp,
    );
  }
}

/// Persistence anchor per sesi (`<dir>/<sessionId>.json`, atomic
/// tmp-then-rename, never-raises) — paritas persist baris sesi Hermes
/// (`model_config._usage_anchor`) agar anchor bertahan lintas turn: loop
/// Tiko dibangun per-turn, identitas objek tidak pernah cukup.
class UsageAnchorStore {
  UsageAnchorStore(this.directory);

  final String directory;

  String _path(String sessionId) {
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return '$directory/$safe.json';
  }

  /// Baca anchor tersimpan; null bila absen/tak terbaca/korup (fail-closed).
  UsageAnchor? load(String sessionId) {
    try {
      final f = File(_path(sessionId));
      if (!f.existsSync()) return null;
      final raw = json.decode(f.readAsStringSync());
      return UsageAnchor.fromJson(raw['anchor'] ?? raw);
    } catch (_) {
      return null;
    }
  }

  /// Simpan (atau hapus, [anchor] = null) anchor sesi. Best-effort: sesi
  /// mungkin belum ada di disk — kegagalan persist tidak boleh menggagalkan
  /// turn (Hermes `persist_usage_anchor`).
  void save(String sessionId, UsageAnchor? anchor) {
    try {
      final dir = Directory(directory);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File(_path(sessionId));
      if (anchor == null) {
        if (f.existsSync()) f.deleteSync();
        return;
      }
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(
        json.encode({'anchor': anchor.toJson()}),
        flush: true,
      );
      tmp.renameSync(f.path);
    } catch (_) {} // best-effort
  }
}
