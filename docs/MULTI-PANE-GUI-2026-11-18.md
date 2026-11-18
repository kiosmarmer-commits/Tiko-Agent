# Multi-pane Workspace GUI (GUI-P2-03) — 18 November 2026

Status: **Implemented** — preferensi tampilan dua klien (Flutter + web), tanpa API baru.

Sumber rancangan: `TIKO-AGENT-GUI-REPORT.md` backlog P2 —
`GUI-P2-03 Multi-pane layout … acceptance: Session, files, inspector panes`.

## Prinsip

- Data selalu dari API runtime yang sama (`/v1/sessions`, `/v1/runs`,
  `/v1/artifacts` + `/v1/artifacts/read`); multi-pane hanyalah komposisi layout.
- Mode tunggal tetap default; multi-pane diaktifkan lewat preferensi pengguna,
  bukan dipaksakan pada layar sempit.
- Semua render tetap `textContent` (web) dan widget aman (Flutter).

## Flutter (`apps/agent_flutter`)

- `lib/ui/settings_store.dart` — setting baru `multiPane` (default `false`,
  key `ui.multiPane`, persist via `AppSettings.save/load`, tersedia di
  `copyWith`).
- `lib/ui/settings_view.dart` — SwitchListTile "Multi-pane workspace
  (GUI-P2-03)" di bagian perilaku.
- `lib/ui/multi_pane_view.dart` (BARU):
  - `SessionsPane` — daftar sesi (judul + channel + jumlah turn), highlight
    sesi aktif, refresh, tap langsung membuka sesi ke chat.
  - `InspectorPane` — header + `ToggleButtons` Runs/Files; Runs menampilkan
    run aktif + riwayat (badge RUNNING/SELESAI/GAGAL, session, langkah, token)
    dengan refresh; Files menampilkan listing artifacts (path, bytes,
    modified, flag truncation) dan tap membuka preview via API baca
    read-only; tombol tutup pane.
- `lib/main.dart`:
  - Route `chat` pada layar lebar (`>= 900px`, shell desktop) dibungkus
    `Row`: `SessionsPane` + chat + `InspectorPane` bila `settings.multiPane`.
  - `inspectorVisible` state + `_toggleInspector()`; tombol toggle di
    `PageHeader` chat (kemunculan ikon view-column/chevron).
  - Lazy-load: snapshot runs dimuat saat multi-pane pertama tampil
    (`_selectRoute`, saat setting diaktifkan, dan saat inspector dibuka);
    artifacts dimuat saat tab Files pada inspector dibuka.
  - Pemilihan sesi dari pane memakai jalur yang sama dengan halaman Sessions
    (`sessionKey` + `chat.openSession`).

## Web parity (`apps/agentd/web`)

- `index.html` — tab Chat memperoleh tombol `#btn-multipane`
  (`aria-pressed`), pembungkus `#chat-panes` dengan `#pane-chat` (isi chat
  asli, tidak berpindah logika) plus `aside#pane-sessions`
  (`#pane-session-list`, refresh) dan `aside#pane-inspector`
  (`#pane-runs-list`, refresh, tombol tutup).
- `app.css` — `.chat-panes` flex (pane memformat 240px, chat fleksibel,
  menyempit di bawah 1100px), header pane + border var tema.
- `app.js`:
  - `loadSessions(listId)` / `loadRuns(listId)` direfaktor menerima id list
    sehingga dipakai bersama tab asli dan pane (tidak duplikasi render).
  - `setMultipane(on)` toggle class `multipane` pada `#tab-chat`, atribut
    `aria-pressed`, Hidden kedua pane, dan lazy-load pane sessions + runs.
  - Handler refresh pane + tombol tutup; delegasi klik run util expand langkah
    bawaan `_runItem` tetap berlaku di pane.

## Test

- Flutter: `test/multi_pane_view_test.dart` — 4 testWidgets (render+
  highlight+onSelect sesi, runs + refresh, tab Files + open artifact, tombol
  tutup). Total flutter test 250.
- Web: `app.test.cjs` — 2 test (toggle membuka pane + memuat `/v1/sessions`
  & `/v1/runs` + class/aria + close; refresh pane memanggil ulang API).
  Total node --test 33.
- Harness: id pane baru (`pane-sessions`, `pane-inspector`,
  `pane-session-list`, `pane-runs-list`, dll), hidden awal `true`.

## Verifikasi lokal

- `flutter analyze` (apps/agent_flutter): bersih.
- `flutter test`: 250 lulus.
- `flutter build web --release`: sukses.
- `node --test apps/agentd/web/app.test.cjs`: 33 lulus.
- `bash scripts/web_ui_validate.sh`: lulus.

## Batasan jujur

- Pane sessions web read-only; pemilihan sesi tetap lewat tab Sessions (chat
  web belum membawa state pemilihan sesi).
- Inspector web hanya runs; preview artifacts tetap lewat tab Artifacts.
- Tidak ada drag-resize pane (lebar tetap); tidak ada state pane yang
  dipersist di web (toggle per sesi browser).
- Tanpa golden/E2E visual; multi-pane hanya diverifikasi widget/Node test +
  build web release.
