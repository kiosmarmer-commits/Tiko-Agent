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
