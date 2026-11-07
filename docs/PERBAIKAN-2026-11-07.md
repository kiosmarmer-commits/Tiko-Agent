# MANIFEST PERBAIKAN — agent_dart (Tiko) — 7 November 2026

Dokumen ini merinci SEMUA file yang dibuat/diperbarui dalam sesi perbaikan
menyeluruh ini, alasannya, file lama yang perlu dihapus manual, item yang
ditunda (defer), dan langkah verifikasi WAJIB.

> CATATAN PENTING: karena keterbatasan izin Drive, setiap file yang
> diperbarui diunggah sebagai file BARU dengan nama sama di folder yang
> sama. **File versi lama (nama sama) di folder yang sama HARUS dihapus
> manual** agar tidak membingungkan compiler/IDE.

---

## 1. File yang diunggah (status: BARU = file sebelumnya tidak ada, GANTI = sudah ada versi lama → hapus manual)

### packages/agent_core/lib/src/
| File | Status | Isi perubahan |
|---|---|---|
| `agent_loop.dart` | GANTI | **[BUGFIX]** deklarasi `_lastRouteExplain` yang hilang (file lama TIDAK kompilasi). **[FR-01]** auto-draft skill lama (>=4 tool, tanpa cek sukses) diganti S_eval-gated: hanya turn SUKSES dengan S_eval ≥ 0.85 yang dikompilasi jadi SKILL.md; parameter baru `synthLlm` (LLM reflection, fallback naive) dan `skillEval` (bobot w1/w2/w3, threshold). |
| `context_builder.dart` | GANTI | **[FR-03]** field `expander` (ContextExpander?) — input user diekspansi @file/@dir/@git/@url sebelum dikirim ke LLM; best-effort, gagal ekspansi tidak memblokir turn. |
| `context_expander.dart` | BARU | **[FR-03]** ContextExpander: @file: (maks 32 KiB), @dir: (maks 200 entri), @git:diff/log/status, @url: (http/https, blokir localhost/private/link-local = SSRF guard, maks 64 KiB); path wajib di dalam workspace (symlink di-resolve, escape ditolak); envelope `<expanded_context>` dengan netralisasi closing tag. |
| `skill_synthesis.dart` | BARU | **[FR-01]** SkillEvalConfig (w1=0.5, w2=0.3, w3=0.2, threshold=0.85, saturasi tool=10, token referensi=20000); `SkillSynthesis.evalScore` (S_eval), `synthesizeDraft` (refleksi LLM → JSON {name, description, triggers, tools, steps, failures} → SKILL.md via SkillDraftBuilder), `naiveDraft` (fallback tanpa LLM). |
| `skill_gate.dart` | GANTI | **[FR-01]** kelas baru `SkillMatchScorer` (Score_gate = α·closeness + (1−α)·(successRate × ageDecay), α=0.7, half-life 30 hari) + `ScoredSkill`; embedder opsional (fallback Jaccard lexical). Kelas `SkillPromotionGate` asli TIDAK diubah. |
| `budget_guard.dart` | GANTI | getter `tokensUsed` (dibutuhkan agent_loop untuk S_eval). |

### packages/agent_core/ (root)
| File | Status | Isi perubahan |
|---|---|---|
| `agent_core.dart` | GANTI | export baru: `src/context_expander.dart`, `src/skill_synthesis.dart`. |

### packages/agent_security/lib/src/
| File | Status | Isi perubahan |
|---|---|---|
| `shell_policy.dart` | GANTI | **[FR-02]** metode baru `commandRisk(String) → double` — indeks R_cmd [0,1]: pola destruktif (rm -rf, mkfs, dd, shutdown, kill -9, chmod 777, fork bomb) +0.55; eskalasi privilege (sudo/su/doas) +0.30; curl/waget → interpreter +0.40; package manager +0.15; target sensitif (/etc, systemctl, iptables) +0.10; metakarakter → langsung 0.8. API `check()` asli TIDAK diubah. |

