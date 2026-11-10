# Tiko Agent — Implementation Bundle (10 November 2026)

## Baseline dan validasi

- Repository: `kiosmarmer-commits/Tiko-Agent`, branch `main`.
- Baseline source: `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`.
- GitHub Actions run `42687414796` sukses 2/2 untuk baseline. Run tersebut **tidak** menguji perubahan bundle ini.
- Perubahan bundle belum dikirim ke GitHub; operasi pembuatan branch melalui konektor menghasilkan HTTP 403.
- Dart/Flutter SDK tidak tersedia pada lingkungan penyusunan; `dart format`, `dart analyze`, Dart tests, Flutter tests dan Web build belum dijalankan untuk bundle ini.
- Pemeriksaan non-SDK: seluruh `bash -n scripts/*.sh`, Python `compileall`, `node --check apps/agentd/web/app.js`, YAML 24 file, JSON 3 file, serta `scripts/web_ui_validate.sh` 3/3 PASS.

## Implementasi baru

1. Provider Router: fallback mengambil half-open probe slot, all-open fail-closed (`NoHealthyProviderException`), AgentLoop menangani kondisi availability dan melepas slot ketika request provider belum dimulai.
2. SMTP: response timeout (default 10s), transaction deadline (default 60s setelah TCP connect), monotonic deadline, timeout pada socket flush/TLS handshake dan cleanup socket.
3. MCP Streamable HTTP: optional GET SSE, notifikasi server disalurkan melalui stream, server JSON-RPC request ber-ID diobservasi tetapi belum dieksekusi/dijawab; SSE event dibatasi 256 KiB default dan observasi dibatasi 100 entri.
4. MCP protocol version: typed config `protocol_version`, default `2025-11-25`, versi hasil initialize dikirim via header pada request lanjutan, GET dan DELETE; nilai versi hasil initialize yang malformed ditolak.
5. MCP endpoint validation: URL credentials/user-info, fragment, whitespace/control chars ditolak; admin-configured internal URL tetap tidak melalui SSRF guard. Retry dibatasi ke read-only JSON-RPC methods, maksimal 2 percobaan ulang default untuk network exception/status transient; nilai dapat diatur per server melalui `max_read_retries: 0..3`. `tools/call`/notifications tidak di-retry.
6. Regression tests: provider fallback/health, stalled SMTP greeting/response, MCP GET SSE/session/protocol header, oversized SSE event drop, bounded retry read-only versus non-retry `tools/call`, unsafe custom-header rejection, MCP config version/retry count/header validation dan URL validation.
7. Dokumentasi diperbarui: README, index, status, roadmap, P1 robustness, MCP guide, SMTP guide, CI incident note dan manifest.

## Batasan yang tersisa

- Skill feedback endpoint/UI end-to-end belum dibuat.
- Email inbound belum memiliki IMAP/POP/SMTP receiver.
- Android scaffold/native APK CI belum tersedia.
- MCP GET reconnect/resume dan JSON-RPC server-request handling belum selesai; OAuth registration tidak tersedia. Retry untuk `tools/call` sengaja tidak diterapkan tanpa idempotency contract.
- MCP HTTP URL tetap admin-trusted; SSRF/DNS rebinding guard belum diterapkan.
- Integrasi kredensial vendor, live SMTP relay/certificate, MCP eksternal dan pengujian perangkat fisik/Termux belum dilakukan.

## Validasi yang harus dilakukan setelah menerapkan ZIP

```bash
dart pub get
bash scripts/validate.sh
bash scripts/flutter_validate.sh
```

Jika gate gagal, perbaiki kegagalan pertama, format ulang file Dart yang berubah, lalu jalankan seluruh gate lagi. Jangan menganggap baseline CI hijau sebagai bukti bundle ini telah lolos.
