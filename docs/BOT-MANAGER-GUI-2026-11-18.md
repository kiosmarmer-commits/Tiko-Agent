# GUI-P1-04: Bot/Agent Manager Flutter — 2026-11-18

Implementasi item **GUI-P1-04** (Bot/Agent Manager) dari backlog audit GUI
(`TIKO-AGENT-GUI-REPORT.md` §11 P1): CRUD profil bot persisten (BotStore di
`tiko_runtime`) + binding/unbinding sesi ke bot, semuanya lewat GUI tanpa
command `/bot`. Sebelumnya `/bot` hanya bisa diakses via chat command — audit
menandai ini sebagai fitur yang butuh REST API + GUI.

## 1. Backend REST API (baru)

- `packages/tiko_runtime/lib/src/bot_mode.dart`: accessor baru
  `BotStore.bindings()` → `Map<String, String>` unmodifiable
  (id sesi → id bot) untuk kebutuhan read API.
- `packages/agent_gateway/lib/src/http_api.dart`:
  - Exception typed `ApiRequestException(status, code, message)` — dilempar
    callback wiring untuk memetakan kegagalan domain (conflict, dsb.) ke
    respons `_error` typed alih-alih 500 generik. Ditangkap oleh handler
    top-level sebelum `catch` generik.
  - 8 callback opsional di `HttpApiServer`: `listBots`, `getBot`,
    `createBot`, `updateBot`, `deleteBot`, `listBotBindings`, `bindBot`,
    `unbindBot`. Callback null → `501 not_implemented`.
  - **Endpoints**:
    - `GET /v1/bots` → `{bots: [...]}` (toJson BotProfile, snake_case).
    - `POST /v1/bots` → `201` + profil; `409 conflict` bila id sudah ada;
      `400 invalid_request` bila body/field tidak valid.
    - `GET /v1/bots/bindings` → `{bindings: {...}}` (dicek sebelum
      `/v1/bots/{id}`).
    - `GET /v1/bots/{id}` → profil atau `404`.
    - `PATCH /v1/bots/{id}` → update subset (`name`, `persona`, `model`,
      `greeting`, `tool_allowlist`); `model: null` menghapus model
      (`clearModel`); `404` bila bot tidak ada.
    - `DELETE /v1/bots/{id}` → `{deleted: true}` atau `404`.
    - `POST /v1/bots/{id}/bind` body `{session_id}` → `{ok: true, bound: true}`.
    - `POST /v1/bots/{id}/unbind` body `{session_id}` → `404` bila binding
      tidak cocok.
  - **Validasi** `_validateBotPayload`: id wajib cocok pola
    `^[a-z0-9][a-z0-9_-]{0,63}$` (mirror `BotProfile.isValidId`), name wajib
    string non-kosong maks 128, `model` string/null, `persona`/`greeting`
    string, `tool_allowlist` daftar string, field di luar whitelist →
    `400 invalid_request`.
- `apps/agentd/bin/agentd.dart`: pasang ke-8 callback di atas `rt.botStore`
  (yang sama dengan command `/bot` di chat) — create cek duplikat →
  `ApiRequestException(409, 'conflict', ...)`; update pakai `copyWith` +
  `clearModel` bila `model: null`; delete/bind/unbind cek keberadaan dan
  kecocokan binding dulu.

## 2. Data layer Flutter (typed)

- `data/models.dart`: DTO `BotProfileItem` (id/name/persona/model/greeting/
  toolAllowlist/createdAt/updatedAt) + `fromMap` snake_case.
- `agent_api_client.dart`: `listBots()`, `createBot()` (menerima 201),
  `updateBot()` PATCH, `deleteBot()` DELETE, `listBotBindings()`,
  `bindBot()`, `unbindBot()`. Backend bot memakai error model typed
  (401/400/404/409/501), sehingga cukup `_throwIf` — `ApiError.fromResponse`
  mengangkat 409 → `ApiError(conflict)`, 404 → `notFound`, 400 →
  `invalidRequest`, 501 → `notImplemented`. Tidak perlu `_throwPayloadError`
  (kontras dengan skills, yang memakai HTTP 200 + `error`).
