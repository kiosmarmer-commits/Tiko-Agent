# Pedoman Pengembangan Tiko-Agent

Dokumen ini menjelaskan cara menambah modul, fitur, provider, gateway, atau algoritma tanpa mengubah perilaku lama secara diam-diam.

## Prinsip utama

1. **Source dan test adalah kontrak.** Dokumentasi menjelaskan kontrak; perubahan algoritma memerlukan fixture regresi.
2. **Satu pemilik state.** State konfigurasi, cache, session, approval, health, dan queue harus memiliki satu owner yang jelas.
3. **Fail closed pada boundary.** Secret hilang, input invalid, sandbox tidak tersedia, signature gagal, allowlist kosong, dan capability tidak dikenal harus ditolak atau degraded dengan pesan yang dapat ditindaklanjuti.
4. **Library tidak otomatis berarti feature.** Class provider baru perlu wiring runtime, konfigurasi, tool/command, test integration, dan dokumentasi sebelum diberi label fully implemented.
5. **Perubahan algoritma harus dapat dibandingkan.** Simpan baseline, fixture, metrik, dan alasan perubahan; jangan mencampur refactor besar dengan perubahan score/ranking/routing.

## Sebelum menulis kode

Tuliskan mini design note di issue/PR:

- masalah pengguna dan package pemilik;
- kontrak input/output dan error;
- state, concurrency, timeout, retry, serta lifecycle `close()`;
- permission, secret, SSRF, sandbox, dan audit impact;
- backward compatibility dan migration plan;
- test acceptance serta dokumen yang akan diperbarui.

Cari implementasi dan test yang ada lebih dulu. Gunakan `rg`, baca entry point package, cek export barrel, lalu telusuri caller/callee sebelum membuat abstraction baru.

## Checklist penambahan modul

1. Buat file di package yang paling dekat dengan domainnya.
2. Pisahkan model, interface, transport/adaptor, dan orchestration; jangan menaruh semuanya di entry point daemon.
3. Export hanya API publik yang stabil melalui barrel file package.
4. Dokumentasikan public class, constructor, getter, method, parameter penting, error, timeout, dan contoh penggunaan dengan `///` sesuai Effective Dart.
5. Tambahkan unit test untuk valid input, invalid input, boundary, timeout, retry, close, dan concurrency.
6. Tambahkan integration/wiring test bila modul harus terlihat dari runtime, registry, command, gateway, atau Flutter.
7. Tambahkan konfigurasi dengan default aman dan validasi eksplisit. Secret wajib `env:NAME`/SecretRef; jangan simpan nilai secret.
8. Perbarui README, indeks, dokumen domain, contoh config, dan status partial/conditional.
9. Jalankan analyzer dan test package sebelum test workspace.

## Tool atau MCP server

- Definisikan `ToolSpec` lengkap: name, description, schema, risk, confirmation, dan parallel-safety.
- Validasi schema fail-closed; tolak key, tipe, dan ukuran yang tidak dikenal.
- Gunakan `ToolContext` untuk cancellation, workspace, audit, secret broker, dan approval.
- Batasi path dengan path-safety; batasi command dengan sandbox; batasi network dengan SSRF/pinned client.
- MCP harus memiliki lifecycle start/close, timeout, session recovery, error surface, dan test transport.
- Tambahkan test registry yang membuktikan tool benar-benar terpasang, bukan hanya class yang dapat di-import.

## Provider AI atau memory

- Implementasikan interface provider yang sudah ada; jangan membuat format response kedua tanpa adapter.
- Petakan capability, model, token usage, latency, error class, dan health probe.
- Hormati circuit breaker dan fallback policy; provider baru tidak boleh bypass health gate.
- Untuk memory, tetapkan owner scope, provenance, trust/taint, TTL/decay, deduplication, dan redaction.
- Uji response wrapped/bare, empty result, malformed result, timeout, HTTP error, dan retry policy.

## Gateway atau channel

