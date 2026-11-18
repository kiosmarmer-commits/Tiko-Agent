# GUI-P2-02: Command palette global — 2026-11-18

Item **Command palette** dari backlog P2 ("Produktivitas desktop/web —
Ctrl/Cmd+K action/search"): overlay aksi global kini tersedia di kedua
klien — komponen `command_palette.dart` (FR-44, sebelumnya hanya dipakai
note editor) **di-wire sebagai palette level aplikasi** di Flutter, dan
web UI mendapat palette paritas dengan pola interaksi yang sama.

## 1. Flutter (`apps/agent_flutter`)

- `PaletteShortcut` (sudah ada) dipasang mengelilingi `home: Scaffold`
  di `main.dart` — binding **Ctrl+K** dan **Ctrl+P** membuka
  `showCommandPalette`.
- `_openCommandPalette()` membangun aksi global:
  - Navigasi: satu aksi per `kAppRoutes` (17 halaman) memanggil
    `_selectRoute` — efek sama persis dengan klik rail/More, termasuk
    lazy-load runs/memory explorer.
  - `Muat ulang data admin` → `refreshAdmin(force: true)`.
- `showCommandPalette` ditambah `onSubmitted` pada filter field sehingga
  Enter dari IME/text field juga menjalankan aksi terpilih (selain
  binding `SingleActivator(enter)` di list dan tap item).

## 2. Web parity (`apps/agentd/web`)

- Overlay `#cmd-palette` (input `#cmd-input` + list `#cmd-list`) markup
  statik + style fixed overlay di `app.css`; awalnya `hidden`.
- Refactor kecil: logika switch tab diekstrak ke `switchTab(target)` —
  dipakai bersama oleh klik tab (perilaku lama tidak berubah) dan
  palette (pilih tab dari daftar).
- **Ctrl/Cmd+K** toggle palette (toggle bila sudah terbuka), filter
  substring case-insensitive, **Enter** memilih item pertama hasil
  filter, **Escape** menutup; klik item bekerja via delegasi
  `#cmd-list` — memilih tab tertentu (bukan hanya item pertama).
- Semua render `textContent` — item merender label tab statik, aman
  XSS secara struktural (bukan interpolasi innerHTML).

## 3. Test

- Flutter 2 baru (`command_palette_global_test.dart`): Ctrl+K membuka
  palette, filter, tap item menjalankan aksi; filter kosong + Escape
  menutup. (246 total).
- Web 2 baru: Ctrl+K buka + filter 'ru' → hanya tab Runs + pilih via
  klik delegasi → section Runs aktif & palette tertutup; Escape menutup
  + toggle Ctrl/Cmd+K. (31 total).
- Verifikasi: `flutter analyze` bersih; `flutter test` 246 lulus;
  `flutter build web --release` sukses; `node --test` 31 lulus;
  `bash scripts/web_ui_validate.sh` lulus.

## Yang TIDAK termasuk

- **Desktop app belum punya menu halaman untuk memanggil palette**
  (hanya shortcut keyboard); integrasi tombol toolbar menyusul bila
  diperlukan.
- Web palette belum menampilkan aksi non-navigasi (mis. refresh admin)
  — hanya perpindahan tab.
- Tanpa jest/golden visual; tanpa browser E2E nyata (harness Node).
