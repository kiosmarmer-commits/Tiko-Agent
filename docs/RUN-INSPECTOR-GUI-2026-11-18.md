# GUI-P2-04b: Run-inspector — 2026-11-18

Item **Run-inspector** (backlog audit GUI lanjutan: "Run detail yang kaya
— plan/steps/tool/subagent"): admin kini dapat **melihat turn agent yang
sedang aktif dan riwayat terbaru** — termasuk langkah tool per run
(nama, verdict gate, error, durasi), subagent parent, token, dan durasi
— di atas endpoint yang benar-benar ada (`GET /v1/runs`). Data berupa
snapshot in-memory yang diinstrument langsung di jalur `chatWithStatus`;
input/answer disanitasi `SecuritySanitizer` saat direkam (TIDAK ada
args tool maupun konten mentah yang bocor).

## 1. Runtime (`packages/tiko_runtime`)

- Kelas `RunStep` / `InspectedRun` / `TurnInspector` (top-level,
  exported): registri in-memory bounded — ring maksimum **50 run**, ring
  langkah maksimum **100 langkah per run**.
- `chatWithStatus` menjadi **wrapper instrumentasi** yang mendelegasikan
  ke `_chatWithStatusCore` (isi asli tak berubah): `begin` mencatat
  sesi/channel/pratinjau input (sanitasi + potong 240 char), `finish`
  mencatat success/tokens/tool count/pratinjau jawaban, `catch` mencatat
  error lalu `rethrow`. Subagent (`session: parent/sub/...`) otomatis
  terdeteksi sebagai run anak dengan `parent`.
- Hook `audit` di loop memanggil `turnInspector.recordTool(...)` pada
  setiap tool call nyata (eksekusi maupun deny) — nama, verdict gate
  (`verdict.verdict.name`), `is_error`, `duration_ms`.
- `TikoRuntime.turnInspectorSnapshot({limit = 40})` →
  `{active: [...state=running], recent: [...done/error terbaru dulu],
  truncated}`; murni observasi, tidak memengaruhi turn.

## 2. Gateway (`packages/agent_gateway`)

- Callback `runsProvider()` — null → `501 not_implemented`.
- Route `GET /v1/runs` (read-only; method lain → 404; auth bearer).

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- `runsProvider: () async => rt.turnInspectorSnapshot()`.

## 4. Flutter (`apps/agent_flutter`)

- DTO: `RunStepEntry` (tool/verdict/isError/durationMs/at), `RunEntry`
  (id/session/channel/subagent/parent/input/state/startedAt/endedAt/
  durationMs/success/tokensUsed/toolCalls/answer/error/steps + getter
  `running`), `RunsSnapshot` {active, recent, truncated}.
- Klien: `listRuns()` (GET `/v1/runs`, timeout 15s); repo
  `runInspector()`.
- `ui/runs_page.dart` (`RunsPage`, StatelessWidget): header
  (jumlah aktif + riwayat + flag terpotong), tombol refresh, bagian
  **AKTIF** (badge RUNNING) dan **RIWAYAT** (badge SELESAI/GAGAL/ERROR);
  tiap run `ExpansionTile` — subtitle subagent link parent, konten
  expand: laporan jawaban/error + daftar langkah tool monospace berwarna
  (✓ hijau / × merah, verdict + durasi).
- Route `AppRoute.runs` (rail "Runs", ikon play_circle, non-primary →
  kelompok More di mobile); **lazy load** saat pertama masuk route
  (bukan bagian refreshAdmin) + tombol muat ulang manual; More page
  memuat ListTile Runs (jumlah aktif).

## 5. Web parity (`apps/agentd/web`)

- Tab **Runs**: tombol muat ulang, daftar label AKTIF/RIWAYAT + item run
  (judul pratinjau input, meta badge/status/subagent/langkah); klik item
  expand/collapse daftar langkah; semua render via `textContent` —
  payload ber-`<script>` dibuktikan aman di test harness. Test node +2
  (25 total).

## 6. Dokumentasi & test

- Test: runtime 3 baru (`run_inspector_test.dart` — unit inspector +
  ring/step cap + integrasi mock `single_tool` merekam step `datetime`),
  gateway 2 baru (`http_api_runs_test.dart`), Flutter 9 baru (4
  repository + 5 view), web 2 baru.
- Verifikasi: `dart analyze` tiko_runtime/agent_gateway/agentd bersih;
  `dart test` tiko_runtime 272, agent_gateway 182, agentd 7 — semua
  lulus; `flutter analyze` bersih; `flutter test` 234 lulus;
  `flutter build web --release` sukses; `node --test` 25 lulus.

## Yang TIDAK termasuk

- **Read-only** — TIDAK ada aksi stop/cancel turn dari GUI (cancel tetap
  via `rt.cancelTurn`/channel lain; evaluasi endpoint stop menyusul).
- **Snapshot polling, bukan streaming** — langkah muncul setelah tool
  selesai (`audit` callback dipanggil post-eksekusi); TIDAK ada
  langkah "sedang berjalan" real-time maupun stream WS per langkah.
- Registri **in-memory, hilang saat restart** daemon; ring maksimum
  50 run / 100 langkah per run.
- **TIDAK ada** args tool di langkah (hanya nama/verdict/error/durasi)
  — konten pratinjau input/answer memakai sanitizer runtime, terpotong
  240 char.
- Belum ada detail plan eksekusi (PlanExecute) per run, drill-down
  provider/router, atau riwayat lintas restart.
