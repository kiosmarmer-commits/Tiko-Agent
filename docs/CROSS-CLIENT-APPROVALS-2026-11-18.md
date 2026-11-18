# GUI-P0-06 — Cross-Client Approvals (2026-11-18)

Implementasi item **GUI-P0-06** dari laporan audit GUI eksternal: approval
dengan satu state bersama yang terlihat di semua client (web UI dan Flutter).

## Kondisi sebelum perubahan

- State approval memang sudah tunggal: `ApprovalBroker`
  (`packages/tiko_runtime/lib/src/approval_ledger.dart`) adalah ledger durable
  lintas-proses; web dan Flutter membaca/memutus requests yang sama via
  `GET /v1/approvals` dan `POST /v1/approvals/{id}`.
- Gateway sudah men-push semua runtime event (termasuk `approval.pending` dan
  `approval.decided`) ke semua client WebSocket.
- Gap: (1) setiap keputusan dicatat dengan aktor `api` — tidak bisa dibedakan
  dari client mana keputusan berasal; (2) web UI tidak me-refresh daftar
  approvals saat event approval masuk (hanya saat tab dibuka/tombol refresh);
  (3) Flutter tidak menampilkan indikator pending pada navigasi.

## Perubahan

### 1. Atribusi aktor lintas client

- `packages/agent_gateway/lib/src/http_api.dart`: callback `decideApproval`
  kini menerima `actor` opsional. Aktor diambil dari body `actor` atau header
  `x-tiko-actor`, disanitasi (`_sanitizeActor`: karakter kontrol dibuang,
  dipotong 64, kosong = null). Berlaku untuk `POST /v1/approvals/{id}`,
  `POST /v1/confirm`, dan frame WS `confirm_response`.
- `apps/agentd/bin/agentd.dart`: meneruskan aktor ke
  `rt.decideApproval(..., actor: actor ?? 'api')`.
- Web UI (`app.js`): mengirim `actor: 'web'`.
- Flutter (`agent_api_client.dart`): mengirim `actor: 'flutter'`.
- Ledger mencatat aktor tiap keputusan → audit "siapa memutuskan dari client
  mana" kini akurat.

### 2. Web UI: refresh event-driven

`watchEvents` (watcher WS yang selalu aktif) kini memicu `loadApprovals()`
(dengan debounce 250 ms via `refreshApprovalsFromEvents`) saat event
`approval.pending`/`approval.decided` masuk dan tab Approvals sedang terlihat
— pola yang sama dengan refresh otomatis tab Tasks pada event `job.*`.
Keputusan dari client lain langsung terlihat tanpa memuat ulang manual.

### 3. Flutter: badge pending di navigasi

`DesktopShell` dan `MobileShell` menerima `pendingApprovals` dan menampilkan
badge Material `Badge` pada destinasi Approvals bila > 0; `main.dart`
menghitungnya dari `approvals.where((a) => a.isPending).length`.

## Yang TIDAK termasuk (jujur)

- Flutter tidak menerima push approval event: stream WS chat hanya hidup saat
  mengirim pesan; refresh admin tetap polling 15 detik + on-action. Push
  global (watcher WS permanen seperti web) menyusul bila diperlukan.
- Halaman Security & Approval Center penuh (kolom expiry, affected
  files/host, policy) masih backlog P1; iterasi ini fokus pada state lintas
  client.
- Aktor disanitasi, bukan diautentikasi per-client — sebuah client bisa
  mengirim nilai aktor apa pun; ini atribusi audit, bukan kontrol akses
  (autentikasi token tetap gerbang aslinya).

## Test

- Gateway (`packages/agent_gateway/test/http_api_approval_test.dart`): aktor
  dari body diteruskan, fallback header, sanitasi (kontrol/trim/64/ kosong),
  dan frame legacy `/v1/confirm` dengan aktor.
- Web (`apps/agentd/web/app.test.cjs`): keputusan mengirim `actor: 'web'`;
  event `approval.decided`/`approval.pending` memicu reload daftar saat tab
  aktif dan diabaikan saat tab tidak aktif. Harness diperbaiki: elemen section
  tab kini tersedia via `$('#tab-x')`, timer opsional-sinkron.
- Flutter (`agent_repository_test.dart`): `decideApproval` mengirim
  `actor: 'flutter'`. (`app_shell_test.dart`): badge tampil/tidak pada kedua
  shell.

## Verifikasi

- `node --check apps/agentd/web/app.js` ✓; `node --test apps/agentd/web/app.test.cjs` 8/8 ✓.
- Dart/Flutter tidak tersedia di lingkungan penyusunan — verifikasi lanjutan
  via CI (analyze/test/build).
