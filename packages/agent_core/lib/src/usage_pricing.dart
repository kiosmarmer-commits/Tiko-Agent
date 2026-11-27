/// Usage pricing (Hermes parity: `agent/usage_pricing.py`): estimasi biaya
/// USD dari usage token dengan rate card list-price model yang dikenal.
/// Status jujur: `estimated` (harga dari rate card), `unknown` (model tak
/// dikenal atau tanpa usage) — Tiko tidak pernah menampilkan "actual" karena
/// tidak menerima invoice provider. Label sub-cent dirender 4 desimal agar
/// model murah tidak pernah tampil sebagai "$0.00" (Hermes #79220).
library;


/// Harga list-price USD per juta token (input/output) satu model.
class ModelPricing {
  const ModelPricing({
    required this.inputPerMTok,
    required this.outputPerMTok,
    this.source = 'rate-card',
  });

  final double inputPerMTok;
  final double outputPerMTok;
  final String source;
}

/// Rate card list-price model populer (USD per MTok). Snapshot statis —
/// harga provider berubah; status tetap `estimated` agar tidak pernah
/// berpura-pura presisi.
const Map<String, ModelPricing> _rateCard = {
  'gpt-4o': ModelPricing(inputPerMTok: 2.50, outputPerMTok: 10.00),
  'gpt-4o-mini': ModelPricing(inputPerMTok: 0.15, outputPerMTok: 0.60),
  'gpt-4.1': ModelPricing(inputPerMTok: 2.00, outputPerMTok: 8.00),
  'gpt-4.1-mini': ModelPricing(inputPerMTok: 0.40, outputPerMTok: 1.60),
  'gpt-4.1-nano': ModelPricing(inputPerMTok: 0.10, outputPerMTok: 0.40),
  'o3': ModelPricing(inputPerMTok: 2.00, outputPerMTok: 8.00),
  'o4-mini': ModelPricing(inputPerMTok: 1.10, outputPerMTok: 4.40),
  'claude-opus-4': ModelPricing(inputPerMTok: 15.00, outputPerMTok: 75.00),
  'claude-sonnet-4': ModelPricing(inputPerMTok: 3.00, outputPerMTok: 15.00),
  'claude-haiku-4': ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4.00),
  'claude-3-7-sonnet': ModelPricing(inputPerMTok: 3.00, outputPerMTok: 15.00),
  'gemini-2.5-pro': ModelPricing(inputPerMTok: 1.25, outputPerMTok: 10.00),
  'gemini-2.5-flash': ModelPricing(inputPerMTok: 0.30, outputPerMTok: 2.50),
  'gemini-2.0-flash': ModelPricing(inputPerMTok: 0.10, outputPerMTok: 0.40),
  'deepseek-chat': ModelPricing(inputPerMTok: 0.27, outputPerMTok: 1.10),
  'deepseek-reasoner': ModelPricing(inputPerMTok: 0.55, outputPerMTok: 2.19),
  'mistral-large': ModelPricing(inputPerMTok: 2.00, outputPerMTok: 6.00),
  'mistral-small': ModelPricing(inputPerMTok: 0.10, outputPerMTok: 0.30),
  'grok-3': ModelPricing(inputPerMTok: 3.00, outputPerMTok: 15.00),
  'grok-3-mini': ModelPricing(inputPerMTok: 0.30, outputPerMTok: 0.50),
  'kimi-k2': ModelPricing(inputPerMTok: 0.60, outputPerMTok: 2.50),
};

final RegExp _dateSuffix = RegExp(r'-\d{4}-\d{2}-\d{2}$');

/// Cari harga model: exact → tanggal-suffix dipangkas → prefix terpanjang.
/// Null bila model tidak dikenal rate card.
ModelPricing? pricingForModel(String? model) {
  if (model == null) return null;
  final key = model.trim().toLowerCase();
  if (key.isEmpty) return null;
  final exact = _rateCard[key];
  if (exact != null) return exact;
  final noDate = _dateSuffix.firstMatch(key) != null
      ? key.replaceFirst(_dateSuffix, '')
      : key;
  final noDateHit = _rateCard[noDate];
  if (noDateHit != null) return noDateHit;
  ModelPricing? best;
  var bestLen = 0;
  for (final e in _rateCard.entries) {
    if (noDate.startsWith('${e.key}-') && e.key.length > bestLen) {
      best = e.value;
      bestLen = e.key.length;
    }
  }
  return best;
}

/// Status estimasi biaya — subset Hermes (Tiko tidak pernah `actual`).
const costStatusEstimated = 'estimated';
const costStatusUnknown = 'unknown';

/// Hasil estimasi biaya satu turn.
class CostEstimate {
  const CostEstimate({
    required this.usd,
    required this.status,
    this.model = '',
  });

  final double usd;

  /// `estimated` (rate card) atau `unknown` (model tak dikenal / tanpa usage).
  final String status;
  final String model;

  Map<String, dynamic> toJson() => {
        'usd': usd,
        'status': status,
        if (model.isNotEmpty) 'model': model,
      };
}

/// Estimasi biaya USD satu turn dari usage yang dilaporkan provider.
/// Model tak dikenal / tanpa usage → status `unknown`, usd 0 (fail-open).
CostEstimate estimateCostUsd({
  String? model,
  required int promptTokens,
  required int completionTokens,
}) {
  if (promptTokens <= 0 && completionTokens <= 0) {
    return const CostEstimate(usd: 0, status: costStatusUnknown);
  }
  final pricing = pricingForModel(model);
  if (pricing == null) {
    return CostEstimate(
      usd: 0,
      status: costStatusUnknown,
      model: model ?? '',
    );
  }
  final usd = (promptTokens / 1e6) * pricing.inputPerMTok +
      (completionTokens / 1e6) * pricing.outputPerMTok;
  return CostEstimate(
    usd: usd,
    status: costStatusEstimated,
    model: model ?? '',
  );
}

/// Label biaya user-facing: nol → "$0.00"; sub-cent → "~$0.0046" (4 desimal,
/// atau "~$<0.0001" bila pembulatannya nol agar tidak pernah terbaca nol);
/// else "~$1.23".
String formatCostLabel(double amount) {
  if (amount == 0) return r'$0.00';
  if (amount < 0.01) {
    final label = '~\$${amount.toStringAsFixed(4)}';
    return label == '~\$0.0000' ? '~\$<0.0001' : label;
  }
  return '~\$${amount.toStringAsFixed(2)}';
}
