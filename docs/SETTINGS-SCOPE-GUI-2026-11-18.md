# GUI-P1-08: Settings scope Flutter — 2026-11-18

Implementasi item **GUI-P1-08** (Settings scope) dari backlog audit GUI
(`TIKO-AGENT-GUI-REPORT.md` §11 P1, rekomendasi #6 / gap #8): halaman
Settings kini **memisahkan tiga scope** secara eksplisit — preferensi
perangkat, kredensial, dan status daemon — sehingga pengguna tahu mana
yang tersimpan lokal, mana yang hanya hidup di memori sesi, dan mana yang
read-only dari daemon.

Prinsip jujur tetap dipakai: konfigurasi daemon bersifat **immutable saat
daemon hidup** (plugin/MCP/channel/provider default). GUI karenanya hanya
menampilkan status runtime read-only dari `GET /v1/status` + catatan cara
mengubah config (ubah file config + restart); tidak ada kontrol untuk aksi
yang belum punya backend.

## 1. UI: pemisahan scope (`ui/settings_view.dart`)

- `_scopeCaption(context, text)` — caption kecil (ikon `rule_outlined` +
  teks 11px muted) di atas tiap section:
  - **Tampilan → "Perangkat — tersimpan lokal di perangkat ini
    (shared_preferences)"**.
  - **Koneksi → "Kredensial — hanya di memori sesi, tidak pernah
    dipersist"**.
  - **Perilaku → "Perangkat — tersimpan lokal"**.
  - **Bloks daemon → "Daemon — status runtime, read-only (config
    immutable: ubah config + restart)"**.
- **Toggle visibilitas bearer token**: `TextFormField` token kini
  `obscureText: !_tokenVisible` dengan `suffixIcon` tombol mata
  (`visibility_outlined` ⇄ `visibility_off_outlined`) + helper text "Hanya
  di memori sesi..." — token default tersembunyi, tidak pernah dipersist
  (kebijakan GUI-P0-05 tetap).

## 2. UI: section daemon status read-only (`GET /v1/status`)

- Param baru `SettingsView.daemonStatus` (`Map<String, dynamic>?`) diisi
  dari snapshot `/v1/status` yang sudah dipoll `main.dart` (15 detik).
- Blok read-only: caption scope + judul "Daemon — status runtime" + panel
  `ListTile` berisi versi daemon, provider default, backend memori, safe
  mode, sandbox, profil resource (helper `_daemonStatusRows`).
- `ListTile` "Konfigurasi daemon": penjelasan config immutable — ubah file
  config lalu restart; override provider per sesi ada di halaman Providers.
- `main.dart`: `daemonStatus` diteruskan ke `SettingsView` (desktop) dan
  `_MorePage` → push Settings (mobile).

## 3. Test

- `test/settings_test.dart` (+2 testWidgets, total 7):
  - "GUI-P1-08: scope terpisah — caption perangkat/kredensial/daemon":
    caption Perangkat/Kredensial di-top, panel daemon ter-render dengan
    nilai dari `/v1/status` mock (`1.2.3`, `mock-1`, `sqlite`, `true`,
    `process`, `laptop`), caption read-only + penjelasan config immutable.
  - "GUI-P1-08: toggle visibilitas bearer token": token tersembunyi
    default → tap mata → token terlihat + ikon berganti.

## Yang TIDAK termasuk (jujur)

- **Endpoint mutasi config daemon dari GUI**: tidak ada (backend tidak
  menyediakan; config immutable saat daemon hidup) — status daemon di
  Settings read-only, perubahan via file config + restart.
- **Edit vault path / auto-lock sebagai "daemon config"**: tetap scope
  perangkat (shared_preferences lokal), bukan config daemon.
- **Bearer token tetap tidak dipersist**: tidak ditulis ke
  shared_preferences/localStorage (dikunci test GUI-P0-05); hanya hidup di
  memori sesi.
- **Live push status daemon**: masuk saat polling admin 15 detik.
- **Web UI parity**: perubahan Settings belum ada di `apps/web` (menyusul).

## Verifikasi

- Diverifikasi **lokal**:
  - `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 175
    lulus (2 testWidgets baru); `flutter build web --release` sukses.
- Batas: GUI hanya menampilkan field `GET /v1/status` yang benar-benar
  terekspos; tidak ada kontrol untuk aksi yang belum punya backend.
