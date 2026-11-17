# 09 — Backlog dan Batasan yang Masih Terbuka

**Source basis:** GitHub `main` baseline `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle perubahan lokal 10 November dan status validasinya dicatat di `docs/STATUS-2026-11-10.md`.

Dokumen fase M0–M7 lama telah menjadi usang: banyak deliverable awal sudah ada di source dan diuji CI. Dokumen ini mengganti roadmap fase tersebut dengan backlog berbasis gap aktual. Laporan milestone bertanggal tetap disimpan sebagai histori.

## 1. Sudah tersedia pada source snapshot

| Area | Kondisi |
|---|---|
| Workspace, core agent loop, router, provider factory | Implemented |
| CLI setup/config/doctor/chat/daemon/approvals/skills/calc | Implemented |
| Web UI HTTP + WebSocket dan Flutter client | Implemented; validasi CI build/test tersedia |
| Memory SQLite FTS5 + JSON fallback, owner scope | Implemented; fallback degraded saat native SQLite tidak tersedia |
| MCP stdio dan Streamable HTTP | Implemented dengan batasan HTTP yang tercantum di AGD-03 |
| Skills scan, isolated golden evaluator, approval/metrics ledger | Implemented; feedback UI end-to-end belum lengkap |
| Scheduler IANA timezone, durable delivery acknowledgement/retry | Implemented; at-least-once delivery |
| Capability sempit resource-bound, circuit breaker single-probe, tier routing | Implemented |
| `agent_calc` M0/M1/M2/M3 | Implemented sesuai laporan; M3 task 21–23 berlabel inferensi |

## 2. Gap teknis yang terdokumentasi

Prioritas disarankan; bukan klaim bahwa semua item berikut merupakan release blocker.

| Prioritas | Gap | Kondisi/bukti | Kriteria penutupan |
|---|---|---|---|
| P1 | MCP HTTP server-initiated SSE GET | **Ditutup (C2, 2026-11-16):** request ber-ID dijawab opt-in `mcp.answer_server_requests` (hanya tool low-risk, concurrency/timeout/rate-limit handler); resume SSE via `Last-Event-ID`; test multi-event/reconnect/wiring ditambahkan | Tertutup; lihat `MCP-SERVER-REQUESTS-2026-11-16.md` |
| P1 | Antarmuka generatif (GenUI) | **Ditutup (D1, 2026-11-17):** DSL widget aman grammar-tertutup (7 tipe node, fail-closed ganda agen+klien), tool `render_ui` (risk low), transport blok ```genui di teks chat tanpa perubahan protokol, renderer Flutter lengkap (section/text/metric/chart bar-line/form/actions/divider); aksi/form dikirim balik sebagai pesan `/ui`; 27 test baru | Tertutup; lihat `GENUI-D1-2026-11-17.md`. Chart kaya (fl_chart) & handler `/ui` eksplisit di agentd = lanjutan |
| P1 | Memori asosiatif HDC | **Ditutup (D2, 2026-11-17):** hypervector biner 10.000 dim (XOR binding self-inverse, majority bundling tie→0 deterministik, rotasi permutasi, similarity Hamming) + encoder trigram Kanerva deterministik-seed + toko in-memory FIFO (maxEntries 1000) + tool `hdc_memory` (remember/recall/forget/stats, risk low); pure Dart tanpa dep baru (web-safe); 25 test baru | Tertutup; lihat `HDC-MEMORY-D2-2026-11-17.md`. Framing jujur: pelengkap asosiatif, bukan pengganti semantik; persistensi opsional = lanjutan |
| P1 | Self-correction loop untuk script (Wasm sandbox) | **Ditutup (D3, 2026-11-17):** tool `script_selfheal` (risk high, opt-in `script.self_repair`) — loop retry terbatas ≤3: script gagal → stderr/stdout ke LLM auxiliar → patch script lengkap → validasi fail-closed (kosong/oversize/identik ditolak, anti-loop) → eksekusi ulang di OS sandbox yang sama; audit trail per percobaan ke AuditLog; advisor parsing fail-closed (UNFIXABLE/fence terakhir); 24 test baru | Tertutup; lihat `SELF-CORRECTION-D3-2026-11-17.md`. Bagian Wasm tetap BLOCKED (belum ada dependency Wasm matang untuk Dart) — dilaporkan jujur, bukan dihitung selesai |
| P1 | Federated learning antar instance | **Ditutup (D5, 2026-11-17):** versi jujur "federated-lite" — tool `skill_share` (risk medium): export paket JSON skill tervalidasi (redaksi rahasia fail-closed dua arah, trust direset ke draft) + import dengan merge metrik CRDT LWW-Register; persist impor tanpa pernah menimpa skill lokal; 22 test baru | Tertutup; lihat `SKILL-SHARE-D5-2026-11-17.md`. FL sungguhan (gradient update/swarm otomatis/server agregasi) = BLOCKED (butuh infrastruktur) — dilaporkan jujur |
| P1 | Ebbinghaus memory compaction proaktif (LLM summarization) | **Ditutup (E2, 2026-11-17):** `IdleMemoryConsolidator` (opt-in `memory.idle_consolidation`, default false) — entri episodik retensi rendah (≤0.5) diringkas jadi fakta semantik via LLM auxiliar saat idle (hitung giliran ≥25, bukan timer); gerbang kandidat minimum, parsing fail-closed (NONE/baris tak valid dibuang), cap harian 6 panggilan LLM; entri asli tidak dihapus (decay/floor lama yang melupakan); 13 test baru | Tertutup; lihat `IDLE-CONSOLIDATION-E2-2026-11-17.md`. Klaim "background isolate / database tetap kecil selamanya" tidak dibuat — ringkasan LLM tanpa verifikasi fakta otomatis, dilaporkan jujur |
| P1 | Deteksi anomali token per skill ("Immune System") | **Ditutup (E1, 2026-11-17):** versi jujur "immune-lite" — `TokenAnomalyDetector` (baseline rolling mean+stddev per skill, dua lantai z-score 3.0 + rasio 3x anti false-positive baseline datar, cooldown 60 menit, fail-closed minSamples 5), wiring opt-in `security.token_anomaly` (default false) di jalur turn: event `security.token_anomaly` + AuditLog + karantina skill ke draft (cap harian 3, pola B4); 14 test baru | Tertutup; lihat `TOKEN-ANOMALY-E1-2026-11-17.md`. Klaim "agen keamanan otonom / self-healing tools otomatis" tidak dibuat — detektor ambang statistik yang melaporkan; penindakan lewat mekanisme approval/karantina yang sudah ada |
| P1 | Isolate swarm (konkurensi paralel) | **Ditutup (D4, 2026-11-17):** audit — tool batch paralel sudah tertutup `ParallelToolRunner` (filter parallelSafe + cancellation guard), beban CPU + hard-cancel sudah tertutup `CalcSandbox`; gap nyata ditutup: fan-out paralel terbatas RAG (retrieve multi-variant & ingest multi-chunk, `maxConcurrency` default 4, urutan/determinisme ranking terjaga, ekuivalensi + latensi dibuktikan test); 7 test baru | Tertutup; lihat `ISOLATE-SWARM-D4-2026-11-17.md`. Klaim "swarm puluhan micro-agent" tidak dibuat — fan-out terbatas yang terukur; IsolatePool tanpa pemanggil produksi didokumentasikan jujur |
| P1 | MCP HTTP protocol/security hardening | **Ditutup (C8, 2026-11-16):** OAuth kini ada — `McpOAuthTokenSource` dengan dua implementasi: `client_credentials` (lama, backward compatible) dan `authorization_code` + PKCE (login browser, discovery RFC 9728/8414, DCR RFC 7591, resource RFC 8707, refresh token, persistensi 0600 atomik, auth_method auto/basic/post/none). Protocol version config, header negosiasi, URL validation, bounded retry read-only sudah ada sebelumnya; request server-initiated ber-ID dijawab opt-in (C2) | Tertutup; lihat `MCP-OAUTH-AUTHCODE-2026-11-16.md`. Interop live vendor nyata tetap terbuka (butuh kredensial) |
| P1 | Unified provider health state | **Ditutup (C9, 2026-11-17):** audit lengkap — `breakerFor()` adapter di atas `ProviderHealth` yang identik dengan Router (verifikasi `identical()`), `auxiliaryLlm()` ter-wire di 3 titik produksi (subagent, reflection, synthesis/judge), semua pemanggilan LLM langsung tercakup (AgentLoop atau auxiliar terbungkus), tidak ada CircuitBreaker standalone divergen; regression concurrency 6 test (C3). API legacy dipertahankan (tidak ada counter divergen; permukaan resmi direct-use) | Tertutup; lihat `ROADMAP-CLOSURE-AUDIT-2026-11-17.md` |
| P1 | Flutter API error transparency | **Ditutup (C9, 2026-11-17):** kriteria terpenuhi — `_throwIf` pada admin GET, regression test 401/403/500/503 (C7, `token_encoding_test.dart`), dan CI menjalankan `flutter analyze` + `flutter test` (ci.yml) yang hijau di seluruh PR C3–C8 | Tertutup; lihat `ROADMAP-CLOSURE-AUDIT-2026-11-17.md` |
| P1 | Flutter WebSocket URL/token handling | **Ditutup (C5, 2026-11-16):** Implementasi URI/lifecycle dasar sudah ada; 6 test edge ditambahkan (karakter khusus round-trip, frame biner → error, ticket 401 → connect tanpa ticket, close mendadak, upgrade ditolak, timeout ready 10 s). Bug teardown ditemukan & diperbaiki: `sink.close()` kini bounded 5 s agar error upgrade tidak menggantung. Reconnect = retry eksplisit pengguna (by design) | Tertutup; lihat `FLUTTER-WS-EDGE-2026-11-16.md`. Perangkat nyata tetap terbuka |
| P1 | Email SMTP TLS, input validation dan timeout | Default CA/hostname verification; STARTTLS no-downgrade; AUTH butuh TLS; mailbox/header/DATA divalidasi; response timeout 10 detik dan transaksi 60 detik setelah connect | Fake SMTP tests termasuk stalled greeting dan stalled MAIL FROM ditambahkan; belum dieksekusi tanpa Dart SDK; live relay/certificate test terbuka |
| P1 | Inbound email gateway | **Ditutup (C4, 2026-11-16):** `ImapPoller` TLS-only + wiring agentd sudah ada di main; anti-replay dedup `Message-ID` (bounded cache 512), allowlist pengirim kini fail-closed (kosong = tolak semua), lifecycle test (poll gagal tidak mematikan loop, `stop()` idempotent) ditambahkan — test 6 → 11 | Tertutup; lihat `INBOUND-EMAIL-ANTI-REPLAY-2026-11-16.md`. Live relay/cert test butuh kredensial nyata |
| P1 | Feedback-to-skill loop | **Ditutup (C1, 2026-11-16):** `/feedback up\|down` tingkat turn + `POST /v1/sessions/<id>/feedback` (auth Bearer) mengarahkan 👍/👎 ke skill turn terakhir (metrik durabel) dan ke ledger self-evolution (reblend reward); audit + event `feedback.turn`/`evolution.feedback`. Pemetaan sesi→skill in-memory (hilang saat restart; feedback per-skill via slug tidak terpengaruh) | Tertutup; lihat `FEEDBACK-LOOP-2026-11-16.md` |
| P1 | Sandbox behavior pada Android/Termux | Deteksi sandbox host bersyarat; proot bukan OS isolation kuat | Dokumen hasil probe device, block risky execution tanpa sandbox, test physical device |
| P2 | Vector scale/performance | Runtime memakai brute-force vector index | Benchmark jumlah data realistis; putuskan sqlite-vec/alternatif hanya setelah Android compatibility test |
| P2 | Scheduler delivery exactly-once semantics | **Ditutup (C6, 2026-11-16):** `OutboundMessage.idempotencyKey` + `deliveryIdempotencyKey(jobId, runId)` deterministik; Matrix txnId dedup server-side sungguhan, Email Message-ID deterministik, agentd wiring. Bug QUIT tidak graceful (Broken pipe race) diperbaiki. Matriks duplicate-safe per platform didokumentasikan jujur | Tertutup; lihat `SCHEDULER-IDEMPOTENCY-2026-11-16.md`. Platform tanpa API idempotensi tetap at-least-once (review policy untuk anti-duplikat ketat) |
| P2 | Durable metrics consistency | **Ditutup (C7 audit, 2026-11-16):** row stale — `SkillMetricsLedger` flush per-event (rantai terserialisasi + tmp+rename atomik), `flushPendingSinks()` dipanggil saat shutdown (runtime + skill API), feedback wiring selesai di C1. Test: 7 metrik + 3 sink + durabilitas restart level runtime | Tertutup; bukti di `TOKEN-ENCODING-TESTS-2026-11-16.md` §row stale |
| P2 | API/Flutter token encoding and API failure handling | **Ditutup (C7, 2026-11-16):** 5 test baru — 401/403/500/503 surface sebagai exception berkoden, token CRLF (header injection) ditolak lokal tanpa sampai server, baseUrl malformed gagal terkendali, ID unicode/reserved ter-encode utuh, sendMessage unicode utuh via JSON | Tertutup; lihat `TOKEN-ENCODING-TESTS-2026-11-16.md`. Perangkat nyata tetap terbuka |
| P2 | Termux benchmark | `bench_isolate.dart` tersedia; pengukuran perangkat nyata belum direkam | Arsipkan p50/p95 pada device target dan versi Dart/Android |
| P2 | Kalkulator backlog TASK-CALC-24..35 | Definisi task asli tidak ada di repository | Pemilik menuliskan scope/DoD; jangan mengarang task turunan |
| P2 | Gateway real-world integration | CI memvalidasi code/mock, bukan credentials akun platform | Smoke nyata untuk setiap gateway sebelum menandai siap produksi |

