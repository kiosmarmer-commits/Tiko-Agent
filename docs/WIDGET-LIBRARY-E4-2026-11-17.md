# E4: Pustaka Widget Flutter Reusable (`tiko_widgets`) — 2026-11-17

## Ringkasan

E4 menutup gap dari laporan Qwen ("DX untuk Flutter — widget siap pakai
`TikoChatInterface`, `TikoAgentStatusIndicator`"): widget kunci diekstrak dari
`apps/agent_flutter` ke paket reusable **`apps/tiko_widgets`** agar aplikasi
Flutter lain bisa mengintegrasikan agen Tiko tanpa menyalin kode.

## Lokasi paket (keputusan teknis)

`apps/tiko_widgets` — **sengaja di luar workspace Dart** dan di luar loop
`dart analyze` CI: paket bergantung Flutter SDK tidak bisa dianalisis dengan
`dart pub get`/`dart analyze` murni dari workspace Dart. CI mendapat job khusus
baru **`tiko-widgets`** (flutter pub get + analyze + test, Flutter 3.47.5).

## Isi

| Widget | Asal | Catatan |
|---|---|---|
| `GenUiMessageView` | `apps/agent_flutter/lib/ui/gen_ui_view.dart` (D1) | Renderer pesan dengan blok ```genui; fail-closed |
| `GenUiView` | sama | Renderer satu `GenUiSpec` (7 tipe node) |
| `RoutingSummary` | `apps/agent_flutter/lib/ui/status_view.dart` | Parsing murni payload `/v1/status` (tanpa I/O) |
| `TikoChatInterface` | **BARU** | Antarmuka chat generik: daftar bubble user/assistant/error + input + dukungan GenUI; tanpa dependensi API client |

`apps/agent_flutter` kini mengimpor dari paket via **shim re-export**
(`lib/ui/gen_ui_view.dart`, `lib/ui/status_view.dart`) sehingga `main.dart`
dan test lama tetap berfungsi tanpa perubahan.

## Batasan (dilaporkan jujur)

- `TikoChatInterface` sengaja minimal (bubble + input + GenUI); bukan
  pengganti UI lengkap agent_flutter (tanpa streaming token, tanpa attachment).
- `RoutingSummary` adalah kelas parsing murni; kartu dashboard visual tetap di
  aplikasi host.
- Paket belum dipublikasikan ke pub.dev (`publish_to: none`).

## Pengujian

- `apps/tiko_widgets/test/tiko_widgets_test.dart` — 5 test widget: empty
  message, onSend ter-trim, busy menonaktifkan input, bubble per-role,
  default `TikoChatMessage`.
- `flutter analyze` bersih di tiko_widgets dan agent_flutter.
- `flutter test` agent_flutter: 78 pass (test GenUI/status lama tetap hijau
  via shim).
- CI: job baru `tiko-widgets` (analyze + test), job flutter lama memvalidasi
  integrasi shim lewat build web/desktop.
