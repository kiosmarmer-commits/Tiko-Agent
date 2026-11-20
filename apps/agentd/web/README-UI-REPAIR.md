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

Buka `http://127.0.0.1:8787/`, lalu masukkan token dari `data/api.token` pada tab Bantuan. Default daemon hanya bind ke loopback; pengaksesan jarak jauh memerlukan konfigurasi host, TLS, firewall, dan kebijakan Origin yang sesuai.

## Menyajikan Flutter Web (Jalur A fase 1)

`HttpApiServer` sekarang melayani seluruh folder statis dari `webRoot` (sebelumnya hanya lima path tetap), sehingga hasil `flutter build web --release` dapat menggantikan dashboard vanilla tanpa mengubah runtime:

1. `cd apps/agent_flutter && flutter build web --release`
2. Jalankan agentd dari root repo; `_findWebRoot()` memprioritaskan `apps/agent_flutter/build/web`, fallback ke `apps/agentd/web`.
3. Override via env: `WEB_ROOT=/path/to/build/web`.

Atribut penggabungan: API namespace (`/v1/*`), `/health`, dan `/webhooks/*` dikecualikan dari static serving; aset tetap tanpa auth karena digandengkan pada Host allowlist + bind loopback (B-08); guard traversal `..`/`%2e%2e` fail-closed dengan kode 400; semua respons statis diberi `X-Content-Type-Options: nosniff` dan `Cache-Control: no-cache`.

Flutter Web yang dilayani agentd berjalan same-origin: `API_BASE` otomatis mengikuti origin halaman dan WebSocket memakai ticket sekali pakai `POST /v1/auth/ticket`; token HTTP API tetap dimasukkan pada tab Bantuan/Settings. Dashboard vanilla masih dipertahankan sebagai UI ringan fallback sampai fase 2 (retirement setelah paritas terverifikasi di browser).

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
