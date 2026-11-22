# 10 — Web UI agentd (Flutter Web)

> **Catatan status:** dokumen mengikuti implementasi Jalur A fase 3. Dashboard web agentd adalah hasil build Flutter Web yang dilayani `HttpApiServer` milik daemon; dashboard vanilla berbasis JavaScript di `apps/agentd/web` telah dipensiunkan dan dihapus.

## 1. Arsitektur penyajian

- Sumber UI: hasil `flutter build web --release` pada `apps/agent_flutter/build/web`. Satu pohon widget memakai design token `SimpulTheme` (lihat [09-DESAIN-GUI.md](09-DESAIN-GUI.md)) sehingga UI web identik dengan client Android/Desktop.
- Penyajian: `HttpApiServer` (`packages/agent_gateway/lib/src/http_api.dart`) melayani folder `webRoot` secara generik — hanya GET, mengecualikan `/health`, `/v1/*`, dan `/webhooks/*`; peta mime lengkap; header `X-Content-Type-Options: nosniff` dan `Cache-Control: no-cache`; guard traversal `..`/`%2e%2e` fail-closed (400) dengan dekoding percent-encoded sebelum dicek.
- Discovery webRoot di `apps/agentd/bin/agentd.dart` (`_findWebRoot`): env `WEB_ROOT` (harus memuat `index.html`), lalu `apps/agent_flutter/build/web` relatif root repo dan CWD. Bila tidak ditemukan, UI statis 404 dan daemon mencetak instruksi build.
- Aset statis tanpa auth karena hanya terjangkau lewat bind loopback + Host allowlist 421 (B-08); API tetap 401 tanpa kredensial.

## 2. Menjalankan

```bash
cd apps/agent_flutter && flutter build web --release
dart run apps/agentd/bin/agentd.dart --api
```

- Buka `http://127.0.0.1:8787/`. Override lokasi aset via `WEB_ROOT=/path/to/build/web`.
- Saat UI dilayani langsung oleh agentd (same-origin), **tidak perlu memasukkan token**: browser otomatis membuka dashboard setelah server siap. Token Bearer tetap diterima dan hanya diperlukan untuk klien di luar origin daemon (misal perangkat lain yang mengakses daemon yang di-bind ke host non-loopback).
- Flutter Web berjalan same-origin: `API_BASE` mengikuti origin halaman, WebSocket memakai ticket sekali pakai (`POST /v1/auth/ticket`).

## 3. Sesi cookie same-origin (tanpa token)

- Saat `_serveStatic` menyajikan `index.html`, respons memuat `Set-Cookie: tiko_web_session=<acak>; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`; nilai acak 32 byte per proses daemon (ganti setelah restart).
- `_auth` menerima Bearer **atau** cookie tersebut. Permintaan yang membawa header `Origin` hanya diterima jika origin-nya loopback (`127.0.0.1`, `localhost`, `::1`) atau host bind daemon — lapis kedua di atas browser yang tidak mengirim cookie `SameSite=Strict` untuk permintaan cross-site; bind loopback + Host allowlist tetap lapis pertama. Opsi "tanpa auth di loopback" ditolak karena POST cross-site simple-request dapat melewati preflight. Token API utama tidak pernah tersimpan di cookie.
- Alur chat: cookie → `POST /v1/auth/ticket` → ticket sekali pakai TTL 30 detik → upgrade WebSocket `/v1/stream?ticket=`.

## 4. Auto-open browser

- Menjalankan daemon secara langsung otomatis membuka browser ke UI bila webRoot ditemukan dan bind loopback, per platform (`open`/`xdg-open`/`cmd /c start`).
- Spawn dari app Flutter desktop dan scheduler programatik menyetel `TIKO_NO_BROWSER=1` agar tidak membuka tab ekstra. Kontrol manual: `TIKO_NO_BROWSER=1` atau `TIKO_OPEN_BROWSER=0`.
- Auto-open hanya aktif pada bind loopback; daemon yang di-bind ke host non-loopback tidak membuka browser.

### 4.1 Pemilih model per-sesi (discovery ala Hermes)

