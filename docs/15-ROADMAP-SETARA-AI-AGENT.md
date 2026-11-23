# 15 — Roadmap Setara & Unggul vs AI Agent Lain

> **Catatan status:** dokumen ini adalah roadmap implementasi untuk menaikkan kapabilitas Tiko-Agent ke level setara (lalu unggul) dibanding agen AI mainstream, berdasarkan analisa gap (lihat `HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md` dan `docs/12`). Source dan test adalah kontrak implementasi.

**Terakhir diperbarui:** November 2026.

## 0. Prinsip

1. **Additive saja** — tidak ada fitur/fungsi yang dihapus; perilaku fail-closed default tetap default.
2. Setiap fase = 1 PR per fase (pola `vibe/<slug>-ed0e3f`) dengan test dan inventaris uji mengikuti konvensi repo.
3. Tanpa dependensi baru kecuali dijustifikasi; agen tetap untrusted dan semua aksi mediasi host.
4. Prioritas ditentukan pengungkit: kemampuan yang membuka fungsi lain didahulukan.

## 1. Status fase

| Fase | Judul | Status | Ringkasan |
|---|---|---|---|
| F1 — Daya eksekusi nyata | Host-exec opt-in + smoke setup | ✅ selesai | `sandbox.allow_host_exec` + `tiko setup --smoke` + panduan sandbox install.sh — lihat §2 |
| F2 — Coding agent | Repo map, git toolset, edit-loop | 🔄 berjalan | bagian 1 (code_context + git toolset) selesai; bagian 2 (edit-loop guard + IdeIntegration) menyusul — lihat §3 |
| F3 — Debugging superior | Error recall, log probe, post-mortem | ⏳ belum | lihat §4 |
| F4 — Riset unggul | Multi-putaran refine + verify claims | ⏳ belum | lihat §5 |
| F5 — Otonomi & scheduling | context_from, digest, watcher | ⏳ belum | lihat §6 |
| F6 — Tuntas integrasi | smart-home wiring, voice/memory adapters | ⏳ belum | lihat §7 |
| F7 — Keunggulan kompondensal | Eval harness, cost observability | ⏳ belum | lihat §8 |

## 2. Fase F1 — Daya eksekusi nyata

Masalah: `ShellTool` ditolak fail-closed bila tidak ada sandbox OS (`SandboxKind.none` → `UnsupportedError`) dan default provider mock — di host polos, kemampuan eksekusi agen nyaris nol.

1. **`sandbox.allow_host_exec` (default `false`)** — ✅: bila tidak ada sandbox OS tersedia, tool `shell` menjalankan argv array **TANPA interpreter shell** (pola `verify_project` di `verify_tool.dart`): validasi metachar + `PathSafety` (symlink-aware) + jail workspace tetap berjalan, timeout 15s, output cap 50.000 char. Konvensi mengikuti `CodeExecutionConfig.allowUnsafeLocalExecution` (`docs/07` §5).
   - Config: `tiko_config.dart` (`sandboxAllowHostExec`), wiring `tiko_runtime.dart` → `createBuiltinTools(allowHostExec: ...)`, implementasi `builtin.dart` (`ShellTool.allowHostExec`).
   - Uji: `shell_host_exec_test.dart` (flag off → ditolak; flag on → output/exit nyata; jail & metachar tetap), `tiko_config_test.dart` (parse default/true/non-bool).
2. **Smoke-test provider pasca-setup** — ✅: `tiko setup --smoke` menjalankan satu turn agentic uji (“hitung 5+1” → tool `calc` → jawaban “6”) lewat `TikoRuntime.create` + `chatWithStatus`; turn 1 tool call ≈70 ms dengan mock; gagal → exit code 1 dengan pesan; health/circuit-breaker probe tetap tersedia via `tiko doctor --probe`.
   - Uji: `tiko_cli_test.dart` (parse `--smoke`), smoke langsung di temp dir.
3. **Auto-bootstrap sandbox lokal** — ✅: `install.sh` mendeteksi `bwrap`/`docker` dan bila absen memandu satu perintah (`sudo apt-get install -y bubblewrap`) + alternatif `sandbox.allow_host_exec`; `doctor` check `sandbox` tetap memberi instruksi setara saat runtime.

