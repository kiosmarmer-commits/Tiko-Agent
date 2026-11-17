# C9 — Audit Penutupan Roadmap: Unified Provider Health & Flutter Error Transparency

Tanggal: 2026-11-17 · Status: Audit selesai, dua row roadmap ditutup · PR: vibe/health-audit-closure-563120

## Row 1 — Unified provider health state (P1)

**Kondisi awal row:** "`CircuitBreaker`/`BreakerLlmProvider` hanya API legacy dan tidak di-wire runtime."

**Hasil audit (bukti pada main `7a95a50` + C3):**

1. **State machine tunggal per provider.** `TikoRuntime.breakerFor(providerId)`
   (tiko_runtime.dart:1246) adalah adapter `CircuitBreaker` di atas
   `ProviderHealth` yang **identik** dengan yang dipakai Router untuk
   seleksi/fallback — tidak ada counter kesehatan yang divergen. Diverifikasi
   `identical()` di `unified_health_test.dart` dan
   `auxiliary_health_test.dart:38,49`.
2. **Jalur auxiliar ter-wire produksi.** `auxiliaryLlm()` (tiko_runtime.dart:1264)
   membungkus provider pertama dengan `BreakerLlmProvider` + health bersama;
   dipakai di 3 titik produksi: subagent (baris 136), reflection loop (148),
   skill synthesis + judge evolusi diri (1565).
3. **Audit pemakaian LLM langsung.** Semua pemanggilan LLM di apps/agentd,
   apps/tiko, agent_gateway, agent_scheduler melewati `rt.chat` (tercatat
   sekali via AgentLoop) atau jalur auxiliar terbungkus. Tidak ada permukaan
   lain yang memanggil provider langsung tanpa health.
4. **Audit consumer `CircuitBreaker` standalone.** Pencarian seluruh
   packages/apps: hanya adapter `breakerFor` (health-based), test, dan
   definisi di `agent_providers`. Tidak ada breaker standalone yang mencatat
   ke counter terpisah. API publik dipertahankan (dipakai internal + tersedia
   untuk permukaan direct-use masa depan) dengan dokumentasi kontrak
   "record exactly once" pada docstring `breakerFor`.
5. **Regression concurrency (C3, PR #66).** 6 test concurrency
   (`provider_health_concurrency_test.dart`): single-probe half-open, tidak
   ada double-count, `releaseProbe` saat cancel, `breaker_open` fail-closed.

**Keputusan:** row ditutup. API legacy tidak dihapus karena: (a) audit
menunjukkan tidak ada state divergen, (b) `breakerFor`/`auxiliaryLlm` adalah
permukaan resmi untuk direct-use, (c) penghapusan API publik hanya merusak
konsumen eksternal tanpa manfaat.

## Row 2 — Flutter API error transparency (P1)

**Kriteria penutupan row:** "Regression test 401 ditambahkan; jalankan
Flutter test/analyze pada CI."

**Bukti terpenuhi:**

1. Admin GET memakai `_throwIf` — HTTP 401/403/5xx tidak lagi disamarkan
   sebagai data kosong.
2. Regression test C7 (PR #70, merged): `apps/agent_flutter/test/token_encoding_test.dart`
   — 5 test mencakup 401/403/500/503 dilempar sebagai exception berkoden,
   token CRLF ditolak lokal, baseUrl malformed, ID unicode, sendMessage unicode.
3. CI menjalankan `flutter analyze` + `flutter test` pada
   `.github/workflows/ci.yml` (langkah "== flutter analyze ==" dan
   "== flutter test =="), gagal build bila analyze/test gagal. Terbukti
   hijau pada seluruh PR C3–C8 (21/21 checks).

**Keputusan:** row ditutup.

## Item yang tetap terbuka (butuh sumber daya eksternal)

| Item | Penghalang |
|---|---|
| Email SMTP live relay/certificate test | Butuh kredensial relay nyata |
| Sandbox QA Android/Termux (probe device, benchmark p50/p95) | Butuh perangkat fisik |
| Vector scale benchmark | Butuh perangkat/data realistis |
| Gateway real-world smoke | Butuh kredensial akun platform |
| TASK-CALC-24..35 | Butuh scope/DoD dari pemilik |
