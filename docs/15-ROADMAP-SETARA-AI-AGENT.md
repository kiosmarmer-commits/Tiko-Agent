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
| F2 — Coding agent | Repo map, git toolset, edit-loop | ✅ selesai | `code_context` + git toolset aman + edit-loop guard + wiring IdeIntegration — lihat §3 |
| F3 — Debugging superior | Error recall, log probe, post-mortem | ✅ selesai | `agent.error_recall` auto-recall 3 kecocokan/turn + tool `error_lookup`/`error_record` + `log_probe` (list/tail/grep/runs) + `VerifyPostMortem` lesson procedural — lihat §4 |
| F4 — Riset unggul | Multi-putaran refine + verify claims | ✅ selesai | refine terarah maks 2 putaran budget-guarded + verifikasi klaim evidence + dedupe sumber + ekspor PDF pure-Dart — lihat §5 |
| F5 — Otonomi & scheduling | context_from, digest, watcher | ✅ selesai | watcher probe + digest harian + chaining konteks (PR #164) — lihat §6 |
| F6 — Tuntas integrasi | smart-home wiring, voice/memory adapters | ✅ selesai | smart-home REST (F6.1) + STT chain lengkap 10 provider (F6.2); A2UI E9 opsional sesuai docs/14 — lihat §7 |
| F7 — Keunggulan kompondensal | Eval harness, cost observability | ✅ selesai | eval gate offline-first di CI + ledger cost per user/channel/day (PR #166) — lihat §8 |
| F8 — Otonomi aman bertingkat | Profil security + approval-remember | ✅ selesai | `security.profile` (strict/standard/trusted_workspace) + mode `guided` + `risk_overrides` + approval-remember session/workspace — lihat §9 |

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
3. **Edit loop guard** (opsional per config `agent.edit_loop_verify`, default false) — ✅: `EditLoopGuard` di `agent_core` — setelah `patch_file` sukses, seluruh tool lain ditahan fail-closed (hasil error ke model, bukan eksekusi) sampai `verify_project` sukses; state di-reset tiap turn; tool yang gagal verifikasi tetap menahan. Terintegrasi `AgentLoop(editLoopVerify:)` di jalur chat runtime; guard blok tercatat di audit sebagai denial. Uji: `edit_loop_guard_test.dart` (state machine 5 + integrasi loop 2).
4. **Selesaikan wiring `IdeIntegrationTool`** — ✅: konfigurasi `agent.ide_integration` (default false, fail-closed); saat aktif, tool terdaftar di runtime dengan `ToolRegistry` nyata — daftar tool ACP (`listTools`,capabilities,resources) dibaca **live** dari registry (termasuk tool MCP/script/script-tools yang dimuat belakangan) via `ToolRegistry.all`. Uji: `ide_integration_registry_test.dart` (listing live, executeTool via registry, factory), `tiko_config_test.dart` (parse kedua flag).

## 4. Fase F3 — Debugging superior (diferensiasi)

1. **Auto-recall error memory**: ContextBuilder menarik sampai 3 kesalahan mirip dari `ErrorMemoryStore` (pola `MemoryNudgeEngine` yang sudah ada) — agen mengingat bug lintas sesi.
2. **Tool `log_probe`** (read-only, fail-closed): tail/grep log di `data/logs` + journald opsional, terintegrasi `TurnInspector` → agen menganalisis jejak run-nya sendiri.
3. **Post-mortem procedural**: reflection engine menulis "lesson" ke layered memory (procedural) setelah verify gagal 2× lalu sukses.

## 5. Fase F4 — Riset unggul

1. **Multi-putaran `deep_research`** — ✅: setelah review pertama, kritik reviewer memicu `refine` terarah (`_refinePlannerPrompt` → query BARU anti-duplikat → gather slot `r<n>q<i>` → re-sintesis → re-review), maks 2 putaran (`maxRefineRounds` 0..2) dengan budget guard `tokenBudget` (runtime: 60k eco / 300k standard). default `maxRefineRounds: 0` = perilaku lama (kompatibilitas). Event: `research.refine_started|refine_planned|refine_noop|refine_failed`; catatan review efektif = hasil review terakhir.
2. **Wire `verify_claims` (evidence ledger) ke laporan riset** — ✅: stage `__verify` (opt-in `verifyClaims`, diaktifkan di runtime) mengecek ulang ≤3 klaim utama dengan tool riset, mengikat bukti via `claim`, lalu `verify_claims`; hasil jadi bagian `## Verifikasi Klaim` laporan; gagal/`VERIFIKASI_TIDAK_TERSEDIA` bersifat jujur tidak menggagalkan laporan. `claim`/`verify_claims` masuk allowlist tool riset (`defaultResearchTools`).
3. **Dedupe sumber + export markdown/PDF** — ✅: `dedupeSources` (fragment + parameter pelacakan `utm_*`/`fbclid`/`gclid`/`msclkid`/`ref` dibuang, trailing slash rata, case-insensitive, idempoten) diterapkan pada laporan final; ekspor PDF pure-Dart tanpa dependensi (`research_pdf.dart`, `buildPdfReport` → A4 Helvetica multi-halaman) disimpan best-effort `reports/riset-<id>.pdf` (`ResearchRunStore.savePdfReport`, field `pdf_name` additive + `refine_rounds`); digest job riset menyertakan jalur PDF; tool `deep_research` menampilkan `pdf=`.

## 6. Fase F5 — Otonomi & scheduling

1. **`context_from` chaining antar-job** (gap terdok `docs/13` §1).
2. **Digest proaktif harian** ala Pulse/Hermes (cron + riset + gateway yang sudah ada).
3. **Watcher job**: probe periodik (`verify_project`/URL) yang memicu turn agen hanya saat status berubah.

## 7. Fase F6 — Penuntasan integrasi (tanpa menghapus apa pun)

1. **Smart-home wiring user-facing** — ✅ selesai: tool `smart_home` (high-risk, approval-gated) ter-register di runtime + REST user-facing di gateway: `GET /v1/smart-home` (daftar provider), `GET /v1/smart-home/devices?provider=`, `GET /v1/smart-home/devices/{provider}/{id}`, `POST /v1/smart-home/devices/{provider}/{id}/execute` (auth token sama dengan endpoint mutasi lain; provider tak dikenal 404, error upstream 502, payload non-objek 400). Consen provider tetap via allowlist env (`allowedEntityIds` Home Assistant + kredensial khusus env).
2. **Voice breadth** (TTS/STT provider) dan **adapter memori cloud first-class** — gap `HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md` §"Yang masih gap".
   - STT MiniMax (`POST /v1/speech_to_text`, model `asr-1.0`) ditambahkan ke fallback chain `SttClient` (Groq Whisper/Mistral/ElevenLabs/xAI/DeepInfra sudah ada sebelumnya); wiring env per-provider di agentd (`GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `ELEVENLABS_API_KEY`, `DEEPINFRA_API_KEY`, `MINIMAX_API_KEY`, `STT_LOCAL_COMMAND`).
   - STT **Gemini** (`POST /v1beta/models/{model}:generateContent`, audio `inline_data` base64, header `x-goog-api-key`) — provider terakhir dari daftar Hermes: chain STT kini `local`, `local_command`, `groq`, `openai`, **`gemini`**, `mistral`, `xai`, `elevenlabs`, `deepinfra`, `minimax` (model default `gemini-2.0-flash`, override env `GEMINI_STT_MODEL`); wiring env agentd `GEMINI_API_KEY`.
   - Adapter memori cloud (RetainDB/ByteRover/Supermemory) sudah tersedia di `agent_memory`; tidak ada pekerjaan tambahan.
3. **A2UI tersisa (E9 Video/Audio, katalog chart lanjutan)** — hanya bila keputusan `docs/14` diubah (video_player) / opsional.

## 8. Fase F7 — Keunggulan kompondensal

1. **Eval harness rilis**: batch + trajectory export (sudah implemented, `docs/12` P5) → eval regresi otomatis per rilis; skor guard/skill jadi gerbang CI — ✅ selesai (pendekatan offline-first, keputusan pengguna):
   - Gerbang guard: harness prompt-injection Indonesia (40 kasus deterministik, tanpa LLM) di `agent_security` — `injection_eval_test.dart` (akurasi 100% dicegat CI).
   - Gerbang task: `eval_gate.dart` (part tiko_runtime) — `EvalTaskSpec` + `parseEvalTasksJsonl` + `runEvalGate` (urutan deterministik, alasan gagal eksplisit, skor pass-rate, `gate_passed`); dataset emas `test/fixtures/eval_golden.jsonl` dijalankan atas runtime + provider `mock` (skenario `assisted`, 100% offline).
   - `scripts/eval_gate.sh`: tahap offline dulu; bila gagal dan `TIKO_EVAL_LIVE_CONFIG` diset, fallback ke eval live provider LLM asli (`TIKO_EVAL_LIVE=1`, fixture `eval_live.jsonl` success-only, 3 task beranggaran) — sesuai keputusan "offline first, fallback token provider asli".
   - CI: langkah khusus "Eval gate (F7.1, offline deterministik)" di workflow `ci.yml` (job dart).
2. **Cost/token observability per user/channel** di halaman Runs (agregasi dari `TurnInspector` + persist) — ✅ selesai:
   - `packages/tiko_runtime/lib/src/cost_ledger.dart`: `CostEntry` + `CostLedger` (persist JSONL `turn_costs.jsonl`, atomic tmp+rename, tail-trim 5.000 entri, skip baris korup fail-soft); `summary({group_by: user|channel|day, days})` mengembalikan total + bucket terurut token.
   - Wiring runtime: `chatWithStatus` mencatat setiap turn user-facing (turn internal `internalCommand: true` dilewati), deterministik (di-await), fail-soft via event `cost.record_failed`.
   - REST: snapshot `GET /v1/runs` kini menyertakan blok `cost` (pass-through `turnInspectorSnapshot`).
   - Web UI: kartu "BIAYA/TOKEN (7 HARI)" di halaman Runs (total + tabel top bucket, parsing defensif di `apps/agent_flutter/lib/data/models.dart`).
3. **Dukung diferensiator yang sudah berjalan**: sandbox fail-closed + approval + audit yang lebih ketat dari kebanyakan agen (dipertahankan), scheduler tahan DST, A2UI generative-UI.

## 9. Fase F8 — Otonomi aman bertingkat (security UX)

Masalah: user baru menghadapi friksi konfirmasi berulang (`verify_project` selalu high meski read-mostly, allowlist shell tidak mencakup toolchain dev, konfirmasi identik tak pernah diingat) sementara mode `auto` justru MENOLAK tool high alih-alih menanyakan.

Prinsip desain: turunkan FREKUENSI konfirmasi, jangan hapus lapisan mediasi host. Semua lapisan tetap berjalan: ShellPolicy (metachar), jail workspace PathSafety, taint C-03, audit, capability token.

1. **`security.profile` (F8.1)** — ✅: preset `strict` (default, perilaku lama), `standard`, `trusted_workspace` di `tiko_config.dart`; preset hanya mengisi field yang TIDAK diset eksplisit di `security.*` (nilai eksplisit selalu menang).
   - `strict`: mode `ask`, allowlist bawaan (`ls/cat/git status/pwd/echo`), tanpa override.
   - `standard`: mode baru `guided` (medium/low auto; high SELALU dikonfirmasi, never auto; shell di luar allowlist dikonfirmasi — bukan ditolak; metachar tetap ditolak keras) + allowlist toolchain dev (`dart`, `flutter`, `make`, `cmake`, `gcc`, `g++`, `clang`, `javac`, `java`, `go`, `cargo`, `rustc`, `npm`, `node`, `npx`, `python`, `python3`, `pip`, `pip3`, `pytest`, `grep`, `wc`, `head`, `tail`, `find`, `git status/diff/log`) + `risk_overrides: {verify_project: medium}`.
   - `trusted_workspace`: seperti `standard` plus `require_confirm` dikosongkan (medium sudah auto; high tetap dikonfirmasi oleh gate).
   - Profil tidak dikenal → fallback `strict` + issue non-fatal.
2. **`security.risk_overrides` (F8.1)** — ✅: map `tool -> low|medium|high|critical` divalidasi (label tak valid → issue non-fatal + entri diabaikan), diteruskan ke `MatrixPermissionGate.riskOverrides` (runtime + Tirith); override diterapkan terhadap risiko efektif strictest-of, kepemilikan operator di luar jail workspace.
3. **Approval-remember (F8.2)** — ✅: `approval_rules.dart` (part tiko_runtime) — setelah confirm `y`, CLI bertanya "Ingat aksi ini? [t]idak / [s]esi / [w]orkspace"; rule session in-memory (per sesi), rule workspace persist `data/approval_rules.json` (fail-soft, entri korup dilompati); match = tool sama + prefix perintah shell penuh yang diingat (`flutter test` tidak mengizinkan `flutter clean` otomatis); gate tetap berjalan — hanya prompt identik yang di-skip.
4. **`execute_code` polyglot (F8.3)** — ✅: `ExecutionLanguage` kini 9 bahasa (python, javascript, bash, dart, java, go, c, cpp, rust) dengan docker image resmi per bahasa; bahasa interpreted langsung dijalankan (`java script.java` single-file, `go run`), bahasa compiled (C/C++/Rust) memakai model compile-then-run satu langkah di temp dir (binari tidak pernah jatuh di workspace); `LocalCodeExecutionProvider.interpreterAvailable()` probe ketersediaan untuk fail-soft; `allowedLanguages` default kini semua bahasa (mediasi tetap via sandbox/docker/host-exec opt-in + gate high);
   - Uji: `polyglot_execution_test.dart` — eksekusi nyata per bahasa yang tersedia di host (fail-soft bila tidak), model enum, fail-closed `allowedLanguages`, schema enum lengkap.
5. **Registry 100 bahasa (F8.3b)** — ✅: `language_registry.dart` — `LanguageSpec` data-driven (bukan enum): **+43 bahasa didukung** di luar 9 inti (C#, TypeScript via strip-types, SQL/sqlite, PHP, Swift, Kotlin, R, Ruby, Lua, PowerShell, Perl, Haskell, Julia, Elixir, Clojure, Groovy, F#, Scala, Fortran(gfortran), COBOL(cobc), Ada(gnat), Objective-C, Common Lisp(sbcl), Scheme(guile), Prolog(swipl), Erlang(escript), OCaml, Crystal, Nim, Zig, D(dmd), Smalltalk(gst), Verilog(iverilog+vvp), Modula-2(gm2), Racket, Forth, Io, Factor, J, PostScript(gs), Awk, Tcl, FreeBASIC, Gambas, Pascal(fpc), **Brainfuck via interpreter built-in Dart**); ~40 bahasa proprietary/GUI/mainframe (ABAP, Scratch, Apex, Solidity, RPG, Natural, PL/I, dsb.) **ditolak eksplisit dengan alasan** — bukan error kabur; alias umum (`c++`, `c#`, `golang`, `standard ml`, dsb.); eksekusi registry via `sh -c` template `{file}` dengan cwd temp dir (artefak `tiko_prog` tidak jatuh ke workspace); docker image resmi per bahasa yang ada; `allowedLanguageNames` whitelist opsional; fail-soft toolchain absen (probe PATH, tanpa eksekusi).
   - Uji: `language_registry_test.dart` (11) — daftar 100 bahasa user semuanya terwakili, alias, BF hello-world + kap langkah, whitelist, fail-closed unsupported.
6. **Peta lanjutan F8.4** (belum): provisioning toolchain otomatis `doctor --fix` (unduh/set toolchain saat absen), auto-approve paket/apt dengan konfirmasi sekali per toolchain.
5. **FFI in-process tetap ditolak** — dengan alasan arsitektur yang sama seperti `video_player` (docs/14): artefak eksekusi bersifat sementara; polyglot lewat proses/container terpisah.
