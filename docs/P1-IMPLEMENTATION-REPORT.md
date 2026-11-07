# Tiko P1 Implementation Report

Tanggal: 2026-11-07  
Basis: `agent_dart_tiko_p0_fixed.zip` (hasil P0 sebelumnya)

## Ringkasan

P1 dikerjakan sebagai tranche pertama yang aman dan dapat diverifikasi secara statis. Perubahan ini mengaktifkan kembali dua fondasi yang sudah tersedia tetapi tidak tersambung pada runtime: retrieval memory dan SkillRegistry. Ini bukan klaim bahwa seluruh backlog P1 selesai.

## Perubahan

### P1-A: Runtime memory retrieval aktif

- `TikoRuntime.chat()` sebelumnya membuat `_RuntimeContext` hanya dengan `registry` dan `sessions`; `ContextBuilder.memory` tidak pernah diberikan.
- `_RuntimeContext` sekarang menerima `MemoryStore` runtime yang sama dengan AgentLoop.
- `ContextBuilder` melakukan retrieval top-5 untuk pesan user dan menambahkan hasil ke context.
- Hasil retrieval diberi ID dan score untuk keterlacakan.
- Hasil memory dibungkus `<untrusted_data>` dengan instruksi eksplisit bahwa kontennya adalah data, bukan instruksi. Ini mengurangi risiko prompt injection dari memory lama.
- Ditambahkan `context_memory_safety_test.dart` untuk memastikan pembungkus untrusted tetap ada.

### P1-B: SkillRegistry aktif pada runtime

- Runtime memuat skill dari direktori `<workspace>/skills` saat komposisi dibuat.
- Registry yang sama diberikan ke ContextBuilder dan AgentLoop.
- Skill berstatus draft tetap tidak dimasukkan sebagai instruksi aktif; mekanisme match/status yang ada tetap berlaku.
- Direktori skill yang digunakan AgentLoop diarahkan ke lokasi yang sama dengan direktori yang dimuat runtime.

## Pemeriksaan statis

- YAML/YML: 23/23 berhasil diparse dengan PyYAML.
- JavaScript: `node --check` lulus untuk seluruh file JS yang diperiksa.
- Bash: `bash -n` lulus untuk seluruh file shell yang diperiksa.
- Dart SDK dan Flutter SDK tidak tersedia pada lingkungan pengerjaan; `dart format`, `dart analyze`, `dart test`, `flutter analyze`, dan `flutter test` belum dijalankan.

## P1 yang masih terbuka

1. MCP server configuration, lifecycle, allowlist, health status, dan shutdown terkelola belum dihubungkan ke TikoRuntime. Loader MCP sudah ada, tetapi belum ada schema config P1 yang cukup matang; tidak dibuat konfigurasi spekulatif.
2. Scheduler masih di-host oleh `agentd`; belum menjadi lifecycle service TikoRuntime bersama. Pengiriman hasil job harus tetap diarahkan hanya ke channel asal dan tidak boleh fallback ke gateway pertama.
3. Subagent runner belum dipasang ke registry runtime. Perlu batas depth, token/time budget terpisah, permission inheritance, dan cancellation sebelum diaktifkan.
4. Provenance belum dipertahankan pada `MemoryHit` sampai context. `Fact` sudah memiliki `Provenance`, tetapi seluruh backend retrieval perlu mengembalikan metadata provenance secara konsisten sebelum fitur trust-aware memory dapat dinyatakan selesai.
5. Capability enforcement OS-level untuk shell/script/MCP masih perlu sandbox nyata, bukan hanya gate aplikasi.
6. Golden skill evaluation saat ini masih memiliki jalur evaluasi ringan berbasis teks; belum menjalankan task end-to-end pada sandbox dengan assertions atas tool calls dan efek samping.
7. Circuit breaker/fallback observability, offline queue acknowledgement, dan scheduler timezone/missed-run semantics perlu integration test.

## Langkah verifikasi pada mesin Dart/Flutter

Dari root project:

```bash
dart pub get
dart format packages/agent_core/lib/src/context_builder.dart packages/tiko_runtime/lib/src/tiko_runtime.dart packages/agent_core/test/context_memory_safety_test.dart
dart analyze --fatal-infos
dart test packages/agent_core packages/agent_memory packages/tiko_runtime packages/agent_tools packages/agent_security packages/agent_scheduler packages/agent_gateway packages/agent_providers
```

Lalu validasi app:

```bash
cd apps/tiko && dart test
cd ../agentd && dart analyze --fatal-infos
cd ../agent_flutter && flutter pub get && flutter analyze && flutter test
```

## Catatan keamanan

Memory retrieval tetap bersifat best-effort. Jika retrieval gagal, chat tetap berjalan tanpa memory. Konten memory yang berhasil diambil diperlakukan sebagai untrusted data. Jangan mengubahnya menjadi instruksi sistem atau menaikkan permission berdasarkan isi memory.
