# Laporan — Scheduler Delivery Ack/Retry — 2026-11-09

- **Task**: menutup gap *\"Scheduler outbound delivery acknowledgement/retry
  after the host gateway accepts or rejects the message\"* dari bagian
  \"Remaining release blockers\" di `TIKO-REPAIR-STATUS-2026-11-07.md`.
- **HEAD dasar**: `466136bc` (CI hijau, termasuk fallback Tavily web_search).

## Masalah

Sebelum patch ini, alur job scheduler berhenti di \"agent berhasil\":

1. `Scheduler` menjalankan giliran agent; sukses → `JobStore.completeRun`
   (run dianggap selesai) + event `job.completed`.
2. `agentd` mendengarkan `job.completed` lalu mengirim hasil ke gateway
   secara *fire-and-forget* (`unawaited(target.send(...))`).

Jika `gateway.send()` gagal (Telegram down, webhook 5xx, DNS mati), job
sudah dianggap selesai: hasil hilang, tidak ada retry, tidak ada catatan
kegagalan yang durabel.

## Perilaku baru

1. Kontrak baru `DeliveryHandler` di `agent_scheduler`: host (agentd)
   menyediakan *sink* delivery per channel.
2. Setelah giliran agent sukses, runtime mengantre output secara durabel
   (`JobStore.awaitDelivery`): `pending_run_at` tetap dipegang — run baru
   dianggap selesai setelah gateway meng-ack delivery.
3. Scheduler memproses antrean delivery tiap tick: klaim (increment attempt
   dipersist lebih dulu — *at-least-once*) → kirim dengan timeout 30 detik →
   ack (`completeDelivery`) → event `job.delivered`.
4. Gagal → retry dengan backoff `[20s, 1m, 5m, 15m, 1j]`, maksimum 5 upaya;
   setelah itu `delivery_state: failed` + `delivery_error` durabel dan
   event `job.delivery_failed`. Giliran agent **tidak** diulang untuk
   kegagalan delivery (mencegah duplikasi pekerjaan agent).
5. Semua state delivery dipersist di `jobs.json` dan tahan restart: crash
   antara generate dan kirim → delivery yang di-replay, bukan agent.
6. Saluran tanpa gateway yang cocok (mis. `cli` saat daemon tanpa Telegram)
   tetap di-ack lokal — hasil tersimpan di sesi, tidak pernah dikirim silang
   ke gateway lain (semantik F-14 dipertahankan).
7. Tanpa *sink* `deliver` (mode embedded/legacy), kontrak lama tetap: run
   selesai begitu giliran agent sukses.

## Perubahan kode

| File | Isi |
|---|---|
| `packages/agent_scheduler/lib/src/job_store.dart` | field delivery (`delivery_run_id`, `delivery_text`, `delivery_attempts`, `delivery_next_at`, `last_delivery_at`, `delivery_error`, `delivery_state`) + persist JSON + metode `awaitDelivery` / `deliveryPending` / `claimDueDeliveries` / `completeDelivery` / `scheduleDeliveryRetry` / `failDeliveryPermanently` |
| `packages/agent_scheduler/lib/src/scheduler.dart` | `typedef DeliveryHandler`; parameter `deliver` / `maxDeliveryAttempts` / `deliveryBackoff` / `deliveryTimeout` + callback; loop `_runDeliveries`; skip eksekusi ulang agent saat delivery pending |
| `packages/tiko_runtime/lib/src/tiko_runtime.dart` | `startScheduler(deliver:)` — antre durabel sebelum emit `job.completed`; event baru `job.delivered` / `job.delivery_retry` / `job.delivery_failed` |
| `apps/agentd/bin/agentd.dart` | listener `job.completed` fire-and-forget diganti *sink* `deliver:`; `gateway.send` di-await; tanpa gateway → ack lokal |
| `packages/agent_scheduler/test/delivery_ack_test.dart` | BARU — 8 test (matriks di bawah) |

## Matriks test

| Skenario | Ekspektasi |
|---|---|
| `awaitDelivery` + `completeDelivery` | run di-ack hanya setelah delivery; re-queue `runId` sama idempoten; klaim ulang kosong |
| Restart saat delivery pending | delivery di-replay, agent tidak dijalankan ulang |
| `deliver` sukses | `job.delivered`, attempts 1, agent tepat 1x, tidak re-run di tick berikut |
| Gagal lalu sukses | retry backoff, agent tetap 1x, attempts 2 |
| Retry habis (max 2 di test) | `delivery_state: failed`, `pending_run_at` null, `delivery_error` terisi, agent tetap 1x |
| Gateway hang | timeout dihitung attempt gagal, lalu sukses di upaya berikut |
| Legacy tanpa `deliver` | `completeRun` langsung (perilaku lama dipertahankan) |
| JSON round-trip | field delivery termuat; file lama tanpa key delivery tetap termuat; nilai invalid ditolak per entri |

## Batasan

- *At-least-once*: gateway harus idempoten terhadap kirim ulang. Telegram
  `sendText` tidak idempoten sempurna — duplikat mungkin bila crash tepat
  setelah kirim sukses tetapi sebelum ack terpersist.
- Tidak ada dead-letter queue terpisah; `delivery_state: failed` +
  `delivery_error` di `jobs.json` adalah catatannya.

## Verifikasi

- CI GitHub Actions hijau di HEAD (job \"Dart analysis, tests and CLI
  smoke\" + \"Flutter client analysis, tests and web build\").
- `dart analyze --fatal-infos --fatal-warnings` bersih.
