# 05 — Scheduler, Gateway dan API

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be`.

## 1. Scheduler dan job store

`agent_scheduler` memiliki cron parser, `JobStore`, tick loop dan delivery pipeline. `TikoRuntime.startScheduler()` membangun scheduler bersama; `agentd` menyuplai delivery handler yang hanya mengirim ke gateway dengan channel yang sama dengan job.

Default scheduler pada source: tick setiap **20 detik**, delivery timeout **30 detik**, maksimal **5 delivery attempts**, backoff `[20 detik, 1 menit, 5 menit, 15 menit, 1 jam]`.

### Delivery acknowledgement

Ketika giliran agent sukses, output dimasukkan lebih dulu ke state delivery durabel di `jobs.json`. Scheduler mengklaim delivery (attempt dicatat sebelum send), menunggu gateway meng-ack dengan selesainya `send`, lalu menandai delivered. Kegagalan/timeout di-retry tanpa menjalankan ulang giliran agent. Setelah batas upaya, state menjadi failed permanen dan event `job.delivery_failed` dicatat.

Semantik ini **at-least-once**, bukan exactly-once: crash setelah gateway menerima pesan tetapi sebelum ack tersimpan dapat menghasilkan duplikasi saat replay. Tidak ada dead-letter queue terpisah; status/error tersimpan pada job. Jika tidak ada gateway sink yang cocok, host mempertahankan hasil pada session dan melakukan local ack; hasil tidak dikirim ke gateway lain.

## 2. Zona waktu cron

`agent_scheduler` menggunakan package `timezone` melalui adapter `Tz` untuk nama IANA, misalnya `Asia/Jakarta`, `Europe/Berlin`, `America/New_York`. Waktu dinding diubah ke/dari UTC; DST dihitung dari tzdata versi dependency.

Konvensi saat DST:

- Gap spring-forward dinormalisasi maju oleh `TZDateTime` ke instant valid.
- Fold fall-back memilih kemunculan pertama (at-most-once per tanggal lokal).
- Offset legacy seperti `WIB`, `WITA`, dan `+09` tetap didukung untuk kompatibilitas.

Aturan zona masa depan mengikuti versi data tzdata yang dibawa package `timezone`; pembaruan aturan IANA perlu dependency update dan test.

## 3. Gateway/channel yang tersedia

`agentd` mengaktifkan gateway berdasarkan variabel environment:

| Channel | Aktivasi utama | Catatan |
|---|---|---|
| CLI | proses `tiko`/`agentd --cli` dan terminal | Konfirmasi dapat ditampilkan pada terminal interaktif |
| HTTP/WebSocket + Web UI | `--api`, `--ui`, `API_TOKEN`, atau `AGENT_UI=1` | Default bind `127.0.0.1`, port config default 8787 |
| Telegram | `--telegram` atau `TG_TOKEN` | `TG_ALLOW` wajib berisi ID numerik allowlisted; opsional STT `WHISPER_BIN`/`STT_API_KEY` |
| Discord | `DISCORD_WEBHOOK` atau `DISCORD_BOT_TOKEN` | `DISCORD_ALLOW` untuk ID allowlist; `DISCORD_APP_ID` untuk slash setup; slash register kecuali `DISCORD_SLASH=0` |
| Email (outbound SMTP) | `EMAIL_FROM` | `SMTP_HOST`, `SMTP_PORT`, `EMAIL_ALLOW`, `EMAIL_TO`, `SMTP_STARTTLS`, `SMTP_USER`, `SMTP_PASS`; inbound receiver belum di-wire |
| WhatsApp webhook | `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_VERIFY_TOKEN`, `WHATSAPP_APP_SECRET` harus lengkap | Inbound melalui endpoint webhook; signature Meta diverifikasi |
| Slack webhook | `SLACK_SIGNING_SECRET` + `SLACK_WEBHOOK_URL` atau `SLACK_BOT_TOKEN` | Signature inbound diverifikasi; outbound memakai webhook/bot sesuai konfigurasi |

Ketersediaan kode gateway bukan bukti akun/platform nyata telah diuji. Credentials/allowlist/endpoint harus disediakan pengguna.

## 4. HTTP API

API menggunakan Bearer token pada endpoint admin/operasional. `/health` dikecualikan dari autentikasi. Route source yang tersedia:

| Method | Path | Kegunaan |
|---|---|---|
| GET | `/health` | Liveness tanpa token |
| GET | `/v1/status` | Status runtime |
| GET | `/v1/sessions` | Daftar sesi |
| GET | `/v1/doctor` | Diagnostik runtime |
| GET | `/v1/capabilities` | Kapabilitas/config host |
| GET | `/v1/events` | Recent events |
| GET | `/v1/approvals` | Daftar approvals |
| POST | `/v1/approvals/{id}` | Setujui/tolak approval pending |
| POST | `/v1/messages` | Kirim pesan ke agent; memiliki bounded idempotency cache |
| GET/upgrade | `/v1/stream` | WebSocket event dan chat stream |
| GET | `/v1/memories` | Daftar memory facts |
| DELETE | `/v1/memories/{id}` | Hapus memory |
| POST | `/v1/shutdown` | Shutdown terautentikasi |

Webhook WhatsApp/Slack dipasang pada server yang sama jika gateway dikonfigurasi.

Token dibuat acak bila `API_TOKEN` tidak diset, minimal 32 karakter jika disediakan manual, disimpan di `data/api.token` dengan POSIX mode `0600`, dan tidak dicetak ke daemon log. Default `API_HOST=127.0.0.1`; port berasal dari `api.port` atau `API_PORT`.

## 5. Scheduler lifecycle

Daemon memperoleh instance lock lebih dahulu, lalu menjalankan MCP, mempersiapkan token, menyiapkan gateway, dan memulai scheduler dengan delivery sink. Shutdown menghentikan scheduler secara bounded dan menutup MCP/gateway sebelum melepas lock. Jangan menjalankan dua daemon untuk profile/data directory yang sama.

## 6. Smoke dan batasan

`bash scripts/smoke_agentd.sh` memeriksa lifecycle/API daemon pada CI. Itu bukan test terhadap kredensial nyata di setiap gateway. Email channel pada snapshot ini hanya mengirim outbound SMTP; `pushInbound()` belum dipasangkan dengan IMAP/POP/SMTP listener di `agentd`. STARTTLS tersedia tetapi callback sertifikat saat ini menerima semua sertifikat invalid, sehingga jangan gunakan direct STARTTLS untuk koneksi yang tidak dipercaya. Gunakan relay lokal dengan validasi TLS upstream sampai source diperbaiki.