- Implementasikan `Gateway` dan kontrak `InboundMessage`/`OutboundMessage` yang sama.
- Tetapkan identity mapping: `channel`, `userKey`, `sessionKey`, thread, group, dan metadata.
- Verifikasi signature/authentication sebelum `pushInbound`.
- Terapkan allowlist, group mention policy, rate limit, timeout, retry/backoff, dan idempotency.
- Pastikan `close()` menutup stream, subscription, socket, dan HTTP client yang dimiliki gateway.
- Tambahkan test inbound, outbound, error, retry, unauthorized, close, dan parity dengan channel lain.

## Smart-home provider

Provider baru harus mengikuti `SmartHomeProvider` dan model netral:

- `listDevices()` aman terhadap response kosong/wrapped dan menerapkan allowlist.
- `getDevice()` dan `execute()` menolak device yang tidak diizinkan.
- Command divalidasi berdasarkan kemampuan device, bukan diteruskan mentah.
- Event stream memiliki reconnect/backoff, parsing malformed event, dan lifecycle close.
- Secret/token tidak muncul di error, log, snapshot, atau metadata publik.
- Tambahkan contract test yang sama dengan Home Assistant, Tuya, dan eWeLink.
- Setelah itu baru tambahkan registry/config/tool runtime; class provider saja belum cukup.

## Perubahan algoritma

Berlaku untuk agent loop, routing, retrieval, ranking, memory decay, scheduler, dan prediksi.

1. Tuliskan invariant sebelum perubahan, misalnya “deny tetap deny”, “score berada di rentang”, “tie-break deterministik”, atau “cancel tidak dicatat sebagai sukses”.
2. Bekukan fixture baseline dan tambahkan regression test.
3. Pisahkan perubahan formula dari perubahan transport/UI.
4. Dokumentasikan input, output, unit, batas, fallback, kompleksitas, dan tie-break.
5. Bandingkan sebelum/sesudah pada golden/eval set dan jelaskan metrik.
6. Jangan mengganti default atau dataset produksi hanya karena test menjadi lebih mudah.
7. Jika hasil berubah sengaja, naikkan versi schema/config atau sediakan migration/compatibility path.

Untuk algoritma prediksi, jangan mengubah candle parsing, indikator, score, risiko, backtest, atau dataset tanpa fixture numerik dan persetujuan domain. Untuk memory/routing, jangan mengubah ranking atau decay tanpa evaluasi query/trajectory yang mewakili penggunaan nyata.

## Testing dan CI

```sh
dart format path/yang-diubah.dart
dart analyze packages/<pemilik> --fatal-warnings
dart test packages/<pemilik>/test
git diff --check
```

Untuk perubahan lintas package:

```sh
dart analyze --fatal-warnings
dart test
bash scripts/validate.sh
```

Gunakan random-order seed untuk menemukan state global dan test yang berbagi port/file. Jangan memperbaiki nondeterminism dengan menonaktifkan parallelism; isolasikan fixture, port, temporary directory, clock, dan cleanup.

## Pull request dan dokumentasi

PR harus memuat ringkasan sebelum/sesudah, package yang berubah, kontrak/schema, security dan compatibility impact, test command, hasil test, status fitur (`Implemented`, `Conditional`, `Library only`, `Partial`, atau `Not implemented`), serta daftar dokumentasi yang diperbarui.

Jangan menulis “semua sudah selesai” jika wiring, native dependency, credential, atau CI belum diverifikasi. Gunakan commit SHA dan tanggal untuk snapshot status.

## Hal yang dilarang

- Commit token, credential, `data/`, `.env`, binary build, atau output runtime.
- Mengubah algoritma kalender/prediksi/memory/routing tanpa test regresi dan catatan perubahan.
- Menambahkan retry tanpa idempotency dan batas maksimum.
- Menelan exception tanpa audit/error surface.
- Menambahkan public API tanpa doc comment dan test.
- Mengubah banyak file dengan formatter/rename massal ketika perubahan tidak memerlukannya.
- Mengklaim direct integration ketika implementasi sebenarnya hanya adapter/library.