- Chip model di header chat membaca `GET /v1/providers/<id>/models`: daemon menjalankan live discovery hanya untuk provider yang terkonfigurasi (config + `gateway.env`) — tidak pernah menebak provider. Transport discovery: OpenAI-compat `GET {base}/models` (openai, gemini, deepseek, openai_compat) dan Ollama native `GET {base}/api/tags`; kontrak bersama `ModelDiscovery` di agent_providers.
- Hasil discovery di-cache 15 menit per provider; endpoint error → daftar kosong (fail-open) dan pemilih lanjut memakai model default provider.
- Pilihan provider + model tersimpan per-sesi via `POST /v1/providers/session` dengan field `model` opsional; chip menampilkan `provider · model` bila model eksplisit terpasang.
- Snapshot `GET /v1/providers` menambahkan `session_model_choices` (peta session → model).

### 4.2 Renderer markdown + tombol salin (C1)

- Balasan asisten dirender lewat `TikoMarkdownView` (`tiko_widgets`): subset markdown — heading, paragraf, bullet/ordered, blockquote, tabel sederhana, **bold**/*italic*/inline code/link, dan code fence dengan panel monospace terpisah (label bahasa, scroll horizontal, tombol "Salin kode"). Bukan CommonMark penuh — sintaks di luar subset tampil apa adanya.
- Blok ```genui tetap dirender sebagai widget oleh `GenUiMessageView`; segmen teks di luarnya kini markdown.
- Tombol "Salin" per-pesan asisten menyalin teks mentah (termasuk markdown) ke clipboard + SnackBar "Pesan tersalin". Pesan user tetap selectable text.

### 4.3 Lampiran file di chat (C2)

- Composer punya tombol attach (maksimum 4 file, 2 MiB/file) + chip pratinjau dengan tombol hapus; pesan user menampilkan ringkasan `📎 nama-file`.
- Lampiran dikirim inline base64 ke `POST /v1/messages` / WS `/v1/stream` (`attachments: [{name, mime, data_base64}]`); daemon memvalidasi fail-closed (jumlah, nama aman, mime allowlist text/* + subset application/* + image png/jpeg/gif/webp, 2 MiB/file) dan menolak 400 dengan pesan bahasa Indonesia.
- Runtime membaca dokumen teks sebagai konteks inline `[lampiran: nama] … [/lampiran: nama]` (cap 64 KiB/file, 128 KiB total); gambar/biner  hanya menghasilkan metadata jujur (vision provider belum didukung runtime).
- Platform: pemilih file aktif di Web (input file browser, tanpa dependency baru); desktop gagal jujur dan mengarahkan ke referensi `@file:` dari P3.

### 4.4 Panel file + chips @file + kartu diff di chat (C3)

- Header chat punya tombol folder (`btn-chat-files`) untuk membuka `ChatArtifactPanel`: daftar file artifacts read-only dengan navigasi folder, tombol naik (`..`), refresh, dan preview file (isi teks + diff vs `.bak` bila tersedia) lewat `ArtifactPreviewPanel` (termasuk tombol salin isi file).
- Layout: layar lebar (≥1100px) panel kanan 380px; layar sempit overlay penuh di atas chat. Read-only — tidak ada endpoint tulis.
- Referensi `@file:` dalam pesan dirender sebagai chip monospace; tap membuka file di panel. Parsing fail-closed di `collectFileRefs` (skip `..`/backslash, maks 6, tanda baca akhir dipangkas).
- Pesan dengan field `files` (daftar `{path, changed}`) merender kartu file ("Lihat" + "Diff"); sumber otomatis dari tool trace dikerjakan di C4.

## 5. Batasan dan test

- Memerlukan Flutter SDK untuk build; tanpa build, UI statis 404 dengan instruksi di log daemon. Renderer Canvaskit postematik aset engine dari CDN saat pertama kali dibuka, jadi browser pengguna memerlukan akses jaringan keluar; untuk lingkungan offline, pertimbangkan self-host aset Canvaskit pada konfigurasi build Flutter Web.
- Contract test generik static serving termasuk sesi cookie: `packages/agent_gateway/test/http_api_static_test.dart` (statika, traversal, Set-Cookie, API via cookie, Origin check, ticket via cookie).
- Pengujian lintas browser/perangkat bersifat manual; tidak ada pengganti otomatis untuk skenario visual tersebut.