## 2.1 Implementasi bundle lanjutan 10 November 2026

| Area | Perubahan | Status verifikasi |
|---|---|---|
| Provider health/fallback | `nextFallback` melakukan `tryAcquire`; primary dan fallback memakai single-probe slot; all-open fail-closed; AgentLoop menangani no-provider serta melepas slot pada jalur pra-eksekusi | Router tests ditambahkan; belum dijalankan dengan Dart SDK |
| SMTP timeout | Response timeout 10 detik, transaction deadline 60 detik, timeout pada read/flush/TLS, socket dihancurkan setelah gagal | Fake SMTP stall tests ditambahkan; belum dijalankan |
| MCP GET SSE | Optional GET SSE untuk notifikasi; request JSON-RPC ber-ID dicatat, belum dijawab; errors terpisah dari main POST path | Lifecycle test ditambahkan; belum dijalankan |
| MCP protocol/security | Typed `protocol_version`, header hasil negosiasi pada request lanjutan/GET/DELETE, URL user-info/fragment/control chars ditolak; retry transient terbatas untuk read-only request | Runtime config + HTTP lifecycle retry tests ditambahkan; belum dijalankan |
| Dokumentasi | README/index/status/roadmap/MCP/SMTP/manifest diperbarui ke baseline `dfa7a0e` dan membedakan bukti CI baseline dengan bundle lokal | Review tekstual; belum ada pipeline baru |