## 3. Fase F2 — Coding agent kelas Claude Code

1. **Repo map + `code_context`** — ✅ bagian 1: `CodeContextTool` (risk low, parallelSafe) — action `map`/`find`/`refs` via regex parser per bahasa (Dart class/mixin/enum/extension + top-level function; Python def/class; JS-TS function/class; Go/Rust/Java/Kotlin terindeks) di atas workspace, stateless (pindai ulang tiap panggilan), guard `maxFiles=2000`/`maxFileSize=256KB`/junk-dir skip, path jail PathSafety, limit 1-50. Terdaftar di `tiko_runtime.dart`. Uji: `code_context_test.dart` (map/find/refs/fail-closed/path keluar/subdir).
2. **Git toolset aman** — ✅ bagian 1: `GitCommandRunner` (argv array, `runInShell: false`, timeout 30s, jail `-C workspaceRoot`) + `git_status`/`git_diff`/`git_log` (read-only) + `git_commit` (risk medium; message 1-200 char tanpa kontrol char; hanya staged atau pathspec eksplisit tervalidasi; tanpa amend/force; fail-closed bila tidak ada yang distage). Uji: `git_tools_test.dart` (7 skenario).
3. **Edit loop guard** (opsional per config `agent.edit_loop_verify`) — ⏳ bagian 2: setelah `patch_file` wajib `verify_project` sukses sebelum aksi berikutnya — memakai loop detector yang sudah ada sebagai fondasi.
4. **Selesaikan wiring `IdeIntegrationTool`** (toolbank memakai `tools: []` di `builtin.dart`) — ⏳ bagian 2: sambungkan registry nyata + test ACP.

## 4. Fase F3 — Debugging superior (diferensiasi)

1. **Auto-recall error memory**: ContextBuilder menarik sampai 3 kesalahan mirip dari `ErrorMemoryStore` (pola `MemoryNudgeEngine` yang sudah ada) — agen mengingat bug lintas sesi.
2. **Tool `log_probe`** (read-only, fail-closed): tail/grep log di `data/logs` + journald opsional, terintegrasi `TurnInspector` → agen menganalisis jejak run-nya sendiri.
3. **Post-mortem procedural**: reflection engine menulis "lesson" ke layered memory (procedural) setelah verify gagal 2× lalu sukses.

## 5. Fase F4 — Riset unggul

1. **Multi-putaran `deep_research`** (gap terdok `docs/13` §1): iterasi critique→re-plan maks 2 putaran, budget-guarded.
2. **Wire `verify_claims` (evidence ledger) ke laporan riset** sebelum terbit.
3. **Dedupe sumber + export markdown/PDF** ke channel gateway.

## 6. Fase F5 — Otonomi & scheduling

1. **`context_from` chaining antar-job** (gap terdok `docs/13` §1).
2. **Digest proaktif harian** ala Pulse/Hermes (cron + riset + gateway yang sudah ada).
3. **Watcher job**: probe periodik (`verify_project`/URL) yang memicu turn agen hanya saat status berubah.

## 7. Fase F6 — Penuntasan integrasi (tanpa menghapus apa pun)

1. **Smart-home wiring user-facing**: tool/REST + consent (README mencatat provider masih "library + test contract").
2. **Voice breadth** (TTS/STT provider) dan **adapter memori cloud first-class** — gap `HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md` §"Yang masih gap".
3. **A2UI tersisa (E9 Video/Audio, katalog chart lanjutan)** — hanya bila keputusan `docs/14` diubah (video_player) / opsional.

## 8. Fase F7 — Keunggulan kompondensal

1. **Eval harness rilis**: batch + trajectory export (sudah implemented, `docs/12` P5) → eval regresi otomatis per rilis; skor guard/skill jadi gerbang CI.
2. **Cost/token observability per user/channel** di halaman Runs (agregasi dari `TurnInspector` + persist).
3. **Dukung diferensiator yang sudah berjalan**: sandbox fail-closed + approval + audit yang lebih ketat dari kebanyakan agen (dipertahankan), scheduler tahan DST, A2UI generative-UI.
