# Secure Credential Handling (GUI-P0-05) — 2026-11-18

Implementasi item **GUI-P0-05** dari laporan audit GUI: "Secure
credential/session handling — Browser localStorage dan manual token entry
berisiko — Tidak ada secret raw di log/UI/local preferences".

## Yang berubah

### 1. Web UI (`apps/agentd/web`)

- **Token tidak lagi disimpan di `localStorage`** (plaintext permanen di
  profil browser). Kini dipakai `sessionStorage`: berlaku per-tab dan terhapus
  otomatis saat tab ditutup.
- **Migrasi otomatis satu kali**: token lama yang masih ada di `localStorage`
  dipindahkan ke `sessionStorage` lalu dihapus dari penyimpanan permanen.
- Menyimpan token kosong pada form koneksi menghapus token dari sesi.
- Hint keamanan di halaman Bantuan diperbarui (sessionStorage, per-tab).
- `API base URL` tetap di `localStorage` — bukan secret.

### 2. Flutter (`apps/agent_flutter`)

- Kondisi eksisting sudah aman dan kini dikunci test: `AppSettings` tidak
  menyimpan token/secret ke `shared_preferences`; token hanya hidup di memori
  (dart-define atau input manual per sesi).
- Input token sudah `obscureText` + tanpa saran/autocorrect; kini ditambah
  helper text eksplisit bahwa token tidak disimpan ke perangkat.

### 3. Daemon

- Diverifikasi: `agentd` tidak pernah mencetak nilai token ke stdout/stderr
  (hanya pesan status); error API tidak meng-echo header Authorization;
  WebSocket memakai ticket one-time 30 detik sehingga token utama tidak
  pernah lewat URL query.

## Batasan yang jujur

- `sessionStorage` tetap plaintext di memori tab browser — ini memperkecil
  risiko (tidak bertahan, tidak lintas-tab) tapi bukan enkripsi. Untuk
  deployment multi-user yang serius, rekomendasi laporan (session cookie
  HttpOnly server-side / short-lived token) masih menjadi pekerjaan lanjutan.
- Flutter belum memakai keystore aman per-platform (flutter_secure_storage);
  penambahan dependency native + QA per platform disengaja ditunda agar
  perubahan ini tetap kecil dan dapat diverifikasi CI.
- Log daemon di luar `agentd.dart` (gateway platform dsb.) tidak diaudit
  baris-per-baris dalam item ini.

## Test

- `apps/agentd/web/app.test.cjs` — 1 test baru (6 total, lulus lokal via
  `node --test`): migrasi localStorage → sessionStorage, simpan token baru,
  dan penghapusan token kosong; harness kini menyediakan `sessionStorage` +
  `removeItem`.
- `apps/agent_flutter/test/settings_test.dart` — 1 test baru: tidak ada kunci
  `token`/`secret` di preferences setelah save.
