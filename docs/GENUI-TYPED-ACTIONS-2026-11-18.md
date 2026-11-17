# GUI-P0-04: Typed GenUI Actions (`/v1/ui/actions`) — 2026-11-18

## Ringkasan

Implementasi item **GUI-P0-04** dari audit GUI `TIKO-AGENT-GUI-REPORT.md`.
Sebelumnya renderer GenUI mengirim action/form sebagai teks bebas
`/ui <action-id> <json>` langsung ke agent loop — tidak ada validasi
server-side (temuan audit: `apps/agent_flutter/lib/main.dart:455`, nol handler
`/ui` di backend). Kini aksi melewati endpoint typed yang tervalidasi.

## Desain

### Registry per sesi (`agent_core`, `genui_actions.dart`)

- `GenUiActionRegistry.register(sessionKey, spec)` — memindai node
  `actions`/`form` (termasuk di dalam `section.children`) dari spesifikasi
  GenUI hasil `render_ui`, mendaftarkan tiap action id dengan expiry.
- `validateAndConsume(sessionKey, actionId, values)` — fail-closed:
  - **Ownership**: action id hanya valid untuk sesi yang menerima spesifikasinya;
  - **Expiry**: TTL 15 menit sejak dirender;
  - **Single-use**: aksi terkonsumsi sekali (anti-replay); render ulang id
    yang sama (latest wins) mengaktifkan ulang;
  - **Validasi nilai**: field tak dikenal ditolak; `number` harus numerik;
    `select` harus salah satu opsi; tombol polos menolak nilai form.
  - Pelanggaran melempar `GenUiActionRejected`.

### Endpoint (`agent_gateway`)

- `POST /v1/ui/actions` body `{session_key, action_id, values}`:
  - handler tidak dikonfigurasi → 501;
  - session_key kosong/terlalu panjang atau action id di luar format aman
    `[A-Za-z0-9_.-]{1,64}` → 400;
  - `GenUiActionRejected` → 400 `{ok:false, error}`;
  - valid → diteruskan ke agent loop sebagai turn `/ui <id> <json>` dan
    dijawab `{ok:true, text:<balasan agen>}`.

### agentd

- Reply chat HTTP/WS (jalur `httpMessage`) kini dipindai
  `extractGenUiBlocks`; setiap blok valid didaftarkan ke registry untuk
  `sessionKey` pemanggil — mencakup `POST /v1/messages` dan `/v1/stream`.
- `uiActionHandler` memvalidasi lewat registry baru meneruskan aksi.

### Flutter (`agent_flutter`)

- `AgentApiClient.submitUiAction()` — POST typed.
- `ChatController.sendUiAction()` — bubble user+assistant seperti chat biasa;
  **fallback otomatis** ke jalur teks `/ui ...` hanya bila daemon menjawab 501
  (daemon lama); kegagalan lain tampil sebagai pesan system **tanpa
  pengiriman ulang** (menghindari side effect ganda — konsisten dengan
  kebijakan no-auto-retry ChatController).
- `main.dart` `onAction` kini memanggil `chat.sendUiAction(...)`.

## Batasan jujur

- Turn yang diteruskan ke agent loop tetap berformat teks `/ui ...` (agent
  loop belum punya channel aksi biner); yang berubah adalah validasi
  server-side ketat sebelum diteruskan.
- Web UI `agentd/web` belum memakai endpoint ini (belum merender GenUI).
- Expiry/singleton state hidup di memori daemon — restart daemon
  mengosongkan registry (aksi lama ditolak; pengguna render ulang).

## Test

- `packages/agent_core/test/genui_actions_test.dart` — 8 test: single-use,
  ownership, expiry, re-render latest-wins, validasi form (field tak dikenal,
  number, select), tombol menolak nilai, registrasi dari blok ```genui.
- `packages/agent_gateway/test/http_api_ui_actions_test.dart` — 6 test:
  forwarding, id tidak aman 400, session kosong 400, rejected → 400, 501,
  auth.
- `apps/agent_flutter/test/ui_action_test.dart` — 3 test: sukses typed,
  fallback 501 → jalur teks, ditolak 400 → pesan system tanpa resend.
