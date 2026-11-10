# 07 — Keamanan dan Observabilitas

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be`.

## 1. Prinsip

- Mode normal daemon safe: kecuali `--no-safe` diberikan, safe mode diaktifkan.
- Default config `security.mode: ask`; konfigurasi `auto` diberi warning dan bukan rekomendasi default.
- PermissionGate adalah otoritas izin; keputusan LLM/DecisionProvider tidak menggantikan gate.
- Output yang memuat konten workspace (file/list/grep/probe/shell), browser, web, HTTP, MCP dan script diperlakukan sebagai data tak tepercaya di dalam envelope; konten tersebut tidak boleh mengubah instruksi sistem atau menaikkan permission. Session taint untuk approval tambahan hanya dipicu oleh sumber eksternal, bukan sekadar membaca file workspace.
- Secret hanya melalui environment/secure storage; jangan mencatat credential mentah.

## 2. Approval dan single source of truth

`ApprovalBroker` adalah sumber keputusan approval daemon. ID yang sama dipakai CLI, REST, WebSocket, Flutter dan Telegram approval flow. Hanya transisi `pending` yang dapat diputuskan; request memiliki expiry dan approval terlambat/replay ditolak. CLI `tiko approve`, `tiko deny`, `tiko approvals` berbicara ke daemon aktif, bukan membuat broker in-memory tandingan.

API token disimpan di `data/api.token`, dengan POSIX permission `0600`; token tidak dicetak ke log. Token minimal 128-bit/32 karakter. Default API bind `127.0.0.1`; akses remote perlu TLS/reverse proxy, firewall dan kebijakan Origin/rate yang tepat. `/health` terbuka, endpoint `/v1/*` memerlukan auth.

## 3. Capability tokens yang terikat resource

`CapabilityToken` mengikat izin pada:

- operasi spesifik tool: `shell → exec`, `write_file → write`, `patch_file → patch`, `http_request`/`web_fetch → fetch`;
- path file absolut yang disetujui untuk `write_file`/`patch_file`, bukan seluruh workspace;
- host/domain tepat dari URL untuk `http_request`/`web_fetch`;
- fingerprint argumen, session ID, expiry, single-use dan batas payload (default `102400` byte).

Token capability dikonsumsi oleh gate dan `_capability_id` dibuang sebelum args diteruskan ke adapter/audit trace. Kompatibilitas token lama `execute` diberi masa berlaku normal; jangan membuat token baru generik untuk operasi sensitif.

## 4. Tool dan network security

| Ancaman | Mitigasi/source |
|---|---|
| Prompt injection web/file/MCP/workspace | `untrusted_data` envelope; sumber eksternal menambah session taint dan permission re-check; output workspace tetap diisolasi tanpa memaksa approval tambahan pada setiap medium-risk tool |
| Shell command berbahaya | safe mode, allowlist, confirmation, sandbox runner dan bounded output/timeout |
| File path escape | workspace root/path validation pada file adapters; capability exact-path untuk approval writes |
| SSRF | `SsrfGuard` melakukan DNS/IP screening, block loopback/private/link-local/reserved dan pinned connection untuk tool fetch/request. **Pengecualian:** MCP HTTP URL admin-configured saat ini tidak melewati `SsrfGuard`; batasi hak edit config dan review URL secara manual |
| MCP tool spoof/malformed schema | MCP server allowlist, schema/name validation, bounded count/output, risk gate |
| Secret leakage | SecretRef `env:VAR`, redaction, API token file permission |
| Runaway/abuse | budget guard, rate limiter, loop detector, scheduler limits |
| Duplicate sessions | FileSessionStore cross-process lock + refresh-under-lock |
| Delivery loss | durable pending delivery + acknowledgement/retry; at-least-once limitation |

### Trust classification yang dipakai runtime

- **External taint:** `web_fetch`, `web_search`, `http_request`, `cdp_browser`, `mcp_*`, dan `script_*`. Output sukses dari kelompok ini menandai session, sehingga tool medium+ berikutnya perlu melewati konfirmasi tambahan sesuai `MatrixPermissionGate`.
- **Workspace untrusted envelope:** `read_file`, `list_dir`, `grep`, `probe`, dan `shell`. Output tetap dibungkus dan dinetralisasi sebagai data, tetapi tidak menaikkan external session taint hanya karena file dibaca.
- **Other trusted output:** misalnya `datetime`/`calc` tetap melewati redaksi secret, tetapi tidak otomatis dibungkus sebagai untrusted.

Klasifikasi ini mengurangi over-confirmation tanpa menganggap isi file lokal sebagai instruksi tepercaya. Tool berisiko seperti shell/write/patch tetap memiliki risk level dan confirmation policy sendiri. Perubahan pada daftar klasifikasi harus disertai regression test di `agent_core` dan `agent_security`.

## 5. Sandbox host

`SandboxRunner.detect()` mengenali `bubblewrap`, Docker, SSH atau none. Script tool loading dan MCP child process bergantung sandbox yang dapat digunakan. Keberadaan `SandboxRunner` tidak dengan sendirinya membuktikan isolasi OS aktif. Pada `none`, host tidak memiliki batas OS tambahan dari runner. Termux/proot tidak boleh dianggap isolasi kuat. Untuk tool berisiko, pilih host dengan sandbox, jalankan sebagai user terbatas, dan tetap wajibkan permission/confirmation.

Tool forge menjalankan contract tests sebelum tool dipasang; fail-closed bila sandbox test tidak tersedia. Test ini tidak membuktikan keamanan implementasi tool terhadap semua input adversarial.

## 6. Logging/diagnostics

Runtime memiliki audit log, events, provider health/fallback snapshot, resource monitor, status/capabilities/doctor API. Gunakan `tiko doctor`, `tiko doctor --probe`, `tiko route explain --task "..."`, dan endpoint status untuk diagnosis. Audit/event log harus menghindari secret dan payload sensitif; jangan mengaktifkan prompt-level debug pada produksi tanpa redaksi dan kontrol akses.

## 7. Release security checks

Sebelum rilis pada host nyata, verifikasi setidaknya:

1. API tanpa token ditolak selain `/health`.
2. Approval pending hanya dapat disetujui sekali dan kedaluwarsa ditolak.
3. Capability tool A tidak dapat dipakai untuk tool/path/domain lain, payload melebihi limit ditolak.
4. SSRF blok loopback, private, link-local, metadata dan redirect ke alamat terlarang.
5. Shell/script/MCP tanpa sandbox atau allowlist tidak berjalan.
6. Skill baru tidak aktif sebelum isolated golden evaluation + approval; edit skill membatalkan fingerprint approval.
7. Secret tidak masuk Git, audit log, memory ataupun chat output.
8. Scheduler retry tidak menjalankan ulang agent turn dan tidak mengirim silang ke gateway lain.

CI mencakup static analysis/test suites; uji penetrasi dan konfigurasi akun eksternal di host deployment tetap pekerjaan rilis.
