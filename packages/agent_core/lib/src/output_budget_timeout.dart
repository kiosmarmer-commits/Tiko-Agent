/// Output-budget stale-timeout scaling (Hermes `agent/output_budget_timeout.py`):
/// provider yang membagi anggaran `max_output_tokens` besar ke beberapa hop
/// server-capped memakai satu stale timer non-streaming untuk semua hop.
/// Mengalikan timer implisit dengan upper-bound jumlah hop menjaga decode
/// panjang yang sehat agar tidak dibunuh terlalu dini; streaming re-arm di
/// setiap chunk dan tidak perlu penskalaan.
library;

/// Cap token per request terkecil (unary; hop streamed dapat 65.536) — jumlah
/// hop yang diturunkan darinya adalah upper bound.
const outputBudgetHopTokens = 32768;

/// Upper-bound jumlah hop untuk [maxOutputTokens]; 1 bila muat satu request.
int outputBudgetHops(Object? maxOutputTokens) {
  final budget = maxOutputTokens is int && maxOutputTokens > 0
      ? maxOutputTokens
      : 0;
  if (budget <= 0) return 1;
  return (budget + outputBudgetHopTokens - 1) ~/ outputBudgetHopTokens;
}
