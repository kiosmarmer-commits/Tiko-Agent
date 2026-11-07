# Agent Flutter UI

UI minimalis setara web (`http://127.0.0.1:8787/`).

## Tab

| Tab | Fitur |
|-----|--------|
| **Chat** | Pesan, streaming WS, konfirmasi tool; tidak mengulang prompt otomatis via HTTP ketika WS gagal |
| **Memori** | List fakta, hapus, pull-to-refresh |
| **Status** | Provider, jobs, metrics, safe-mode |
| **Bantuan** | Panduan + setelan URL/token + mode streaming |

## Jalankan

```bash
# Terminal 1 — daemon
cd ../..   # root agent_dart
dart run apps/agentd/bin/agentd.dart --api  # token acak disimpan di data/api.token dengan permission 0600

# Terminal 2 — Flutter
cd apps/agent_flutter
flutter pub get
TOKEN="$(tr -d '\r\n' < ../../data/api.token)"
flutter run --dart-define=API_TOKEN="$TOKEN" --dart-define=API_BASE=http://127.0.0.1:8787
```

Android emulator: pakai `http://10.0.2.2:8787` sebagai `API_BASE`.