### packages/agent_tools/lib/src/
| File | Status | Isi perubahan |
|---|---|---|
| `patch_file.dart` | GANTI | **[FR-04]** parameter opsional `checkpointer`; snapshot workspace otomatis sebelum menulis (label `patch:<rel>`); id checkpoint dilaporkan di hasil tool. |
| `checkpoint.dart` | BARU | **[FR-04]** `WorkspaceCheckpointer` (snapshot salinan file → `.tiko/checkpoints/<id>/` + manifest.json; skip .git/.dart_tool/build/node_modules/.tiko; caps: file ≤256 KiB, ≤2000 file, rotasi 10 checkpoint) + `rollback(id)` + `list()`; tools: `RollbackTool` (risk high) dan `ListCheckpointsTool` (risk low). |
| `cdp_browser.dart` | BARU | **[FR-06]** `CdpSession` — Chromium/Chrome headless lokal via CDP (launch `--remote-debugging-port=0`, endpoint diparse dari stderr "DevTools listening on ws://..."; WebSocket + JSON-RPC; Target.createTarget/attachToTarget, Page.navigate, Runtime.evaluate awaitPromise); guard URL http/https + blokir host privat (opsional `allowPrivateUrls`); auto-detect executable (TIKO_CHROME_PATH/CHROME_PATH/kandidat umum). Tool: `CdpBrowserTool` (aksi navigate/evaluate/read_text/close, risk medium). |
| `sandbox.dart` | GANTI | **[FR-02]** enum baru `SandboxKind.ssh`; field `sshHost/sshPort/sshRemoteRoot`; eksekusi remote via `ssh -o BatchMode=yes <host> -- 'mkdir -p <cwd> && cd <cwd> && exec <argv>'` — token argv WAJIB shell-inert (regex ketat, tolak quoting/expansion); `SandboxRunner.dispatchFor(command, riskFn?)` — R<0.2 → bubblewrap→docker; 0.2–0.7 → docker; ≥0.7 → ssh (fallback docker); **none selalu fail-closed**; inject `ShellPolicy.commandRisk` via `riskFn` dari runtime untuk skoring terpusat (agent_tools tidak bergantung pada agent_security); probe `ssh` tersedia. Jalur bubblewrap/docker/none ASLI tidak diubah. |

### packages/agent_tools/lib/src/mcp/
| File | Status | Isi perubahan |
|---|---|---|
| `streamable_http.dart` | BARU | **[FR-07]** `McpStreamableHttpClient` — transport MCP Streamable HTTP self-contained (POST JSON-RPC, Accept application/json + text/event-stream, parse SSE `data:`, header `Mcp-Session-Id`, initialize/listTools/callTool/call generik, koleksi notifikasi server). |

### packages/agent_tools/ (root)
| File | Status | Isi perubahan |
|---|---|---|
| `agent_tools.dart` | GANTI | export baru: `src/checkpoint.dart`, `src/cdp_browser.dart`, `src/mcp/streamable_http.dart`. |

### packages/agent_gateway/lib/src/
| File | Status | Isi perubahan |
|---|---|---|
| `tts.dart` | BARU | **[FR-08]** `TtsProvider` (abstrak), `OpenAiTtsProvider` (endpoint OpenAI-compatible `POST {baseUrl}/audio/speech` — cocok untuk OpenAI/Groq/LM Studio), `ElevenLabsTtsProvider`, `TtsService.speakToFile`. |
| `hotword.dart` | BARU | **[FR-08]** `HotwordListener` (interface platform-agnostic "Hey Tiko"), `NoopHotwordListener`, `PushToTalkHotwordListener` (fallback hotkey). Implementasi native (Porcupine/openWakeWord/platform channel) menyusul di apps/agent_flutter. |
| `whatsapp_gateway.dart` | BARU | **[FR-07]** `WhatsAppGateway` — WhatsApp Business Cloud API (Meta Graph v20.0): `sendText` (Bearer token), `verifyWebhook` (GET handshake hub.challenge), `parseWebhook` (ekstraksi pesan teks masuk), hook `signatureVerifier` untuk validasi X-Hub-Signature-256. |
| `slack_gateway.dart` | BARU | **[FR-07]** `SlackGateway` — Incoming Webhook atau bot token (chat.postMessage), `parseSlashCommand`, `verifyEvent` (token), `parseEventMessage` (abaikan pesan bot → anti-loop). |

### packages/agent_gateway/ (root)
| File | Status | Isi perubahan |
|---|---|---|
| `agent_gateway.dart` | GANTI | export baru: `src/tts.dart`, `src/hotword.dart`, `src/whatsapp_gateway.dart`, `src/slack_gateway.dart`. |

### packages/tiko_runtime/lib/src/
| File | Status | Isi perubahan |
|---|---|---|
| `tiko_runtime.dart` | GANTI | **[FR-03+FR-01 wiring]** `_RuntimeContext` menerima `expander` (super); construction site utama menambah `expander: ContextExpander(workspaceRoot: workspace)`; `AgentLoop` diberi `synthLlm` (provider pertama dari router, null bila kosong → fallback naive draft). Tidak ada perubahan API lain. |

