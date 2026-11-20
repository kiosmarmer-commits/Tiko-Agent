# Tiko Flutter Client

Flutter client untuk daemon Tiko melalui HTTP API dan WebSocket. Client bukan runtime agent mandiri; provider, tools, memory, approvals, scheduler, dan gateways dikelola daemon `agentd`.

## Tab

| Tab | Kemampuan |
|---|---|
| Chat | Mengirim pesan dan menerima event/teks melalui WebSocket; approval tool menggunakan broker daemon yang sama |
| Memori | Melihat dan menghapus memory facts melalui API |
| Status | Status runtime/provider, capability, doctor dan data administrasi yang tersedia pada daemon |
| Approvals | Melihat approval tertunda dan mengirim keputusan ke daemon |
| Sessions | Melihat session yang disediakan daemon |
| Bantuan | Mengatur alamat API dan token serta opsi streaming |

## Desain

Semua warna, spacing, radius, dan typography GUI (Android/Web/Desktop) berasal dari design token terpusat `lib/ui/theme.dart` (`SimpulTheme`) dengan gaya flat modern sederhana. Rancangan lengkap, referensi, dan aturan perubahan token ada di [docs/09-DESAIN-GUI.md](../../docs/09-DESAIN-GUI.md).

## Flutter Web same-origin (Jalur A fase 1)

Build web dapat dilayani langsung oleh agentd sehingga menjadi satu-satunya UI web:

```bash
cd apps/agent_flutter && flutter build web --release
dart run apps/agentd/bin/agentd.dart --api
```

Buka `http://127.0.0.1:8787/`; `_findWebRoot()` memprioritaskan `build/web` di atas dashboard vanilla (`apps/agentd/web`), dan `WEB_ROOT` env bisa meng-override. Pada web, `API_BASE` default mengikuti origin halaman (same-origin) dan WebSocket memakai ticket sekali pakai; saat UI dilayani langsung oleh agentd, cookie sesi same-origin diterbitkan otomatis sehingga kolom token di Settings/Bantuan tidak perlu diisi (opsional, hanya untuk koneksi ke daemon lain). Browser dashboard juga terbuka otomatis saat menjalankan daemon langsung; matikan via env `TIKO_NO_BROWSER=1` atau `TIKO_OPEN_BROWSER=0`.

## Menjalankan

Mulai daemon dari root repository:

```bash
dart run apps/agentd/bin/agentd.dart --api
```

Di terminal lain:

```bash
cd apps/agent_flutter
flutter pub get
TOKEN="$(tr -d '\r\n' < ../../data/api.token)"
flutter run --dart-define=API_TOKEN="$TOKEN" --dart-define=API_BASE=http://127.0.0.1:8787
```

Android Emulator yang mengakses daemon pada komputer host: gunakan `API_BASE=http://10.0.2.2:8787`. Perangkat fisik memerlukan alamat server yang dapat dijangkau dan konfigurasi jaringan yang aman.

## Validasi

```bash
flutter analyze
flutter test
flutter build web --release
```

Job CI menjalankan ketiga validasi ini setelah `flutter pub get`. Token API bersifat rahasia; jangan masukkan token ke source code, commit, atau URL yang dibagikan.
