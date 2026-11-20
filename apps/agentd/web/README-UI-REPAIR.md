# Tiko Web UI

Web UI disajikan oleh `HttpApiServer` milik `agentd` dari `apps/agentd/web/`. UI menggunakan API HTTP ber-token dan endpoint WebSocket `/v1/stream`; ia bukan daemon atau runtime terpisah.

## Tab

- **Chat**: mengirim pesan melalui stream daemon dan menampilkan event konfirmasi tool.
- **Memori**: menampilkan dan menghapus memory facts.
- **Status**: menampilkan status runtime.
- **Approvals**: membaca approval daemon dan mengirim keputusan melalui `POST /v1/approvals/{id}`.
- **Sessions**: menampilkan daftar sesi.
- **Bantuan**: mengatur API base URL dan token pada browser.

## Desain

Palet, radius, dan gaya visual dashboard web diselaraskan dengan design token GUI (`SimpulTheme`) di `apps/agent_flutter/lib/ui/theme.dart`; rancangan dan aturan flat modern ada di [docs/09-DESAIN-GUI.md](../../docs/09-DESAIN-GUI.md). Permukaan flat tanpa shadow/gradient kecuali scrim modal; warna baru wajib masuk `:root` sebagai CSS variable.

## Menjalankan

```bash
dart run apps/agentd/bin/agentd.dart --api
```

Buka `http://127.0.0.1:8787/`. Saat UI dilayani langsung oleh agentd (same-origin), tidak perlu memasukkan token: cookie sesi `tiko_web_session` diterbitkan otomatis ketika index dimuat. Token Bearer tetap diterima dan hanya diperlukan untuk klien di luar origin daemon. Default daemon hanya bind ke loopback; pengaksesan jarak jauh memerlukan konfigurasi host, TLS, firewall, dan kebijakan Origin yang sesuai.

## Menyajikan Flutter Web (Jalur A fase 1)

`HttpApiServer` sekarang melayani seluruh folder statis dari `webRoot` (sebelumnya hanya lima path tetap), sehingga hasil `flutter build web --release` dapat menggantikan dashboard vanilla tanpa mengubah runtime:

1. `cd apps/agent_flutter && flutter build web --release`
2. Jalankan agentd dari root repo; `_findWebRoot()` memprioritaskan `apps/agent_flutter/build/web`, fallback ke `apps/agentd/web`.
3. Override via env: `WEB_ROOT=/path/to/build/web`.

Atribut penggabungan: API namespace (`/v1/*`), `/health`, dan `/webhooks/*` dikecualikan dari static serving; aset tetap tanpa auth karena digandengkan pada Host allowlist + bind loopback (B-08); guard traversal `..`/`%2e%2e` fail-closed dengan kode 400; semua respons statis diberi `X-Content-Type-Options: nosniff` dan `Cache-Control: no-cache`.

Flutter Web yang dilayani agentd berjalan same-origin: `API_BASE` otomatis mengikuti origin halaman dan WebSocket memakai ticket sekali pakai `POST /v1/auth/ticket` (diminta via cookie sesi, tanpa token). Dashboard vanilla masih dipertahankan sebagai UI ringan fallback sampai retirement setelah paritas Flutter Web terverifikasi di browser.

### Sesi cookie same-origin dan auto-open (Jalur A fase 2)

- Saat `_serveStatic` menyajikan `index.html`, respons memuat header `Set-Cookie: tiko_web_session=<acak>; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`. Nilai cookie acak 32 byte per proses daemon (ganti setelah restart).
- `_auth` menerima Bearer **atau** cookie tersebut. Permintaan yang membawa header `Origin` hanya diterima jika origin-nya loopback (`127.0.0.1`, `localhost`, `::1`) atau host bind daemon — lapis kedua di atas browser yang tidak mengirim cookie `SameSite=Strict` untuk permintaan cross-site; bind loopback + Host allowlist tetap lapis pertama. Token API utama tidak pernah tersimpan di cookie.
- Menjalankan daemon secara langsung (`dart run apps/agentd/bin/agentd.dart --api`) otomatis membuka browser ke UI bila webRoot ditemukan dan bind loopback. Spawn dari app Flutter desktop atau scheduler programatik menyetel `TIKO_NO_BROWSER=1` agar tidak ada tab ekstra; manual via `TIKO_NO_BROWSER=1` atau `TIKO_OPEN_BROWSER=0`.

## Implementasi UI yang tercakup pada source saat snapshot

- API helper, event handler, approval handler dan tab loader berada pada scope JavaScript yang sama.
- Navigasi tab menyinkronkan class aktif dan properti `hidden`.
- Nilai dari API dimasukkan ke DOM dengan node dan `textContent`, bukan dirender sebagai HTML mentah.
- Chat menggunakan WebSocket; UI tidak otomatis mengirim ulang pesan melalui HTTP saat stream gagal karena tindakan tool dapat terduplikasi.
- URL WebSocket dibangun dari ticket sekali pakai (`POST /v1/auth/ticket` dengan Bearer → `?ticket=`); token utama tidak pernah dikirim via query.
- UI memiliki status memuat/kosong/error, label aksesibilitas, layout responsif dan reduced-motion behavior.

## Validasi

```bash
bash scripts/web_ui_validate.sh
```

Script tersebut menjalankan pemeriksaan sintaks JavaScript dan test Node built-in jika file test tersedia. Ini bukan pengganti uji visual lintas browser/perangkat.
