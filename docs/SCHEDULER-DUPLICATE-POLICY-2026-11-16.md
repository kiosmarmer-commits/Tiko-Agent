# Scheduler Delivery Duplicate Policy — 16 November 2026

Perbaikan A1 (audit internal 2026-11-16): scheduler delivery bersifat **at-least-once** — counter upaya dipersist *sebelum* pengiriman, sehingga crash di tengah pengiriman me-replay delivery. Konsekuensinya: jika platform sudah menerima pesan tetapi daemon mati sebelum ack, pesan **terkirim dua kali** saat dipulihkan. Platform (Telegram/Discord/Slack/Email) tidak menyediakan idempotency key untuk sendMessage, jadi duplikasi tidak bisa dihilangkan sepenuhnya — kini jendela itu **eksplisit dan dapat dikonfigurasi**.

## Deteksi delivery in-flight

State machine delivery: `awaitDelivery` (attempts=0, next_at=now) → `claimDueDeliveries` (attempts++, next_at=null, **dipersist sebelum kirim**) → sink → `completeDelivery` (ack) / `scheduleDeliveryRetry` (next_at=masa depan) / `failDeliveryPermanently`.

Delivery yang tertangkap di tengah pengiriman saat proses mati terdeteksi deterministik:

```
deliveryRunId != null && deliveryState == 'pending'
  && deliveryNextAt == null && deliveryAttempts >= 1
```

(`JobStore.inFlightDeliveries()`) — sudah diklaim tapi belum di-ack maupun dijadwalkan ulang; satu-satunya cara mencapai state ini adalah proses mati di antara klaim dan penyelesaian.

## Kebijakan: `scheduler.duplicate_policy`

| Nilai | Perilaku saat pulih | Trade-off |
|---|---|---|
| `resend` (default) | Kirim ulang di tick berikutnya (perilaku lama, at-least-once) | Output tidak pernah hilang; penerima bisa melihat duplikat |
| `review` | Tandai **gagal permanen** dengan penjelasan + callback `onDeliveryFailed`; tanpa kirim ulang otomatis | Tanpa duplikat; output tertahan sampai operator meninjau |

```yaml
scheduler:
  duplicate_policy: review   # default: resend
```

Nilai tidak dikenal ditolak fail-closed sebagai `ConfigIssue`.

## Implementasi

- `packages/agent_scheduler/lib/src/job_store.dart` — `inFlightDeliveries()`.
- `packages/agent_scheduler/lib/src/scheduler.dart` — enum `DeliveryDuplicatePolicy { resend, review }`, param `duplicatePolicy`, recovery di `start()` sebelum tick pertama.
- `packages/tiko_runtime/lib/src/tiko_config.dart` — `scheduler.duplicate_policy` → `TikoConfig.schedulerDuplicatePolicy`; `startScheduler()` meneruskannya ke `Scheduler`.

## Test

`packages/agent_scheduler/test/duplicate_policy_test.dart` (4 test):
1. `inFlightDeliveries` mendeteksi delivery yang mati di tengah kirim lintas restart store.
2. Policy `resend` (default): delivery dikirim ulang di tick berikutnya.
3. Policy `review`: tanpa kirim ulang, `onDeliveryFailed` terpanggil, state `failed` dengan pesan penjelasan.
4. Policy `review`: delivery baru yang belum diklaim tetap terkirim normal.

Plus 2 test config (default + nilai tidak dikenal ditolak) di `tiko_config_test.dart`.

## Batasan

- Platform tanpa idempotency key tidak bisa menjamin exactly-once; policy `review` mengubah jendela duplikat menjadi keputusan operator, bukan menghapusnya.
- Deteksi in-flight bersifat per-proses: daemon kedua yang berjalan bersamaan (RuntimeLock mencegah) tidak tercakup.
