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
| P1 | MCP HTTP server-initiated SSE GET | GET SSE opsional sudah terhubung untuk notifikasi; request ber-ID hanya dicatat dan belum dijawab; reconnect/resume belum ada | Test multi-event/reconnect dan desain handler JSON-RPC server request yang terautentikasi/terbatas |
| P1 | MCP HTTP protocol/security hardening | `protocol_version` dapat dikonfigurasi; header hasil negosiasi dikirim pada POST/GET/DELETE; URL user-info/fragment/control chars ditolak; bounded retry hanya read-only method. Static SecretRef auth; admin URL tidak melewati `SsrfGuard`; OAuth tidak ada | Batasi akses konfigurasi/egress, uji server interop dan lifecycle; rancang OAuth bila dibutuhkan. Request server-initiated ber-ID masih perlu handler yang dibatasi |
| P1 | Unified provider health state | Runtime memakai `Router.ProviderHealth` untuk primary dan fallback; provider `CircuitBreaker`/`BreakerLlmProvider` hanya API legacy dan tidak di-wire runtime. Semua-open kini fail-closed | Regression concurrency test dan CI; hapus/deprecate API legacy hanya setelah audit consumer eksternal |
| P1 | Flutter API error transparency | Admin GET kini memakai `_throwIf`; HTTP 401/403/5xx tidak lagi disamarkan sebagai data kosong | Regression test 401 ditambahkan; jalankan Flutter test/analyze pada CI |
| P1 | Flutter WebSocket URL/token handling | `Uri.queryParameters` untuk token, `Uri.encodeComponent` untuk ID delete/approval, sink ditutup pada cancel | Implementasi URI/lifecycle dasar sudah ada; uji karakter khusus, reconnect, timeout dan perangkat nyata |
| P1 | Email SMTP TLS, input validation dan timeout | Default CA/hostname verification; STARTTLS no-downgrade; AUTH butuh TLS; mailbox/header/DATA divalidasi; response timeout 10 detik dan transaksi 60 detik setelah connect | Fake SMTP tests termasuk stalled greeting dan stalled MAIL FROM ditambahkan; belum dieksekusi tanpa Dart SDK; live relay/certificate test terbuka |
| P1 | Inbound email gateway | `EmailGateway.pushInbound()` ada sebagai hook tetapi agentd belum memiliki IMAP/POP/SMTP receiver/poller | Implementasikan receiver aman, autentikasi, allowlist sender, anti-replay dan lifecycle/shutdown test |
| P1 | Feedback-to-skill loop | Ledger punya feedback count/sink; feedback belum dipanggil otomatis menyeluruh dari UI/chat | Endpoint/UI feedback dengan auth, ownership, audit dan test end-to-end |
| P1 | Sandbox behavior pada Android/Termux | Deteksi sandbox host bersyarat; proot bukan OS isolation kuat | Dokumen hasil probe device, block risky execution tanpa sandbox, test physical device |
| P2 | Vector scale/performance | Runtime memakai brute-force vector index | Benchmark jumlah data realistis; putuskan sqlite-vec/alternatif hanya setelah Android compatibility test |
| P2 | Scheduler delivery exactly-once semantics | Saat ini at-least-once; crash send/ack bisa duplikasi | Idempotency key/channel support atau dokumentasi UX duplicate-safe |
| P2 | Durable metrics consistency | Skill usage sink fire-and-forget; crash dapat kehilangan event terakhir | Batch/flush durability bila metrik menjadi basis kebijakan; feedback wiring |
| P2 | API/Flutter token encoding and API failure handling | Area client security/reliability yang layak diuji | Test malformed URL, unicode, token khusus, 401/403/5xx |
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
