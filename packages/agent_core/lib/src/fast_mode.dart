// Hermes parity: `agent/fast_mode.py` — fast mode ber-jendela bounded
// (`/fast auto`, `/fast cold`) + static tier (`/fast`, `/fast ultrafast`).
//
// Tier dipetakan dari kata user/config ke nilai wire: `fast|priority|on` →
// `priority` (OpenAI service_tier; Anthropic/xAI fast mode), `ultrafast|
// ultra` → `ultrafast` (OpenAI-only, gated per model), `auto` (jendela N
// detik per user turn), `cold` (hanya turn pertama sesi tanpa riwayat),
// kata normal/off → null. Satu tabel kata dipakai semua surface (config,
// perintah, GUI) supaya tier baru cukup satu edit.
//
// Deviasi sadar dari Hermes (didokumentasikan): Hermes menyentuh header
// rate-limit fast-mode Anthropic (`anthropic-fast-*-tokens-limit`) lewat
// objek error ber-headers untuk mendeteksi kapasitas fast = 0; provider
// Tiko tidak mengekspos header error, jadi model ditandai tidak tersedia
// saat 429 terjadi pada request ber-tier (retry sekali di tier normal —
// loop sudah punya retry chain).
//
// Fail-closed/fail-open: kata tak dikenal → null (normal) di jalur config;
// `parseExactServiceTier` untuk pilihan eksplisit client melempar ArgumentError
// alih-alih membaca kata asing sebagai normal.
library;

import 'interfaces.dart';
import 'models.dart';

const String fastTierPriority = 'priority';
const String fastTierUltrafast = 'ultrafast';
const String fastTierAuto = 'auto';
const String fastTierCold = 'cold';

const Set<String> boundedFastModes = {fastTierAuto, fastTierCold};

/// Jendela fast default (Hermes `DEFAULT_WINDOW_SECONDS`).
const int defaultFastWindowSec = 60;

/// Header limit fast-mode Anthropic; nilai `0` = organisasi tanpa kapasitas
/// fast untuk model ini (documented fast-mode rate-limit headers).
const List<String> fastLimitHeaders = [
  'anthropic-fast-input-tokens-limit',
  'anthropic-fast-output-tokens-limit',
];

const Set<String> _normalTierWords = {
  '',
  'normal',
  'default',
  'standard',
  'off',
  'none',
};

/// Kata user/config → tier kanonik. Satu tabel untuk semua surface.
const Map<String, String> serviceTierWords = {
  'fast': fastTierPriority,
  'priority': fastTierPriority,
  'on': fastTierPriority,
  'ultrafast': fastTierUltrafast,
  'ultra': fastTierUltrafast,
  'auto': fastTierAuto,
  'cold': fastTierCold,
};

/// Alias `/fast` ter-tipe → kata kanonik (picker selalu kirim nilai kanonik).
const Map<String, String> fastArgAliases = {
  'ultra': 'ultrafast',
};

/// `agent.service_tier` untuk kata user/config; null untuk normal dan kata
/// tak dikenal (fail-open — config salah tidak pernah mengubah perilaku).
String? parseServiceTier(Object? raw) {
  var value = raw?.toString().trim().toLowerCase() ?? '';
  if (_normalTierWords.contains(value)) return null;
  return serviceTierWords[value];
}

/// [parseServiceTier] ketat untuk pilihan eksplisit client: `''`/normal →
/// null (pin normal), kata tak dikenal → ArgumentError (bukan diam-diam
/// dibaca normal).
String? parseExactServiceTier(Object? raw) {
  var value = raw?.toString().trim().toLowerCase() ?? '';
  if (_normalTierWords.contains(value)) return null;
  final tier = serviceTierWords[value];
  if (tier == null) {
    throw ArgumentError('unknown service tier: $value');
  }
  return tier;
}

/// Kata user-facing untuk tier tersimpan (`priority` → `fast`, null →
/// `normal`).
String serviceTierWord(String? tier) {
  if (tier == null || tier.isEmpty) return 'normal';
  return switch (tier) {
    fastTierPriority => 'fast',
    _ => tier,
  };
}

/// State fast mode per sesi: tier terpasang + jendela bounded + daftar
/// model yang dipelajari tidak punya kapasitas fast.
class FastModeState {
  FastModeState({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Tier kanonik terpasang sesi: 'priority'/'ultrafast' (static, selalu
  /// dikirim), 'auto'/'cold' (bounded window), null = normal.
  String? tier;

  /// Panjang jendela bounded (dari `agent.fast_auto_seconds`).
  Duration window = const Duration(seconds: defaultFastWindowSec);

  DateTime _fastUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Model yang dipelajari tidak punya kapasitas fast (stop mengirim tier
  /// untuk model ini sampai proses berakhir).
  final Set<String> unavailableModels = {};

  /// Buka (atau tolak) jendela fast di batas user turn. Static tier tidak
  /// membuka jendela; `cold` hanya saat riwayat pra-turn tidak memuat
  /// pesan user/assistant/tool (turn pertama sesi).
  void beginTurn(List<ChatMessage> priorHistory) {
    _fastUntil = DateTime.fromMillisecondsSinceEpoch(0);
    final mode = tier;
    if (mode == null || !boundedFastModes.contains(mode)) return;
    if (mode == fastTierCold &&
        priorHistory.any(
          (m) =>
              m.role == 'user' || m.role == 'assistant' || m.role == 'tool',
        )) {
      return;
    }
    _fastUntil = _clock().add(window);
  }

  /// True selama jendela bounded masih terbuka.
  bool windowOpen() => _clock().isBefore(_fastUntil);

  /// Tier efektif untuk request ke [model]: static tier selalu dikirim;
  /// bounded tier hanya saat jendela terbuka; model yang sudah dipelajari
  /// tanpa kapasitas fast tidak pernah menerima tier (retry di tier normal).
  String? effectiveServiceTier(String? model) {
    final mode = tier;
    if (mode == null) return null;
    if (model != null && unavailableModels.contains(model)) return null;
    if (boundedFastModes.contains(mode)) {
      return windowOpen() ? mode : null;
    }
    return mode;
  }

  /// Tandai [model] tidak punya kapasitas fast. False bila sudah ditandai
  /// — pemanggil retry paling sekali per model.
  bool markUnavailable(String? model) {
    if (model == null || model.isEmpty) return false;
    return unavailableModels.add(model);
  }
}

/// True untuk 429 pada request fast yang header limit-nya `0` — organisasi
/// memang tidak punya kapasitas fast untuk model ini, menunggu maupun
/// rotasi kunci tidak menolong (Hermes `fast_mode_unprovisioned`).
bool fastModeUnprovisioned({
  required int? statusCode,
  required Map<String, String> headers,
}) {
  if (statusCode != 429) return false;
  return fastLimitHeaders.any(
    (h) => headers[h]?.trim() == '0',
  );
}
