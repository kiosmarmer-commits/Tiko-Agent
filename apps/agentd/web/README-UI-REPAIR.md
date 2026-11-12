# Tiko Web UI

Web UI disajikan oleh `HttpApiServer` milik `agentd` dari `apps/agentd/web/`. UI menggunakan API HTTP ber-token dan endpoint WebSocket `/v1/stream`; ia bukan daemon atau runtime terpisah.

## Tab

- **Chat**: mengirim pesan melalui stream daemon dan menampilkan event konfirmasi tool.
- **Memori**: menampilkan dan menghapus memory facts.
- **Status**: menampilkan status runtime.
- **Approvals**: membaca approval daemon dan mengirim keputusan melalui `POST /v1/approvals/{id}`.
- **Sessions**: menampilkan daftar sesi.
- **Bantuan**: mengatur API base URL dan token pada browser.

## Menjalankan

```bash
dart run apps/agentd/bin/agentd.dart --api
```

Buka `http://127.0.0.1:8787/`, lalu masukkan token dari `data/api.token` pada tab Bantuan. Default daemon hanya bind ke loopback; pengaksesan jarak jauh memerlukan konfigurasi host, TLS, firewall, dan kebijakan Origin yang sesuai.

## Implementasi UI yang tercakup pada source saat snapshot

- API helper, event handler, approval handler dan tab loader berada pada scope JavaScript yang sama.
- Navigasi tab menyinkronkan class aktif dan properti `hidden`.
- Nilai dari API dimasukkan ke DOM dengan node dan `textContent`, bukan dirender sebagai HTML mentah.
- Chat menggunakan WebSocket; UI tidak otomatis mengirim ulang pesan melalui HTTP saat stream gagal karena tindakan tool dapat terduplikasi.
- URL WebSocket menggunakan `URL` dan `searchParams` untuk token.
- UI memiliki status memuat/kosong/error, label aksesibilitas, layout responsif dan reduced-motion behavior.

## Validasi

```bash
bash scripts/web_ui_validate.sh
```

Script tersebut menjalankan pemeriksaan sintaks JavaScript dan test Node built-in jika file test tersedia. Ini bukan pengganti uji visual lintas browser/perangkat.