## 2. File FASE A (sudah diunggah sebelumnya — sesi yang sama, untuk kelengkapan)
| File | Lokasi Drive | Isi |
|---|---|---|
| `sqlite_store.dart` | agent_memory/lib/src | **[FR-10]** Reciprocal Rank Fusion (k=60) BM25 + cosine pada SqliteMemoryStore (merge skor ad-hoc lama diganti RRF, selaras InMemoryStore). |
| `cross_process_lock.dart` | tiko_runtime/lib/src | BARU: CrossProcessLock (tryLock poll 10s, acquireShared) — lock lintas proses file-based. |
| `approval_ledger.dart` | tiko_runtime/lib/src | lock+reload per mutasi (_withFileLock), wait() poll 800ms shared lock, _reloadFromDisk. |
| `offline_queue.dart` | tiko_runtime/lib/src | file lock setelah mutex in-process. |

## 3. File sampah di Drive yang WAJIB dihapus manual
Di folder root `agent_dart`:
- `test-pipeline` (Google Doc) — sisa uji pipeline.
- `test-dart.dart` — sisa uji pipeline.
- Semua file versi LAMA yang terduplikasi oleh unggahan ini (nama sama, modified time lebih lama) — terutama: `agent_loop.dart`, `context_builder.dart`, `skill_gate.dart`, `budget_guard.dart`, `shell_policy.dart`, `patch_file.dart`, `sandbox.dart`, `agent_core.dart`, `agent_gateway.dart`, `agent_tools.dart`, `tiko_runtime.dart` (pilih yang modified time TERBARU).

## 4. Item yang DITUNDA (defer) — dengan alasan
1. **Idempotency key tool calls (A4)** — butuh plumbing AgentLoop→ToolContext lintas paket; risiko regresi tinggi; desain: key = hash(sessionId+turn+tool+args) di ledger.
2. **Cron IANA/DST** — butuh dependency `package:timezone`; berisiko regresi pada scheduler. Default UTC tetap aman.
3. **Integrasi Score_gate penuh ke ContextBuilder** — `SkillMatchScorer` sudah tersedia; mengganti `skillRegistry.match()` lama butuh benchmark gate golden dulu (promosi skill vs match kontekstual berinteraksi).
4. **Wiring subagent runner di tiko_runtime** — desain lengkap (budget depth/token/waktu, inheritance permission, cancellation) ada di laporan P1; menunggu konsolidasi AgentLoop baru ini terverifikasi kompilasi.
5. **HMAC webhook penuh (WhatsApp X-Hub-Signature-256, Slack X-Slack-Signature)** — perlu `package:crypto` di pubspec agent_gateway; hook `signatureVerifier` sudah disediakan.
6. **Sandbox Singularity & Modal** — Blueprint FR-02 menyebut 5 backend; terimplementasi: local (bubblewrap), docker, ssh, none(fail-closed). Singularity/Modal butuh CLI/kredensial spesifik; pola Strategy sudah siap di SandboxKind.

## 5. Bug regresi yang DITEMUKAN & DIPERBAIKI
- `agent_loop.dart`: field `_lastRouteExplain` DIPAKAI tapi TIDAK PERNAH dideklarasikan — file lama tidak dapat dikompilasi. Dideklarasikan + getter publik `lastRouteExplain`.
- Auto-draft skill lama bisa terpicu pada turn GAGAL (hanya cek jumlah tool). Sekarang wajib turn sukses + S_eval ≥ 0.85.

## 6. Langkah verifikasi WAJIB (jalankan di mesin Anda)
```bash
# 1. sinkronkan file baru dari Drive (replace semua file lama, hapus duplikat)
# 2. lalu:
cd agent_dart
dart pub get          # di root & setiap packages/* dan apps/*
bash scripts/validate.sh
bash scripts/flutter_validate.sh   # untuk apps/agent_flutter
```
Kriteria lulus: nol error analisis statis; test golden skill dan sandbox tetap hijau.

## 7. Hal yang TIDAK diubah (sengaja, demi stabilitas)
- API `ShellPolicy.check()` (allowlist structured argv) — R_cmd hanya ADDITIF.
- `SkillPromotionGate` (pipeline draft→scanned→evaluated→canary→approved).
- Semua jalur sandbox bubblewrap/docker asli, termasuk probe namespace.
- Provider fallback chain, compactor, loop detector, taint marking, audit.
