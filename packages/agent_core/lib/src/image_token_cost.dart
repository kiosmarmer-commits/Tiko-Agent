// Hermes parity: `agent/image_token_cost.py` — harga token per-gambar yang
// dipelajari dari usage nyata provider, bukan formula vendor.
//
// Konstanta flat per-gambar salah di dua arah: screenshot 1920x1080 berbiaya
// ~1.100 token di satu provider dan 4.000+ di model mmproj lokal. Provider
// menghargai setiap gambar tepat pada request yang membawanya, jadi biayanya
// teramati: dengan anchor usage yang fresh (jumlah prompt nyata respons
// sebelumnya), residu antara `prompt_tokens` nyata berikutnya dan
// `anchor + delta teks-saja` adalah harga dari N gambar yang diperkenalkan
// delta itu (Hermes #70328).
//
// Nilai yang dipelajari disimpan per model dalam cache JSON (atomic
// tmp-then-rename) supaya sesi baru mulai terkalibrasi. Never-raises:
// kegagalan kalibrasi atau persist tidak boleh menggagalkan turn.

import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'usage_anchor.dart';

/// Band observasi yang masuk akal: di luar ini adalah noise estimasi teks,
/// bukan harga gambar.
const int minPlausibleImageTokenCost = 64;
const int maxPlausibleImageTokenCost = 32768;

/// Faktor EMA pembaruan nilai yang dipelajari (Hermes `_EMA_ALPHA`).
const double imageTokenCostEmaAlpha = 0.5;

/// Hitung jumlah gambar pada daftar pesan (vision).
int countImages(List<ChatMessage> messages) {
  var n = 0;
  for (final m in messages) {
    n += m.images?.length ?? 0;
  }
  return n;
}

/// Tabel harga per-gambar yang dipelajari per model, persisten opsional.
class ImageTokenCostStore {
  ImageTokenCostStore({String? path}) : _path = path;

  final String? _path;
  final Map<String, int> _learned = {};
  bool _loaded = false;

  String key(String? model) => (model ?? '').trim().toLowerCase();

  Map<String, int> _table() {
    if (_loaded || _path == null) return _learned;
    _loaded = true;
    try {
      final f = File(_path);
      if (!f.existsSync()) return _learned;
      final raw = json.decode(f.readAsStringSync());
      if (raw is Map) {
        raw.forEach((k, v) {
          if (k is String &&
              v is int &&
              minPlausibleImageTokenCost <= v &&
              v <= maxPlausibleImageTokenCost) {
            _learned[k] = v;
          }
        });
      }
    } catch (_) {} // best-effort
    return _learned;
  }

  /// Harga per-gambar yang dipelajari untuk [model], else harga default.
  int learnedFor(String? model) =>
      _table()[key(model)] ?? defaultImageTokenCost;

  /// Pelajari harga per-gambar dari respons yang baru menghargai [messages].
  ///
  /// Memerlukan anchor SEBELUMNYA ([anchor], jumlah nyata request prior)
  /// yang masih cocok: residu `promptTokens - (anchor + delta teks-saja)`
  /// adalah harga provider untuk gambar yang diperkenalkan delta itu.
  /// Return harga baru yang dipelajari, atau null bila respons ini tidak
  /// mengajarkan apa pun (tanpa anchor, tanpa gambar baru, residu tak
  /// masuk akal).
  int? calibrateFromUsage({
    String? model,
    required int promptTokens,
    UsageAnchor? anchor,
    required List<ChatMessage> messages,
  }) {
    try {
      if (promptTokens <= 0 || anchor == null || !anchor.matches(messages)) {
        return null;
      }
      var delta = messages.sublist(anchor.baseCount);
      if (delta.isNotEmpty && delta.first.role == 'assistant') {
        delta = delta.sublist(1);
      }
      final nImages = countImages(delta);
      if (nImages <= 0) return null;
      final textOnly =
          anchor.anchoredContextTokens(messages, imageCost: 0);
      if (textOnly == null) return null;
      final perImage = (promptTokens - textOnly) ~/ nImages;
      if (perImage < minPlausibleImageTokenCost ||
          perImage > maxPlausibleImageTokenCost) {
        return null;
      }
      final k = key(model);
      final table = _table();
      final prior = table[k];
      final learned = prior == null
          ? perImage
          : (prior +
                  (imageTokenCostEmaAlpha * (perImage - prior)).round())
              .clamp(minPlausibleImageTokenCost, maxPlausibleImageTokenCost);
      table[k] = learned;
      _persist();
      return learned;
    } catch (_) {
      return null;
    }
  }

  /// Persist atomik tmp-then-rename (never-raises).
  void _persist() {
    final path = _path;
    if (path == null) return;
    try {
      final f = File(path);
      final parent = f.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(json.encode(_learned), flush: true);
      tmp.renameSync(path);
    } catch (_) {} // best-effort
  }
}
