# Batch Gap Kritis Hermes-Parity (2026-11-13)

Basis: analisis gap pasca-batch optimisasi (`HERMES-PARITY-BATCH-2026-11-13.md`). Tiga gap kritis dikerjakan tuntas satu per satu: email inbound, pipeline trajectory→training ala Atropos, dan wizard onboarding terpadu. Agent manager UI, LSP, dan QA perangkat nyata tetap out-of-scope (kebijakan backlog P2).

## Item yang dikerjakan

| ID | Item | Implementasi |
|----|------|--------------|
| GAP-1 | Email inbound ke daemon | `ImapPoller` (`packages/agent_gateway/lib/src/imap_client.dart`): klien IMAP4rev1 poll minimal — TLS-only (implicit TLS, `onBadCertificate` menolak), literal-aware byte reader (`{n}` literal di tengah respons), LOGIN/SELECT/SEARCH UNSEEN/FETCH (BODY.PEEK[])/STORE `\Seen`/LOGOUT, koneksi baru per poll. Parser pesan: header folding, RFC 2047 encoded-words (B/Q), Content-Transfer-Encoding base64/quoted-printable, extract alamat dari `From`. Allowlist pengirim wajib (fail-closed, pola `TG_ALLOW`); pesan pengirim tak diizinkan tetap ditandai `\Seen` agar tidak diproses ulang. Wiring `agentd`: env `IMAP_HOST/IMAP_PORT/IMAP_USER/IMAP_PASSWORD/IMAP_ALLOW/IMAP_POLL_SEC` → `EmailGateway.pushInbound` → jalur chat normal; shutdown rapi via `stop()` |
| GAP-2 | Pipeline trajectory→training ala Atropos | (a) `TrajectoryLogger.exportShareGpt()`: ekspor format ShareGPT JSONL (satu objek percakapan per sesi, turn terurut timestamp) dengan privacy guard yang sama seperti `exportForTraining` (redaksi secret, exclude sesi, cap field). (b) `TrajectoryCompressor.compress()`: kompresi dataset (cap per turn, batas turn per percakapan, buang baris kosong/rusak). (c) `BatchRolloutRunner`: batch rollout dengan executor terinjeksi (`TikoRuntime.chatWithStatus` di host), konkurensi terbatas, urutan hasil deterministik, reward function pluggable (default sparse 1/0), tiap turn ter-log ke trajectory. Training sendiri tetap di luar proses (konsumen: Atropos/Tinker) |
| GAP-3 | Wizard onboarding terpadu | `OnboardingWizard` (`packages/tiko_runtime/lib/src/onboarding.dart`) + `tiko setup --interactive`: satu alur mengumpulkan tipe provider (tipe bawaan/preset/transport divalidasi), API key, base_url/model, dan gateway opsional (Telegram/Discord/SMTP/IMAP). Config ditulis via `ConfigStore` (ter-revision) dengan **SecretRef `env:VAR` saja** — secret tidak pernah masuk YAML; semua nilai rahasia ditulis ke `<dataDir>/gateway.env` dengan pola atomik tmp + chmod 600 + rename (pola `ApiTokenStore`); nilai mengandung newline ditolak |

## Bug nyata yang ditemukan dan diperbaiki

- **Race append `TrajectoryLogger.logTurn`**: dua turn konkuren (rollout paralel / sesi bersamaan) membuka file JSONL hari yang sama pada offset akhir yang sama — tulisan kedua menimpa yang pertama sehingga baris trajectory hilang. Kini appends diserialisasi via rantai future (pola `SkillMetricsLedger`).

## Keputusan desain

- IMAP: TLS implicit wajib; tanpa MIME multipart tree-walking (body teks dipakai apa adanya setelah decode transfer-encoding) dan tanpa IDLE — poll berkala cukup untuk gateway; koneksi baru per poll menjaga state server sederhana.
- `\Seen` ditandai SETELAH fetch berhasil, terlepas dari keputusan allowlist — mencegah loop pemrosesan ulang pesan spam.
- Pipeline RL: kontrak minimal (`RolloutExecutor` + `RewardFn`) agar host menyuntikkan runtime konkret; modul tidak bergantung `tiko_runtime` (berada di agent_core).
- Wizard: prompt interaktif tinggal di CLI (tidak testable via stdin), logika murni + penulisan file di `tiko_runtime` agar teruji; config via `ConfigStore` agar masuk riwayat revisi.

## Tes

- `packages/agent_gateway/test/imap_client_test.dart`: 6 kasus (poll unseen → emit → `\Seen`, allowlist menandai tapi tidak emit, LOGIN gagal → StateError, RFC 2047 Q + base64 body, quoted-printable + header folding, SEARCH kosong).
- `packages/agent_core/test/rl_pipeline_test.dart`: 8 kasus (runner deterministik + log, exception executor → rollout gagal, reward custom, ShareGPT grouping + redaksi + exclude, direktori kosong, kompresi cap + buang baris tak valid, file hilang, end-to-end rollout → export → compress).
- `packages/tiko_runtime/test/onboarding_test.dart`: 9 kasus (config YAML preset/mock/ollama valid + api_key SecretRef, tipe tak dikenal ditolak, env file terurut + newline ditolak, writeAll 0600 + validasi load, tolak overwrite tanpa force, force overwrite, derivasi nama env var).
- Full suite: 13 workspace member `dart analyze --fatal-warnings` bersih; `dart test` lulus semua — agent_core 153, agent_gateway 69, tiko_runtime 134, agent_memory 86, agent_security 60, agent_tools 249, prediksi 108, agent_calc 132, agent_providers 44, agent_scheduler 35, agentd 5 (+23 test baru dibanding batch sebelumnya).

## Batasan yang dicatat

- IMAP poller tidak mengunduh lampiran dan tidak mem-parse multipart alternative/HTML — body teks plain (atau decoded transfer-encoding) yang dipakai.
- Env file harus di-`source` sebelum agentd start (agentd membaca `Platform.environment`); instruksi dicetak wizard.
- Pipeline RL belum menyediakan environment wrapper penuh gaya `HermesAgentBaseEnv` (reset/step RL formal) — kontrak rollout saat ini task-level, cukup untuk generasi dataset SFT/RL batch.
