# 05-SCHEDULER-BOT-GATEWAY

- **ID dokumen:** AGD-05
- **Bergantung pada:** AGD-01, AGD-04

## 1. Scheduler
### Desain
- Sumber kebenaran: tabel `jobs` (AGD-04). Tidak bergantung pada timer in-memory.
- **Tick loop** tiap 15–30 detik: pilih job `enabled=1 AND next_run <= now`, kunci (UPDATE atomik
  `next_run` ke masa depan), buat `InboundMessage` internal (`channel='scheduler'`), jalankan lewat agent loop,
  kirim hasil ke kanal tujuan (`jobs.channel`, `jobs.user_key`).
- **Idempotensi:** setiap eksekusi punya `run_id` (job_id + waktu terjadwal); jangan jalankan dua kali.
- **Missed-run policy** (`missed_policy`): `skip` (lewati), `run_once` (jalankan sekali saat bangun),
  `catch_up` (maks N kali). Default `run_once`.
- **Zona waktu:** simpan zona IANA per job (mis. `Asia/Jakarta`); hitung `next_run` dalam UTC.
- **Batas:** maksimum job aktif, anggaran token per job, timeout per run, notifikasi saat gagal 3×.
- Input jadwal: bahasa natural → DecisionProvider/LLM mengubah ke cron + konfirmasi user sebelum disimpan.

### Pustaka
| Kebutuhan | Opsi | Status |
|---|---|---|
| Parser cron | paket `cron` | ⚠️ belum diverifikasi; alternatif: parser sendiri (5 field) ~100 baris |
| Android background | `workmanager` (minimum periodik ±15 menit), `flutter_background_service` | ⚠️ belum diverifikasi; OS dapat membunuh proses |
| Server/Termux | loop `Timer.periodic` + tabel `jobs` | ✅ pola umum |
Rekomendasi: scheduler **hanya** di daemon (`agentd`), bukan di aplikasi Flutter.
Di Termux gunakan `termux-wake-lock` dan `termux-services`/`tmux` agar proses tidak dimatikan.

## 2. Model pesan gateway
```dart
class InboundMessage {
  final String channel;      // cli | telegram | discord | email | http | scheduler
  final String userKey;      // ID pengguna di kanal tersebut
  final String sessionKey;   // channel + chat id (+ thread)
  final String text;
  final List<Attachment> attachments; // gambar, audio, dokumen
  final Map<String, Object?> meta;
}
abstract class Gateway {
  String get channel;
  Stream<InboundMessage> get inbound;
  Future<void> send(OutboundMessage m);          // teks, markdown, tombol konfirmasi
  Future<void> sendTyping(String sessionKey);
}
```
Aturan bersama semua gateway:
1. **Allowlist pengguna** (ID numerik, bukan username) di config; pesan dari ID lain diabaikan dan dicatat.
2. **Rate limit** per pengguna (mis. 20 pesan/menit) dan per sesi satu tugas aktif (antre atau interupsi).
3. Perintah slash seragam: `/new`, `/stop`, `/model`, `/memory`, `/skills`, `/jobs`, `/status`.
4. Pesan panjang dipecah sesuai batas platform; format Markdown dikonversi per platform.
5. Konfirmasi tool berisiko memakai tombol inline (Telegram) atau prompt teks (kanal lain).
6. Audio masuk → STT (AGD-02) → teks.

## 3. Gateway per platform
| Platform | Paket | Versi/aktivitas | Status | Catatan |
|---|---|---|---|---|
| CLI | `dart:io`, `args` | — | ✅ | Kanal pertama dibuat |
| **Telegram** | `televerse` | **3.3.0** (rilis ±1 hari sebelum sinkronisasi), Bot API 9.5, BSD-3, 96★ | ✅ aktif | Mendukung long polling, `Bot.local` (server Bot API lokal), webhook/serverless via `handleUpdate`, middleware, Conversation API |
| Telegram alternatif | `teledart` | belum diverifikasi | ⚠️ | |
| **Discord** | `nyxx` | **6.8.1** (±3 bulan), Apache-2.0, 333★ | ✅ aktif | Bot dan aplikasi Discord |
| **Email** | `enough_mail` | **2.1.7** (±6 bulan; rilis sebelumnya ±2 tahun), MPL-2.0 | ✅ tapi ritme rilis lambat | IMAP/POP3/SMTP; pantau IDLE untuk push |
| **Web/WebSocket API** | `dart_frog` 1.2.6 (±4 bulan, MIT, 2.039★) atau `shelf` 1.4.2 (dart-lang, Jun 2024, stabil/matang) | ✅ / ⚠️ shelf jarang dirilis | Untuk klien Flutter |
| Slack / Signal | — | ⚠️ tidak ada paket Dart terverifikasi | Gunakan webhook/sidecar (mis. signal-cli) bila perlu |
| WhatsApp | — | ⚠️ | Tidak ada jalur resmi sederhana; **hindari** library tidak resmi (risiko pemblokiran) |

### Telegram: poin implementasi
- Mulai dengan **long polling** (tanpa domain/HTTPS); webhook hanya jika ada VPS dengan TLS.
- Simpan `update_id` terakhir agar tidak memproses ulang setelah restart.
- Indikator mengetik (`sendChatAction`) selama agent bekerja; streaming jawaban dengan edit pesan berkala (hormati batas laju Telegram).
- Tombol inline untuk konfirmasi tool: `callback_data` berisi ID konfirmasi acak, kedaluwarsa 120 dtk.

### API untuk klien Flutter
- Endpoint: `POST /v1/messages` (kirim pesan), `GET /v1/stream` (WebSocket: delta teks, event tool, minta konfirmasi),
  `GET /v1/sessions`, `GET/DELETE /v1/memories`.
- Autentikasi: token statis per perangkat (disimpan di secure storage) + TLS jika lewat jaringan publik.
- Bind default `127.0.0.1`; akses jarak jauh lewat reverse proxy/tunnel yang dikonfigurasi pengguna.

## 4. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-05-01 | Kanal CLI + antarmuka `Gateway` | Percakapan CLI end-to-end |
| TASK-05-02 | Gateway Telegram (polling, allowlist, tombol konfirmasi) | Tes dengan bot nyata |
| TASK-05-03 | Scheduler tick loop + `jobs` + missed policy | Tes simulasi restart |
| TASK-05-04 | Tool `schedule_job` dengan konfirmasi cron | Jadwal natural → cron benar |
| TASK-05-05 | API HTTP/WebSocket untuk Flutter | Klien contoh menerima stream |
| TASK-05-06 | Gateway Discord/Email (opsional) | Tes smoke |
