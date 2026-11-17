# GUI-P0-01 — Unified Shell & Route Map Tunggal (2026-11-18)

Implementasi item **GUI-P0-01** dari laporan audit GUI eksternal
(`TIKO-AGENT-GUI-REPORT.md`): satu shell/navigasi Flutter untuk Android,
Desktop, dan Web dengan **satu route map** dan **design tokens bersama**.

## Latar

Sebelum perubahan ini, definisi navigasi terduplikasi di `main.dart`:
`NavigationRail` desktop (6 destinasi, label `Chat/Dashboard/Approvals/
Sessions/Memory/Settings`) dan `NavigationBar` mobile (5 destinasi, label
berbeda: `Chat/Home/Approve/Sessions/More`). Label domain yang berbeda antar
platform melanggar kriteria audit: "label dan menu domain sama lintas
platform; hanya presentasi berubah".

## Perubahan

### 1. Route map tunggal — `lib/app/app_routes.dart`

- `AppRoute` enum: `chat, dashboard, approvals, sessions, memory, settings`.
- `kAppRoutes`: daftar `AppRouteInfo` (route, label, ikon,
  `primaryOnMobile`) sebagai satu-satunya sumber destinasi navigasi.
- `kMobilePrimaryRoutes`: route primer untuk bottom bar mobile
  (chat/dashboard/approvals/sessions); `memory` dan `settings` dikelompokkan
  ke entry **More** di mobile (`primaryOnMobile: false`).
- Extension `AppRoutePresentation` memberi `label`/`icon` dari peta yang sama.

### 2. Shell bersama — `lib/shell/`

- `desktop_shell.dart`: `DesktopShell` — `NavigationRail` + divider + area
  konten, destinasi dibangun dari `kAppRoutes`.
- `mobile_shell.dart`: `MobileShell` — `NavigationBar` berisi route primer +
  entry `More` (`onSelect` menerima `null` untuk More), dibangun dari
  `kMobilePrimaryRoutes`.
- `main.dart` kini hanya bootstrap + state + halaman; navigasi didelegasikan
  ke shell. State `int tab` diganti `AppRoute route`; kondisi refresh admin
  periodik menjadi `route != chat && route != settings`.

### 3. Design tokens tambahan — `lib/ui/theme.dart`

Sesuai rekomendasi audit (bagian 6.4):

- Permukaan: `surfaceRaised`, `surfaceHover`, `surfaceSelected`,
  `surfaceOverlay` (varian dark + light) + accessor `raised()/hover()/
  selected()/overlay()`.
- Status: `success`, `info` (dark + light) + accessor.
- Spacing: `xxxl = 32` melengkapi skala 4/8/12/16/24.
- Radius: `radiusSmall = 8`, `radius = 12`, `radiusLarge = 16`.
- Skala tipografi: `display` (28), `pageTitle` (22), `sectionTitle` (16),
  `body` (14), `caption` (12) — warna diwarisi ambient style agar dark/light
  konsisten.
- Context getters: `simpulSurfaceRaised/Hover/Selected/Overlay`,
  `simpulSuccess`, `simpulInfo`.

### 4. Penyeragaman label mobile

Label mobile kini identik dengan desktop: `Chat, Dashboard, Approvals,
Sessions, More`. Halaman More tetap menampung Memory, Settings, Graf Vault,
dan Editor Catatan (perilaku lama dipertahankan; entry mem-push halaman
penuh).

## Yang TIDAK termasuk (jujur)

- **URL routing browser** (back/forward, deep-link `/workspace/chat/<id>`)
  belum diimplementasi — butuh `Router` API 2.0 atau dependency routing;
  ditunda agar refactor ini tetap mekanis dan mudah direview.
- Belum ada golden test visual; hanya widget test perilaku.
- Right inspector panel (rancangan audit bagian 6.3) belum dibuat.
- Halaman domain baru (Tasks, Skills, Provider, MCP, Channels) dari backlog
  P1 belum ditambahkan ke route map — peta siap ditambah tanpa menyentuh
  shell lagi.

## Test

`apps/agent_flutter/test/app_shell_test.dart` (7 test baru):

- Route map: label/ikon unik, semua enum tercakup, chat pertama.
- Route primer mobile tepat 4 dan sesuai urutan; memory/settings non-primer.
- DesktopShell: rail merender semua label dari route map; tap memanggil
  `onSelect` dengan route benar.
- MobileShell: bottom bar merender route primer + More; Memory/Settings tidak
  ada di bar; tap More mengirim `null`, tap Chat mengirim route.
- Design tokens: varian dark/light berbeda untuk raised/hover/selected/
  success/info; skala spacing/radius/tipografi tersedia.

`test/widget_test.dart` diperbarui: label mobile kini `Dashboard`/
`Approvals` (bukan `Home`/`Approve`).

## Verifikasi

- Tidak ada Dart/Flutter SDK di lingkungan penyusunan; seluruh verifikasi
  melalui CI (`flutter analyze --fatal-warnings`, `flutter test`,
  `flutter build web`, build desktop/Android).
- Verifikasi lokal terbatas: pemeriksaan manual referensi silang antara
  route map, shell, dan pemakaian di `main.dart`.
