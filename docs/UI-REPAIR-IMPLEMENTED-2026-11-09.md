# Laporan Perbaikan UI Tiko-Agent — 9 November 2026

## Baseline

Perbaikan diterapkan pada snapshot repository `kiosmarmer-commits/Tiko-Agent`, branch `main`, commit `69b6da421bf2a4682dce19e05d1ea608607250be` (`bug fix gpt`). Arsip hasil tetap berisi keseluruhan repository, bukan hanya file yang berubah.

## Perubahan yang diterapkan

### Flutter client

- Refresh data administrasi (status, capabilities, doctor, sesi, approval, event, memori) dijalankan paralel agar tidak menunggu satu per satu.
- Ditambahkan guard refresh agar permintaan periodik dan manual tidak saling bertumpuk, serta generation token agar hasil koneksi lama tidak menimpa state koneksi terbaru.
- Status online diteruskan ke halaman Approvals, Sessions, Memory, Settings, dan halaman More agar status koneksi tidak dibuat seolah selalu online.
- Mengganti sesi chat membersihkan transcript sesi sebelumnya sehingga isi sesi lama tidak tertampil sebagai sesi baru.
- Chat mengikuti pesan terbaru hanya ketika pengguna masih berada dekat bagian bawah; posisi baca pengguna tidak dipaksa turun saat ia sedang membaca pesan lama.
- Penanganan lifecycle Composer dan operasi asynchronous diperketat untuk mencegah penggunaan controller setelah dispose dan `setState` setelah widget tidak mounted.
- Penghapusan memori memberikan konfirmasi dan menampilkan kegagalan, bukan menganggap semua respons sebagai sukses.
- WebSocket meng-encode token query, menunggu koneksi siap, memberi batas waktu stream idle, dan menutup channel pada jalur cleanup.
- ID memori di-encode ketika dipakai pada URL path.

### Pengujian dan metadata Flutter

- Ditambahkan regression test untuk perilaku navigasi layar lebar.
- Metadata Flutter Web menggunakan nama dan deskripsi produk Tiko.
- Workflow CI menjalankan validasi interaksi Web UI.

### Web UI

Kode Web UI pada arsip sumber sudah memuat perbaikan tab Approvals/Sessions, rendering konten Memory dengan `textContent`, chat WebSocket, dan pemakaian endpoint approval bersama. File test interaksi Web UI disertakan dan dijalankan ulang pada paket final.

## Validasi yang benar-benar dijalankan pada paket ini

| Pemeriksaan | Hasil |
|---|---|
| Arsip sumber sebelum perubahan (`unzip -t`) | Lulus |
| Patch Flutter diterapkan dengan pemeriksaan pola sumber | Lulus |
| `python3 -m py_compile scripts/apply_flutter_ui_repairs.py` | Lulus |
| `bash scripts/web_ui_validate.sh` | Lulus, 3/3 test |
| `node --check` melalui validator Web UI | Lulus |
| Pemeriksaan ZIP final (`unzip -t`) | Lulus |

## Belum divalidasi di lingkungan pembuat arsip

Dart SDK dan Flutter SDK tidak tersedia di lingkungan ini. Karena itu `dart format`, `dart analyze`, `flutter analyze`, `flutter test`, `flutter build web --release`, dan workflow CI penuh **belum dijalankan pada hasil perubahan**. Jangan menganggap status CI pada commit baseline sebagai bukti bahwa perubahan lokal ini sudah lolos CI. Jalankan validasi Flutter setelah mengekstrak arsip di lingkungan yang memiliki SDK.

## Validasi lanjutan

Dari root repository:

```bash
bash scripts/web_ui_validate.sh
cd apps/agent_flutter
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build web --release
```

Kembali ke root dan jalankan workflow validasi Dart utama:

```bash
cd ../..
bash scripts/validate.sh
```

## Catatan ruang lingkup

Perubahan kode difokuskan pada Flutter UI/client dan gate validasi Web UI. Temuan arsitektur/security lain yang tercatat di `REPOSITORY-AUDIT-2026-11-09.md` tidak otomatis dianggap telah diperbaiki oleh paket ini; gunakan status dan roadmap audit tersebut untuk pekerjaan berikutnya.