Bundle ini belum merupakan commit GitHub dan belum memiliki hasil CI. Operasi pembuatan branch melalui konektor GitHub ditolak dengan HTTP 403; perubahan disediakan dalam ZIP/patch untuk diterapkan di lingkungan pemilik repository. Jangan pindahkan status ke `Implemented/verified` sebelum `bash scripts/validate.sh` dan `bash scripts/flutter_validate.sh` lulus pada toolchain project.

## 3. Keputusan produk yang masih perlu pemilik

Pertanyaan target deployment utama (Termux, VPS, PC), provider cloud/lokal, dan kanal wajib menentukan urutan prioritas. Jangan mengaktifkan semua gateway dan provider sekaligus tanpa kredensial serta test integrasi.

## 4. Release checklist

- [ ] `dart pub get` berhasil dan lockfile ditinjau.
- [ ] `dart analyze --fatal-warnings` bersih untuk workspace; INFO lints tetap ditampilkan dan ditangani sebagai cleanup non-blocking.
- [ ] Test seluruh workspace member lulus.
- [ ] CLI setup/config/doctor/chat/calc smoke lulus.
- [ ] CLI, agentd dan agent_cli compile executable.
- [ ] Daemon lifecycle/API smoke lulus.
- [ ] Flutter analyze/test/web release build lulus.
- [ ] API token, secrets, allowlist, host bind, domain allowlist, MCP config dan sandbox ditinjau.
- [ ] Gateway eksternal diuji pada akun/endpoint nyata yang akan dipakai.
- [ ] Database/job/approval/session backup dan recovery diuji pada deployment target.
- [ ] Dokumentasi status diperbarui ke SHA commit release aktual.

## 5. Pencatatan perubahan

Selesaikan gap dengan commit kecil yang menyertakan test dan laporan. Jangan mengubah laporan historis agar seolah-olah laporan itu dibuat pada HEAD sekarang. Tambahkan status baru bertanggal, tautkan commit, test dan batasan yang belum selesai.
