# Simple/Advanced Mode GUI (GUI-P2-01) — 18 November 2026

Status: **Implemented** — mode layout di layer navigasi dua klien (Flutter +
web), tanpa API baru dan tanpa mengubah kemampuan runtime.

Sumber rancangan: `TIKO-AGENT-GUI-REPORT.md` backlog P2 —
`GUI-P2-01 Simple/Advanced mode … acceptance: mode layout tanpa mengubah
kemampuan runtime`; prinsip 6.1.3 (progressive disclosure).

## Definisi mode

- **Advanced** (default; perilaku lama tidak berubah): semua 19 route
  terlihat.
- **Simple**: hanya route inti — Chat, Dashboard (satu halaman status),
  Approvals, Sessions, Tasks, Memory, Settings. Modul teknis (Skills, Bots,
  Providers, Plugins, Channels, Automation, Security, Audit, Artifacts, Runs,
  Events, Logs) disembunyikan dari navigasi; halaman tersebut tetap dapat
  diakses bila sedang aktif dan semua API tetap tersedia.

## Flutter (`apps/agent_flutter`)

- `lib/app/app_routes.dart` — `kSimpleRoutes` + `visibleRoutes({required
  advanced})` sumber tunggal filter; `mobilePrimaryRoutes(entries)` variant
  dari getter lama.
- `lib/ui/settings_store.dart` — setting `advancedMode` (default `true`, key
  `ui.advancedMode`, persist + `copyWith`).
- `lib/ui/settings_view.dart` — SwitchListTile "Mode Advanced (GUI-P2-01)"
  dengan penjelasan cakupan Simple.
- `lib/shell/desktop_shell.dart` / `mobile_shell.dart` — param `entries`
  (default `kAppRoutes`); rail dan bottom bar kini dari daftar yang difilter.
- `lib/main.dart` — `routes = visibleRoutes(...)` diteruskan ke kedua shell;
  palette global hanya menawarkan route aktif; `_MorePage` menyembunyikan
  tile modul teknis pada Simple mode; MobileShell `selected` dinolkan bila
  route saat ini tidak ada di daftar aktif.

## Web parity (`apps/agentd/web`)

- `index.html` — tombol `#btn-mode-advanced` di header (teks/`aria-pressed`
  dinamis "Mode: Advanced/Simple"); tab teknis diberi `data-advanced="true"`
  (skills, bots, providers, plugins, channels, jobs, security, audit,
  artifacts, runs).
- `app.js` — `setAdvancedMode(advanced)`: toggle class `advanced-hidden`
  pada tab `data-advanced`, tampilkan/sembunyikan dari command palette
  (`paletteItems` menyaring), fallback ke tab Chat bila tab aktif
  tersembunyi, dan persist preferensi ke `localStorage` key
  `agent_ui_simple` (`try/catch`, opsional). Default Advanced (paritas
  Flutter); Simple hanya di-restore bila tersimpan `'1'`.
- `app.css` — `.tabs button.advanced-hidden { display: none; }` + gaya tombol
  mode.

## Test

- Flutter: `test/simple_mode_test.dart` — filter route, persist setting,
  DesktopShell/MobileShell Simple mode (rail tanpa modul teknis). Total
  flutter test 254.
- Web: `app.test.cjs` — 2 test (toggle menyembunyikan 10 tab teknis +
  fallback Chat + persist localStorage + restore, palette menyaring tab
  tersembunyi). Total node --test 35.
- Harness: `.tabs button.active` selector, `getAttribute`, id
  `btn-mode-advanced`, `dataset.advanced` pada tab sintetis.

## Verifikasi lokal

- `flutter analyze`: bersih; `flutter test`: 254 lulus.
- `flutter build web --release`: sukses.
- `node --check app.js`; `node --test`: 35 lulus; `scripts/web_ui_validate.sh`
  lulus.

## Batasan jujur

- Simple mode hanya menyaring navigasi; rute langsung (state) yang sedang
  aktif tetap dirender, tidak dipaksa pindah.
- Web Simple menyimpan preferensi di `localStorage` (layout preference, bukan
  credential — aman sesuai batasan GUI-P0-05).
- Tanpa onboarding wizard terkait mode; tanpa golden/E2E visual.
