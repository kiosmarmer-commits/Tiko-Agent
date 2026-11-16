# Token Encoding & API Failure Handling Tests (C7) + Penutupan Row Durable Metrics

Tanggal: 2026-11-16
Status: Menutup dua row roadmap P2 sekaligus.

## Row "Durable metrics consistency" — sudah terimplementasi (row stale)

Audit ulang menunjukkan mekanisme yang diminta kriteria sudah lengkap di `main`:

- `SkillMetricsLedger` (agent_core) **flush per-event** dengan rantai future terserialisasi (flush konkuren tidak saling menimpa `.tmp`) + tulisan atomik tmp+rename.
- `SkillRegistry._pendingSinkWrites` melacak tulisan sink yang berjalan; `flushPendingSinks()` menunggu semuanya — dipanggil runtime saat shutdown (`tiko_runtime.dart` close path) dan oleh `runtime_skill_api`.
- Feedback wiring selesai di C1 (`recordFeedback` → ledger durabel).
- Test yang sudah ada: 7 test `skill_metrics_test.dart` (persist, korup fail-closed, pruning, sink), 3 test `skill_feedback_sinks_test.dart` (termasuk "flushPendingSinks menunggu tulisan yang masih berjalan"), dan `skill_metrics_durability_test.dart` level runtime (chat → uses terpersist → restart memulihkan).

Kriteria "Batch/flush durability bila metrik menjadi basis kebijakan; feedback wiring" terpenuhi — row ditutup tanpa perubahan kode, hanya koreksi status roadmap.

## Row "API/Flutter token encoding and API failure handling" — C7

Test baru: `apps/agent_flutter/test/token_encoding_test.dart` (5 test, server palsu HTTP yang dapat dikonfigurasi):

1. **401/403/500/503 semuanya surface sebagai exception dengan kode di pesan** — tidak ada penyamaran sebagai data kosong (melanjutkan perbaikan P1 "Flutter API error transparency").
2. **Token dengan CRLF (header injection) ditolak lokal** — `Authorization: Bearer abc\r\nX-Injected: pwned` ditolak dart:io HttpHeaders; test memastikan request **tidak pernah sampai server** dan tidak ada header palsu yang diterima.
3. **baseUrl malformed** (`'not a url'`, `'http://'`, `'://missing-scheme'`) → error terkendali, bukan crash.
4. **ID unicode/spasi/slash/reserved chars** pada `deleteMemory` dan `decideApproval` — `Uri.encodeComponent` menjaga URL tetap valid; server menerima path ter-encode dan men-decode kembali utuh.
5. **sendMessage unicode/emoji/newline/tab/backslash** — JSON body menjaga teks utuh dua arah.

## Verifikasi lokal (Flutter 3.47.5 / Dart 3.13.4, sama dengan CI)

- `flutter analyze` (apps/agent_flutter): No issues found.
- `flutter test` (apps/agent_flutter): **70 lulus** (3× berulang tanpa flake).

## Batasan yang tetap berlaku

- Test dijalankan pada VM test Flutter (dart:io asli) — bukan pengganti pengujian perangkat nyata.
- Validasi token CRLF bergantung pada dart:io HttpHeaders (sisi VM); di platform web (browser XHR) browser menolak header kontrol secara independen.
