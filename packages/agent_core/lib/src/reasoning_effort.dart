// Hermes parity: `agent/reasoning_effort.py` — kosakata canonical
// reasoning-effort dan clamping wire.
//
// TANGGA effort internal (none→ultra) lebih lebar dari yang diterima wire
// provider mana pun. Satu sumber kebenaran: [effortLadder] (none→tinggi),
// [clampEffort] (verbatim bila didukung, else level LEBIH LEMAH terdekat;
// hanya bila tak ada yang lebih lemah → level terlemah yang didukung), dan
// konstanta kosakata wire bernama. Aturan: bentuk wire tetap lokal di
// provider, hanya matematika kosakata di sini; unset tetap unset (tidak
// pernah mengarang effort); provider menolak level → perbaiki set yang
// dideklarasikan, jangan predikat.
//
// Deviasi sadar dari Hermes: tabel kosakata per-endpoint versi-Hermes
// (Astra/GPT-6/Ox-Alpha/GLM dsb.) tidak di-port — Tiko mendeklarasikan set
// wire untuk transport yang benar-benar dimilikinya (OpenAI-compat,
// Responses, Anthropic); vendor quirks menyusul bila terbukti dibutuhkan.
library;

/// Urutan canonical rendah→tinggi untuk clamping level terdekat.
/// Termasuk `none` agar disable eksplisit bisa di-clamp bila provider
/// mempublikasikannya sebagai level. `ultra` internal (tier produk Codex):
/// tak ada wire yang menerimanya.
const List<String> effortLadder = [
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra',
];

/// Kosakata wire OpenAI-compatible terlebar (OpenRouter, Nous Portal).
const List<String> openAiCompatWireEfforts = [
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max',
];

/// Hermes `THINKING_BUDGET` — effort → `budget_tokens` Anthropic.
const Map<String, int> anthropicThinkingBudget = {
  'xhigh': 32000,
  'high': 16000,
  'medium': 8000,
  'low': 4000,
};

/// Default Hermes bila effort tidak ada di tabel (mis. `minimal`).
const int anthropicThinkingBudgetDefault = 8000;

/// Hermes `ADAPTIVE_EFFORT_MAP` — effort → effort adaptive Anthropic.
/// `minimal` alias legacy untuk `low` di semua model.
const Map<String, String> anthropicAdaptiveEffortMap = {
  'ultra': 'max',
  'max': 'max',
  'xhigh': 'xhigh',
  'high': 'high',
  'medium': 'medium',
  'low': 'low',
  'minimal': 'low',
};

int _ladderIndex(String level) => effortLadder.indexOf(level);

/// True bila [level] dikenali tangga canonical.
bool isKnownEffort(String? level) {
  final l = (level ?? '').trim().toLowerCase();
  return l.isNotEmpty && _ladderIndex(l) >= 0;
}

/// Clamp effort yang diminta ke level yang didukung wire.
///
/// [overrides] (mapping vendor yang dideklarasikan, mis. Kimi K3
/// `medium → high`) dikonsultasikan lebih dulu. Selain itu request lewat
/// apa adanya bila didukung, bila set didukung tak diketahui/kosong, atau
/// bila bukan level tangga yang dikenali (provider custom boleh memakai
/// nama bespoke). Else **level lebih lemah terdekat** — clamp tidak pernah
/// menaikkan biaya; bila tak ada yang lebih lemah, level terlemah (floor
/// provider adalah kecocokan jujur terdekat). Monotonik: request kuat tak
/// pernah melemah di bawah hasil request lebih lemah. `none` men-disable
/// reasoning — tidak pernah jadi target degradasi untuk ask enabled.
String? clampEffort(
  String? effort,
  Iterable<String>? supported, {
  Map<String, String> overrides = const {},
}) {
  final requested = (effort ?? '').trim().toLowerCase();
  if (requested.isEmpty || supported == null) return effort;
  final supportedNorm = [
    for (final s in supported)
      if (isKnownEffort(s)) s.trim().toLowerCase(),
  ];
  if (supportedNorm.isEmpty || supportedNorm.contains(requested)) {
    return effort;
  }
  final override = overrides[requested];
  if (override != null && supportedNorm.contains(override)) {
    return override;
  }
  if (_ladderIndex(requested) < 0) return effort;
  final candidates = [
    for (final level in supportedNorm)
      if (level != 'none') level,
  ];
  if (candidates.isEmpty) return effort;
  final requestedIdx = _ladderIndex(requested);
  final below = [
    for (final level in candidates)
      if (_ladderIndex(level) < requestedIdx) level,
  ];
  if (below.isNotEmpty) {
    var best = below.first;
    for (final level in below) {
      if (_ladderIndex(level) > _ladderIndex(best)) best = level;
    }
    return best;
  }
  var weakest = candidates.first;
  for (final level in candidates) {
    if (_ladderIndex(level) < _ladderIndex(weakest)) weakest = level;
  }
  return weakest;
}

/// Effort → `budget_tokens` Anthropic (`none` → null: disabled, caller
/// membiarkan field off wire; `minimal` → default 8000 ala Hermes).
int? anthropicThinkingBudgetFor(String? effort) {
  final e = (effort ?? '').trim().toLowerCase();
  if (e.isEmpty || e == 'none') return null;
  return anthropicThinkingBudget[e] ?? anthropicThinkingBudgetDefault;
}

/// Effort → effort adaptive Anthropic (`none` → null: field off wire).
String? anthropicAdaptiveEffortFor(String? effort) {
  final e = (effort ?? '').trim().toLowerCase();
  if (e.isEmpty || e == 'none') return null;
  return anthropicAdaptiveEffortMap[e];
}
