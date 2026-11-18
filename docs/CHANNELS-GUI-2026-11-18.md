# GUI-P1-07: Channels Setup Flutter — 2026-11-18

Implementasi item **GUI-P1-07** (Channels setup) dari backlog audit GUI
(`TIKO-AGENT-GUI-REPORT.md` §11 P1): status channel gateway aktif (telegram,
discord, email smtp/imap, whatsapp, slack, signal, matrix, openai, http)
beserta **nama** variabel env yang mengonfigurasinya lewat REST + GUI
Flutter, tanpa harus membaca log startup daemon.

Prinsip jujur tetap dipakai: setup channel di runtime ini bersifat **config
immutable** — gateway di-spawn saat daemon start dari env dan tidak bisa
di-enable/disable Runtime. GUI karenanya **read-only**: membantu melihat
channel mana yang hidup dan env apa yang mengaturnya; perubahan dilakukan
via env + restart daemon, sama seperti CLI.

## 1. Backend REST API (baru)

- `apps/agentd/bin/agentd.dart`:
  - `channelsSnapshot({channel: active})` — builder snapshot dari daftar
    gateway yang benar-benar hidup di daemon (`tg`, `discord`, `email`,
    `imap`, `wa`, `slackGw` plus `gatewayForChannel('signal'|'matrix')`,
    server `openAiServer` dan `api`) — satu sumber dengan startup log.
  - `_channelEnv` — peta **nama** variabel env per channel (daftar persis
    variable yang dibaca konstruksi gateway); hanya nama, **nilai rahasia
    tidak pernah dikirim**.
- `packages/agent_gateway/lib/src/http_api.dart`: callback opsional
  `channelsProvider` (null → `501 not_implemented`); route
  `GET /v1/channels` → snapshot; endpoint read-only (POST lain 404).

## 2. Data layer Flutter (typed)

- `data/models.dart`: DTO `ChannelsSnapshot` + `ChannelInfo`
  (channel/active/env — semua `fromMap` snake_case dan toleran).
- `agent_api_client.dart`: `fetchChannels()` (GET, `_throwIf`).
- `data/agent_repository.dart`: abstract + impl `channels()`.

## 3. UI Flutter

- `ui/channels_view.dart` (baru): `ChannelsPage` stateless — `PageHeader`
  (subtitle N channel + M aktif) + tombol refresh; kartu penjelasan "Setup"
  (env + restart); `_ChannelCard` per channel — ikon per channel, badge
  **aktif** (hijau) / **nonaktif** (abu), daftar `env <NAMA>` (hanya nama).
- `app/app_routes.dart`: `AppRoute.channels` ('Channels',
  `Icons.hub_outlined`, non-primer) — rail kini 14 destinasi.
- `main.dart`: state `channelSnapshot`; refreshAdmin kini **15 GET** paralel
  (index 14 = channels); case `AppRoute.channels`; `_MorePage` field
  `channelSnapshot` + ListTile Channels (counter channel aktif).

## 4. Test

- `packages/agent_gateway/test/http_api_channels_test.dart` (4 test):
  snapshot channel + nama env, 401 tanpa auth, 404 untuk POST (read-only),
  501 tanpa callback.
- `apps/agent_flutter/test/channels_repository_test.dart` (3 test): parse
  snapshot typed, bearer header, `ApiError.notImplemented` tanpa callback.
- `test/channels_view_test.dart` (4 testWidgets): badge aktif/nonaktif +
  nama env, kartu Setup, kondisi kosong, tombol refresh.
- `test/app_shell_test.dart`: set `grouped` + `AppRoute.channels`.

## Yang TIDAK termasuk (jujur)

- **Menyalakan/mematikan channel dari GUI**: env + restart adalah satu-satunya
  jalur setup (config immutable runtime) — GUI read-only.
- **Form/wizard setup channel** (input token dsb.): tidak ada karena backend
  tidak menyimpan config channel yang bisa dimutasi; menampilkannya berarti
  menulis env dari GUI yang belum didukung runtime.
- **Health per koneksi** (ping Telegram API / MX sync lag dll.): gateway
  tidak mengekspos status koneksi live; GUI menampilkan status konfigurasi
  gateway, bukan kesehatan jaringan.
- **Live push perubahan channel**: di-refresh saat polling admin 15 detik.
- **Web UI parity**: halaman Channels belum ada di `apps/web` (menyusul).

## Verifikasi

- Diverifikasi **lokal**:
  - `packages/agent_gateway`: `dart analyze` no issues; `dart test` 160
    lulus (4 test baru).
  - `apps/agentd`: `dart analyze` no issues.
  - `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 173
    lulus (7 test baru); `flutter build web --release` sukses.
- Batas: GUI hanya membaca `GET /v1/channels` yang benar-benar terekspos;
  tidak ada kontrol untuk aksi yang belum punya backend.
