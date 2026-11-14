# Security Hardening — 14 Bug dari Audit Eksternal (15 November 2026)

Dokumen ini mencatat verifikasi dan perbaikan seluruh temuan audit eksternal
`Qwen-tikoaudit15nov26` (snapshot `9b9b822`). Semua perbaikan diverifikasi
dengan test baru dan `dart analyze --fatal-warnings` bersih.

## Ringkasan per Bug

| ID | Severity | Perbaikan | Commit fokus |
|---|---|---|---|
| B-01 | 🔴 kritis | `SecretStore` XOR-LCG diganti XChaCha20-Poly1305 + Argon2id (paket `cryptography`, pola sama dengan `simpul_core/vault_crypto.dart`). Format file v2 `TSS2|salt|nonce|cipher|mac`, tulis atomik + chmod 600, migrasi otomatis dari format legacy XOR, MAC mismatch → `SecretStoreException`. | `fix(security): B-01` |
| B-02 | 🔴 kritis | `CredentialManager._save()`: tulis atomik (tmp + rename), chmod 600 wajib (gagal → error ke pemanggil, tidak lagi `catch (e) {}`), `initialize()` memperketat permission file lama yang longgar. | `fix(security): B-02/B-11` |
| B-03 | 🔴 kritis | `ApiServer._validateAuth`: fail-closed (tanpa token dikonfigurasi → token acak CSPRNG 32 byte digenerate, tersedia via `effectiveAuthToken`; request tanpa token selalu 401) + perbandingan constant-time. | `fix(security): B-03..B-06` |
| B-04 | 🔴 kritis | `ApiServer`: body dibaca dengan batas keras `maxRequestSize` → 413; `corsOrigins` kini ditegakkan (hanya origin terdaftar/`*` yang menerima ACAO + `Vary: Origin`). | `fix(security): B-03..B-06` |
| B-05 | 🟡 | `ApiServer.start()` tidak lagi memblokir di `await for`; accept-loop pindah ke `_server.listen` dan `onStart` dipanggil **sebelum** request pertama dilayani. `stop()` membatalkan subscription lalu menutup server. | `fix(security): B-03..B-06` |
| B-06 | 🟡 | `HttpServer.bind(shared: false)` — proses lain tidak bisa membajak port. | `fix(security): B-03..B-06` |
| B-07 | 🔴 tinggi | `web_search` fetch halaman memakai `IOClient(ssrf.pinnedHttpClient())` (pinning DNS per-connection) + redirect manual dengan re-check `checkUrl` tiap hop (maks `ssrf.maxRedirects`), konsisten dengan `web_fetch`. | `fix(security): B-07` |
| B-08 | 🟡 | `HttpApiServer`: token via query `?token=` dihapus (Bearer + constant-time saja); WebSocket `/v1/stream` memakai ticket sekali pakai TTL 30 detik dari `POST /v1/auth/ticket`; validasi Host (421 untuk host asing); `Access-Control-Allow-Origin: *` dihapus. Web UI `app.js` ikut dimigrasi ke alur ticket. | `fix(security): B-08` |
| B-09 | 🟡 | Workspace jail `ShellTool`: nilai flag (`--file=/etc/passwd`) ikut diperiksa; semua argumen path-like diresolusi kanonik via `PathSafety.resolveInRoot` (symlink-aware, fail-closed), bukan scan `..` leksikal. | `fix(security): B-09` |
| B-10 | 🟢 | `agent_loop`: deteksi kegagalan provider hanya via `finishReason == 'error'` (disetel `LlmError`/exception); heuristik substring `'[error]'` dihapus sehingga jawaban sah yang mengandung teks tersebut tidak lagi memicu fallback. | `fix(reliability): B-10` |
| B-11 | 🟢 | ID eksekusi `code_execution` dan ID kredensial memakai CSPRNG (`Random.secure()`); ID kredensial kini hex 32 char. Temuan audit sebenarnya *understated*: `_randomString` lama memakai satu nilai `DateTime.now()` sehingga 8 karakternya identik. | `fix(security): B-02/B-11`, `fix(security): B-11` |
| B-12 | 🟢 | `scripts/__pycache__/`, `tools/mock_mcp_server/__pycache__/`, `data/agent.db` dihapus dari git; `.gitignore` ditambah `__pycache__/`, `*.pyc`, `data/*.db*`. | `chore(repo): B-12` |
| B-13 | 🟢 | Skrip legacy repair-bundle (`apply.sh`, `apply_ci_fix_bundle.sh`, `apply_continue.sh`, `apply_flutter_ui_repairs.py`) dipindah ke `archive/repair-bundle-2026-11/` dengan README peringatan. | `chore(repo): B-13` |
| B-14 | 🟡 | `PromptGuard`: normalisasi input (zero-width strip + fold whitespace); blob base64 di-decode dan plaintext di-scan ulang — blokir hanya bila hasil decode cocok rule lain (`PI-005-decoded`, critical), blob polos turun ke severity low; rule baru PI-007 (override instruksi Bahasa Indonesia), PI-008 (instruksi eksfiltrasi), PI-009 (baris `system:` palsu). Korpus eval diperbarui mengikuti kontrak baru. | `fix(security): B-14` |

## Test baru

- `packages/agent_security/test/secret_store_test.dart` — roundtrip, no-plaintext, salt unik, tamper MAC, passphrase salah, chmod 600, migrasi legacy.
- `packages/agent_security/test/credential_manager_test.dart` — persist/roundtrip, chmod 600, tighten permission lama, kegagalan simpan tidak ditelan, ID CSPRNG unik.
- `packages/agent_tools/test/api_server_test.dart` — auth 401/fail-closed, 413 body cap, CORS allowlist, urutan onStart, non-blocking start/stop, shared:false.
- `packages/agent_gateway/test/http_api_auth_test.dart` — query token ditolak, Bearer OK, Host asing 421, ticket sekali pakai (replay ditolak).
- `packages/agent_tools/test/shell_jail_test.dart` — kasus baru flag-value, flag boolean lolos, symlink keluar workspace.
- `packages/agent_security/test/prompt_guard_test.dart` — blob base64 polos tidak memblokir, blob berisi injeksi diblokir, PI-007, evasian zero-width.

## Perubahan kontrak yang perlu diketahui

1. **`/v1/stream`**: klien browser wajib memakai alur ticket (`POST /v1/auth/ticket`
   dengan Bearer → `?ticket=`); klien non-browser tetap bisa memakai header Bearer.
2. **`ApiServer` tanpa `authToken`**: token acak digenerate saat `start()` dan
   tersedia via `effectiveAuthToken` — endpoint ber-auth tidak pernah terbuka.
3. **File secret/kredensial**: format baru tidak bisa dibaca implementasi lama;
   `SecretStore` melakukan migrasi otomatis sekali, `CredentialManager` menulis
   ulang pada simpanan pertama.
4. **PI-005**: blob base64 polos kini hanya `sanitize` (severity low, medium
   untuk provenance tak tepercaya), bukan blok. Blob yang terdekode menjadi
   konten injeksi diblokir dari provenance mana pun.

## Verifikasi

- `dart analyze --fatal-warnings` bersih di seluruh workspace.
- `dart test` hijau di semua paket yang berubah (agent_security, agent_tools, agent_gateway, agent_core).
- `node --check apps/agentd/web/app.js` bersih setelah migrasi ticket.
