# Dependency verification log — repository snapshot 2026-11-09

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

## Scope

Log ini direkonsiliasi terhadap manifest `pubspec.yaml` dan lockfile `pubspec.lock` pada commit `69b6da421bf2a4682dce19e05d1ea608607250be`. Ini bukan hasil pemindaian seluruh versi terbaru pub.dev.

## Temuan koreksi dari log lama (4 November)

- `drift` bukan dependency langsung; storage memakai `sqlite3` dan raw SQLite migration.
- `openai_dart`, `ollama_dart`, `anthropic_sdk_dart`, `googleai_dart` bukan dependency langsung package provider. Adapter lokal menggunakan `http`.
- `sqlite-vec` bukan vector index default runtime; runtime memakai `BruteForceVectorIndex`.
- Tabel versi 4 November yang berlabel latest tidak boleh dianggap latest pada 9 November tanpa cek pub.dev baru.

## Resolved lock examples at snapshot

| Package | Resolved lock |
|---|---:|
| http | 1.6.0 |
| sqlite3 | 2.9.4 |
| web_socket_channel | 3.0.3 |
| yaml | 3.1.4 |
| uuid | 4.6.0 |
| path | 1.9.1 |
| meta | 1.19.0 |
| collection | 1.19.1 |
| args | 2.7.0 |
| crypto | 3.0.8 |
| lints | 5.1.1 |
| test | 1.33.0 |

Lihat `docs/08-REGISTRI-DEPENDENSI.md` untuk constraint manifest per package. Lockfile lengkap tetap sumber kebenaran seluruh versi transitive.

## Revalidasi yang harus dilakukan saat dependency diubah

```bash
dart --version
flutter --version
dart pub get
dart pub outdated
```

Catat tanggal pemeriksaan, current/upgrade/resolvable/latest, compatibility SDK, changelog, license dan hasil CI. Jangan menjalankan `dart pub add` hanya untuk mengejar latest tanpa memeriksa dampak serta lockfile.
