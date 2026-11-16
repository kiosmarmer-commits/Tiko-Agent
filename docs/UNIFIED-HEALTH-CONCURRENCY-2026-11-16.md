# Unified Provider Health — Test Regresi Konkurensi (C3)

Tanggal: 2026-11-16
Status: Implementasi unified provider health sudah ada di `main` (row roadmap P1 "Unified provider health state"); sisa pekerjaan yang dinyatakan roadmap adalah **test regresi konkurensi + CI**. PR ini menambahkan test tersebut.

## Latar belakang

State machine kesehatan provider kini SATU (`ProviderHealth` di `agent_core`), dibagi oleh:

- `Router` (pemilihan primary/fallback, snapshot `providerHealth()`),
- `CircuitBreaker` / `BreakerLlmProvider` (adapter tipis, `agent_providers`),
- runtime: `breakerFor(id)`, `auxiliaryLlm()`, `recordProviderFailure/Success`.

Karena state dibagi lintas permukaan, semantik konkurensi half-open **single-probe** adalah invariant yang wajib dijaga: tepat satu pemanggil boleh memenangkan slot probe; pemanggil lain ditolak fail-closed; slot tidak boleh macet.

## Test regresi baru

File: `packages/tiko_runtime/test/provider_health_concurrency_test.dart` (6 test, semua via `Future.wait` untuk mensimulasikan pemanggil paralel pada event loop Dart):

1. **N pemanggil paralel ditolak saat breaker terbuka** — 20 pemanggil `tryAcquire()` paralel saat fase open; semua ditolak, dan `failures` tetap 3 (panggilan yang diblokir tidak boleh double-count sebagai kegagalan baru).
2. **Kegagalan paralel dari banyak pemanggil** — 10 pemanggil `recordProviderFailure` paralel; semua tercatat tepat sekali (tidak ada lost update), breaker terbuka.
3. **Half-open: tepat SATU pemenang probe dari 20 pemanggil paralel** — memakai clock injeksi deterministik; hanya satu `tryAcquire()` yang menang; `selectable` false selama probe berjalan; `releaseProbe()` membebaskan slot untuk probe berikutnya.
4. **Probe sukses menutup breaker untuk semua** — setelah verdict sukses dari pemenang probe, 10 pemanggil paralel kembali dilayani (fase closed).
5. **Pembatalan stream tanpa verdict melepas slot probe** — `BreakerLlmProvider` di atas provider palsu berbasis `StreamController`; konsumen membatalkan stream saat menerima event pertama (pola nyata timeout/abort); `finally` generator menjalankan `releaseProbe()` sehingga half-open tidak macet.
6. **`auxiliaryLlm()` paralel saat breaker open** — 8 stream paralel semuanya menerima `LlmError` kode `breaker_open` (fail-closed), dan `failures` tidak berubah (tanpa double-count).

## Temuan teknis selama penulisan test

Pada Dart 3.13.4, membatalkan subscription stream `async*` yang sedang suspensi menunggu event inner (mis. `StreamController` yang tidak pernah selesai) **tidak segera** menghentikan generator — `await sub.cancel()` tidak selesai dan `finally` belum jalan. Pola pembatalan yang benar dan realistis (dipakai test 5): membatalkan subscription **di dalam callback listener** saat generator suspensi di titik `yield` — `finally` langsung jalan dengan `completed=false` → jalur `releaseProbe()`. Di produksi, stream inner (HTTP) pada akhirnya berakhir sehingga `finally` tetap tereksekusi; test ini mengunci jalur `releaseProbe` agar tidak tereliminasi saat refactor.

## Hasil verifikasi lokal (Dart 3.13.4, sama dengan CI)

- `dart analyze --fatal-warnings`: bersih untuk `tiko_runtime`, `agent_providers`, `agent_core`.
- `dart test`: tiko_runtime **229 lulus**, agent_providers **44 lulus**, agent_core **210 lulus**.

## Batasan yang tetap berlaku

- API `CircuitBreaker`/`BreakerLlmProvider` tanpa injeksi tetap ada untuk backward-compat; deprecation hanya setelah audit consumer eksternal (sesuai kriteria roadmap).
- Jangan double-wrap chat path dengan `BreakerLlmProvider` yang berbagi `ProviderHealth` yang sama — verdict akan tercatat ganda (dijelaskan pada doc-comment runtime).