- `data/agent_repository.dart`: `bots()`, `createBot()`, `updateBot()`,
  `deleteBot()`, `botBindings()`, `bindBot()`, `unbindBot()` — DTO typed
  via `_guard` (timeout/network tetap ApiError).

## 3. UI (`ui/bot_manager_view.dart`)

- `BotsPage` (stateful): header `PageHeader` + tombol **+** (buat) +
  refresh, filter teks id/nama/model, daftar kartu bot.
- Kartu bot: nama + id, model (atau "default"), jumlah tool allowlist,
  jumlah sesi ter-bind, persona (2 baris), tombol Binding/Edit/Hapus.
- Dialog Create/Edit: id divalidasi regex sama dengan backend (pesan error
  inline bila pola ditolak; id fixed saat edit), name wajib, model,
  greeting, persona multiline, tool_allowlist comma-separated. Dialog tidak
  menutup saat validasi gagal.
- Hapus dengan dialog konfirmasi (menjelaskan bahwa semua sesi ter-bind
  ikut dilepas).
- Bottom sheet binding: daftar sesi lengkap dengan statusnya
  (ter-bind ke bot ini / ter-bind ke bot lain / belum ter-bind) dan tombol
  Bind/Unbind kontekstual.
- Hasil semua aksi ditampilkan SnackBar hijau/merah (messenger & warna
  di-capture sebelum await — hindari `use_build_context_synchronously`).

## 4. Shell & refresh

- `app/app_routes.dart`: route `bots` baru (icon `smart_toy`), non-primer di
  mobile (ikut More); rail desktop kini 11 destinasi (scroll guard dari
  P1-03 tetap bekerja).
- `main.dart`: state `bots` + `botBindings`; refreshAdmin menjadi
  **12 GET paralel** (bot + bindings berindeks 9/10); case route
  `AppRoute.bots` dengan callback CRUD/bind; `_MorePage` menerima field
  `bots`/`bindings` + ListTile Bots dengan callback repo lengkap (daftar
  sesi pada More dipakai kosong karena state sesi tidak dilewatkan —
  CRUD tetap penuh).

## 5. Test

- `packages/agent_gateway/test/http_api_bots_test.dart` (15 test, real
  HttpClient): list, 201 create, 409 duplikat, 400 id invalid / name kosong
  / field tidak dikenal / allowlist salah tipe, GET profil + 404, PATCH
  subset + clear model + 404 + field tidak dikenal, DELETE + 404, bind/
  unbind + 404 bot/binding + 400 tanpa session_id, 401 unauth, 501 tanpa
  callback.
- `apps/agent_flutter/test/bots_repository_test.dart` (11 test, fake agentd,
  file pure `test()` tanpa binding): DTO, POST body + 201, 409 →
  ApiError(conflict), 400 → invalidRequest, PATCH clear model, 404 →
  notFound, delete/bind/unbind bool, bindings map, bearer di header, 501 →
  notImplemented.
- `apps/agent_flutter/test/bots_view_test.dart` (5 testWidgets): render
  kartu + metrik, filter, refresh callback, dialog create validasi id + body
  terkirim, sheet binding status + unbind callback.
- `test/app_shell_test.dart`: set route non-primer diperbarui +bots
  (kini 7 route dikelompokkan ke More).

## Yang TIDAK termasuk (jujur)

- **Web UI (`apps/web`) belum punya halaman Bots**: REST API + Flutter GUI
  yang dilengkapi duluan; parity web menyusul item backlog tersendiri.
- **Binding list per-bot di _MorePage**: halaman Bots via More menerima
  daftar sesi kosong (bindings tetap tampil), bind baru dari More memerlukan
  route entry dengan state sesi — menyusul perapian.
- **Live push perubahan bot**: tetap polling 15 detik (belum ada WS global
  admin feed).
- **Import/export profil bot**: endpoint belum ada.

## Verifikasi

- Diverifikasi **lokal**:
  - `packages/agent_gateway`: `dart analyze` no issues; `dart test` 141
    lulus (15 test baru).
  - `packages/tiko_runtime`: `dart test` 254 lulus; `apps/agentd`: 7 lulus.
  - `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 145
    lulus (16 test baru); `flutter build web --release` sukses.
- CI: gateway test job, flutter analyze/test/build web, desktop, Android,
  audit supply-chain, CodeQL.
