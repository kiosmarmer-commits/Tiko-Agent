# GUI Web Parity: Bots, Provider, Plugin, Channels — 2026-11-18

Parity UI web (`apps/agentd/web/` — UI yang dilayani `agentd --api` di
`http://127.0.0.1:<port>/`) untuk empat milestone Flutter GUI yang
sebelumnya hanya ada di aplikasi desktop/mobile: **GUI-P1-04 (Bots)**,
**GUI-P1-05 (Provider manager)**, **GUI-P1-06 (Plugin & tools manager)**,
dan **GUI-P1-07 (Channels)**. Empat tab baru — **Bots, Provider, Plugin,
Channels** — ditambahkan setelah tab Tugas, sebelum Bantuan.

Prinsip jujur tetap dipakai: seluruh tab hanya memakai endpoint REST yang
benar-benar sudah ada di `apps/agent_gateway/lib/src/http_api.dart`
(`GET /v1/plugins`, `GET /v1/channels`, dst.); tidak ada kontrol untuk
aksi yang belum punya backend, dan karakter error `501 not_implemented`
(tanpa callback) ditampilkan apa adanya.

## 1. Tab Bots (GUI-P1-04 parity)

- Daftar bot (`GET /v1/bots`): id + nama, persona, model, dan tool
  allowlist (kosong ditandai "fail-closed").
- **Hapus** bot: `DELETE /v1/bots/:id` (tombol ter-disable selama request).
- Binding sesi (`GET /v1/bots/bindings`): daftar `session → bot`.
- Form **Bind/Unbind** sesi: `POST /v1/bots/:id/bind|unbind`
  (body `{session_id}`).
- Form **Buat bot**: `POST /v1/bots` — id, nama, persona, model (opsional
  → `null`), greeting, tool allowlist (dipisah koma) — payload persis
  `_botCreateKeys` gateway (field lain ditolak 400 oleh backend).

## 2. Tab Provider (GUI-P1-05 parity)

- Snapshot routing (`GET /v1/providers`): default, provider terdaftar
  dengan capability (tool_calling/vision/streaming/max_context), health,
  tiers, dan override sesi aktif — read-only.
- **Override provider per sesi**: `POST /v1/providers/session`
  (`{session_id, provider}`; "default" untuk reset) — satu-satunya mutasi
  provider yang sah saat daemon hidup.
- Caption jujur: mengubah default = ubah file config + restart.

## 3. Tab Plugin & tools (GUI-P1-06 parity)

- Snapshot (`GET /v1/plugins`): plugin (registered/pending + granted),
  katalog tool registry (nama, risk, timeout, parallel-safe), status
  server MCP (`mcp.loader`).
- **Consent grant/revoke**: `POST /v1/plugins/consent`
  (`{plugin, action}`) — plugin belum pending ditolak 404 oleh backend.

## 4. Tab Channels (GUI-P1-07 parity)

- Snapshot (`GET /v1/channels`) — **read-only**: badge aktif/nonaktif per
  channel gateway + daftar **nama** env yang mengaturnya; nilai rahasia
  tidak pernah dikirim backend.
- Kartu setup: env + restart; tidak ada on/off channel runtime
  (config immutable).

## Test

- `apps/agentd/web/app.test.cjs` (+5 test, total 13) — harness DOM fake
  yang sudah ada diperluas (id baru, tab/section baru, mock fetch):
  - Bots: muat list + binding, render aman via textContent (payload mock
    mengandung HTML berbahaya dan diassert tetap teks), aksi hapus →
    DELETE `/v1/bots/:id`.
  - Buat bot + bind/unbind: payload POST persis (allowlist split koma,
    model kosong → `null`).
  - Provider: snapshot render + override POST `/v1/providers/session`.
  - Plugin: snapshot + consent POST `/v1/plugins/consent` (grant).
  - Channels: badge `pill online/offline` + nama env.
- Verifikasi lokal: `node --check apps/agentd/web/app.js` OK;
  `node --test apps/agentd/web/app.test.cjs` → 13 pass. CI menjalankan
  kedua perintah ini via `scripts/web_ui_validate.sh`.

## Yang TIDAK termasuk (jujur)

- **Edit persona/model bot via form PATCH**: allowed, tapi UI web hanya
  menyediakan create + delete + bind/unbind (edit masih via Flutter/CLI) —
  backend PATCH `/v1/bots/:id` sudah ada.
- **On/off channel & edit config daemon**: env + restart tetap satu-satunya
  jalur (config immutable).
- **Kredensial**: token tetap sessionStorage per-tab (GUI-P0-05), tidak
  dipersist.
- **Modify tool risk / uninstall plugin / MCP**: tidak ada endpoint-nya —
  tidak dibuat.
