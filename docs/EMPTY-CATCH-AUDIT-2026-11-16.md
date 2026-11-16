# Audit Empty Catch (A8) — 2026-11-16

## Ringkasan

Audit menyeluruh menemukan **100 blok catch kosong** (`catch (_) {}`) di kode
produksi (non-test). Semua kini tertangani dengan salah satu dari tiga cara:

| Penanganan | Jumlah | Keterangan |
|---|---|---|
| Dikonversi ke logging `stderr.writeln` | 36 | Kegagalan yang menyentuh persistensi, state, atau degradasi diam-diam |
| Ditandai `// best-effort` | 64 | Cleanup/dispose/callback sekunder yang disengaja dan direview |
| Diberi komentar `// best-effort` multi-baris | 1 | Typing indicator Discord (`catch (_) { } finally`) |

## Kebijakan (baru)

1. **Catch kosong wajib bertanda.** Blok `catch (_) {}` hanya boleh ada bila
   ditandai `// best-effort` pada baris yang sama.
2. **Kegagalan persistensi/state tidak boleh senyap.** Penulisan store, load
   data, backfill index, dan save saat shutdown yang gagal harus menghasilkan
   log `stderr.writeln('<komponen>: <aksi> gagal: $e')`.
3. **Gerbang otomatis:** `python3 scripts/audit_empty_catch.py` memverifikasi
   kebijakan ini (exit 1 bila ada catch kosong tanpa penanda). Jalankan di CI
   atau sebelum commit untuk mencegah catch kosong baru yang tak terkelola.

## Kegagalan berisiko yang kini ter-log (pilihan utama)

- **Scheduler**: `releaseRun`, `failDeliveryPermanently`, persist jadwal retry,
  audit event pemulihan — sebelumnya job bisa terjebak in-flight selamanya
  tanpa jejak.
- **Ollama native**: baris stream korup dan `arguments` tool bukan JSON valid —
  sebelumnya output terpotong/tool call rusak tanpa sinyal.
- **Memory (agent_memory)**: load `layered_memory`, load FTS index, backfill
  `facts_fts`, upsert/query `vec_facts`, meta korup, baris pesan korup pada
  `persistent_store` — sebelumnya degradasi pencarian/riwayat tanpa jejak.
- **Drift schema**: migrasi tabel virtual FTS gagal — sebelumnya FTS mati
  diam-diam.
- **Runtime shutdown**: `layeredMemory.save`, `lexical.save`,
  `reflectionEngine.save`, `skills.flushPendingSinks`, `spans.close`,
  `approvals.close`, `reflection.save` — sebelumnya kehilangan data saat
  shutdown tanpa jejak.
- **Agent loop**: refleksi/revision gagal — sebelumnya self-improvement mati
  diam-diam.
- **Skills Hub**: `installed.json` korup — sebelumnya daftar skill direset
  tanpa jejak.
- **Gateway**: whisper lokal gagal (fallback API), `answerCallbackQuery`
  Telegram, dispatch pesan Discord, loop voice UDP.
- **Context builder**: retrieve RAG/layered memory/provider eksternal gagal —
  sebelumnya konteks hilang diam-diam.

## Yang sengaja tetap best-effort (contoh)

- Cleanup sementara: delete temp file/dir, hapus lock usang, `docker rm`.
- Dispose berantai saat shutdown: plugin, MCP loader, sandbox, gateway.
- Callback notifikasi sekunder: `onDelivered`, `onDeliveryFailed`,
  `onDeliveryRetry`, `onFallback`, `onError`.
- Fallback by-design: self-consistency vote (pakai jawaban pertama), parse
  baris non-JSON pada stream ACP, meta parse → nilai default.
