# Scheduler Delivery — Idempotency Key & Duplicate-Safe (C6)

Tanggal: 2026-11-16
Status: Row roadmap P2 "Scheduler delivery exactly-once semantics". Scheduler sudah punya delivery ack + retry backoff + duplicate policy (resend/review, A1). Kriteria tersisa: **idempotency key/channel support atau dokumentasi UX duplicate-safe** — PR ini memberikan keduanya.

## Perubahan

### 1. `OutboundMessage.idempotencyKey` (agent_core)
Field opsional (default `''`, backward compatible). Gateway yang platformnya mendukung dedup memakai key ini agar kirim ulang (retry/crash at-least-once) tidak menghasilkan pesan duplikat di sisi platform.

### 2. `deliveryIdempotencyKey(jobId, runId)` (agent_scheduler)
Helper deterministik `'tik-<jobId>_<runId>'`: pasangan (job, run) stabil lintas retry dan crash recovery — kirim ulang run yang sama menghasilkan key identik; run berbeda menghasilkan key berbeda. Terkunci test.

### 3. Dukungan channel nyata
- **Matrix (dedup server-side sungguhan)**: bila `idempotencyKey` ada, txnId dibuat deterministik (`tiko-<key>`, sufiks `-p<n>` untuk pesan ter-split). Homeserver Matrix menolak event duplikat untuk pasangan (room, txnId) — kirim ulang run yang sama **tidak** menghasilkan pesan ganda. Tanpa key: txn acak seperti biasa. Key disanitasi ke `[A-Za-z0-9._-]` (maks 128).
- **Email (dedup best-effort)**: bila key ada, header `Message-ID: <key@tiko-agent>` deterministik ditambahkan — infrastruktur SMTP/penerima yang mendedup berbasis Message-ID dapat mengenali kirim ulang. Tanpa key: tanpa header (perilaku lama).

### 4. Bug nyata diperbaiki: QUIT tidak graceful (Broken pipe race)
`EmailGateway._smtpSend` memanggil `socket.destroy()` **segera setelah** `QUIT` tanpa membaca respons `221`. Socket dengan data masuk yang belum dibaca membuat kernel mengirim **RST** saat destroy — server relay (dan test fake) melihat `SocketException: Broken pipe`, dan error tersebut bisa muncul sebagai error tidak tertangani yang mengganggu koneksi/pengiriman berikutnya. Direproduksi deterministik (dua `send()` beruntun tanpa jeda gagal; dengan jeda 100 ms berhasil). Perbaikan: baca respons 221 best-effort (timeout 2 s) sebelum destroy — pesan tetap dianggap sukses karena sudah di-ack 250.

### 5. Wiring agentd
`deliver` closure kini mengirim `idempotencyKey: deliveryIdempotencyKey(job.id, runId)` pada setiap `OutboundMessage` — channel yang mendukung dedup otomatis melindungi ulang at-least-once.

## Matriks duplicate-safe per platform (dokumentasi jujur)

| Channel | Dedup platform | Efek kirim ulang (policy `resend`) |
|---|---|---|
| Matrix | Ya — txnId | **Tidak ada duplikat** (dengan idempotencyKey) |
| Email | Best-effort — Message-ID | Duplikat tergantung infrastruktur penerima |
| Telegram | Tidak ada API idempotensi | Penerima bisa melihat duplikat |
| Discord | Tidak ada | Penerima bisa melihat duplikat |
| Slack | Tidak ada | Penerima bisa melihat duplikat |
| WhatsApp | Tidak ada | Penerima bisa melihat duplikat |

Exactly-once penuh tidak dapat dijamin pada platform tanpa API idempotensi; operator yang butuh anti-duplikat ketat memakai `scheduler.duplicate_policy: review` (A1) — mencegah duplikat dengan risiko output hilang bila tidak ditinjau. Idempotency key memberikan lapisan dedup di semua channel yang platformnya memungkinkan.

## Verifikasi lokal (Dart 3.13.4, sama dengan CI)

- `dart analyze --fatal-warnings`: bersih (agent_core, agent_scheduler, agent_gateway, agentd).
- `dart test`: agent_core **210**, agent_scheduler **40**, agent_gateway **103** (3× berulang tanpa flake), agentd **7** (3× berulang).
- Test baru: txnId Matrix deterministik + sanitasi + fallback acak; Message-ID email deterministik + tanpa key tanpa header; `deliveryIdempotencyKey` deterministik.

## Batasan yang tetap berlaku

- Platform tanpa API idempotensi tetap at-least-once (lihat matriks di atas) — tidak ada klaim exactly-once palsu.
- `Message-ID` dedup bergantung pada infrastruktur penerima; bukan jaminan protokol SMTP.
