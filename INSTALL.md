# Instalasi Tiko Agent

Dokumen ini adalah panduan instalasi **source repository** Tiko-Agent. Ini menggantikan petunjuk lama yang hanya menjelaskan ekstraksi UI-repair overlay.

## 1. Persyaratan

- Git.
- Dart SDK minimal sesuai constraint root `pubspec.yaml`: `^3.8.0`. CI snapshot memakai Dart 3.13.4.
- Flutter SDK hanya untuk menjalankan client Flutter; CI snapshot memakai Flutter 3.47.5.
- Ollama atau API provider hanya bila ingin menggunakan model nyata. Provider `mock` cukup untuk smoke awal.
- Untuk isolasi proses tool/MCP, host perlu sandbox OS yang didukung; tanpa itu fitur yang mensyaratkan sandbox harus fail-closed/tidak tersedia.

## 2. Linux / VPS / komputer

```bash
git clone https://github.com/kiosmarmer-commits/Tiko-Agent.git
cd Tiko-Agent
dart --version
dart pub get

dart run apps/tiko/bin/tiko.dart setup --provider mock
dart run apps/tiko/bin/tiko.dart config validate
dart run apps/tiko/bin/tiko.dart doctor
```

Mulai chat:

```bash
dart run apps/tiko/bin/tiko.dart chat
```

Pilih provider Ollama:

```bash
ollama pull qwen2.5:3b
dart run apps/tiko/bin/tiko.dart setup --provider ollama
```

Periksa `config/agent.yaml`, terutama `providers.chat`, `providers.default_chat`, `providers.tiers`, `decision`, `search`, `security`, `storage`, `api`, dan `mcp`. Setup awal dengan `--provider ollama` mengasumsikan Ollama tersedia pada alamat default `http://127.0.0.1:11434`.

## 3. Android / Termux

Di Termux, clone repository lalu jalankan helper:

```bash
pkg update -y
pkg install -y git dart curl
git clone https://github.com/kiosmarmer-commits/Tiko-Agent.git
cd Tiko-Agent
bash scripts/termux_setup.sh
```

Helper `termux_setup.sh` memperbarui paket, memastikan paket `dart`, `git`, `curl`, dan menjalankan `dart pub get`. Setelahnya buat konfigurasi:

```bash
dart run apps/tiko/bin/tiko.dart setup --provider mock
# atau, setelah Ollama/provider tersedia:
# dart run apps/tiko/bin/tiko.dart setup --provider ollama

dart run apps/tiko/bin/tiko.dart config validate
dart run apps/tiko/bin/tiko.dart doctor
```

Jalankan daemon + UI:

```bash
bash scripts/run_agentd.sh
```

Buka `http://127.0.0.1:8787/` dari browser pada perangkat yang sama. API token berada di `data/api.token`; file tersebut harus tetap privat. `termux-wake-lock` dapat membantu menjaga proses, tetapi tidak menjamin Android tidak menghentikan daemon.

## 4. Web UI

Alternatif menjalankan langsung:

```bash
dart run apps/agentd/bin/agentd.dart --api
```

Default host API adalah `127.0.0.1`, default port `8787` (dapat diubah melalui `API_PORT` atau konfigurasi). Token dibuat secara acak jika `API_TOKEN` tidak diberikan, harus minimal 32 karakter bila ditentukan manual, dan ditulis ke `data/api.token` dengan permission POSIX `0600`. Endpoint `/health` terbuka; endpoint `/v1/*` terautentikasi.

Jangan ubah `API_HOST` menjadi `0.0.0.0` kecuali memahami risiko, mengamankan jaringan, dan menambahkan TLS/reverse proxy yang sesuai.

## 5. Flutter Android / Web

Jalankan daemon dahulu, lalu terminal kedua:

```bash
cd apps/agent_flutter
flutter pub get
TOKEN="$(tr -d '\r\n' < ../../data/api.token)"
flutter run --dart-define=API_TOKEN="$TOKEN" --dart-define=API_BASE=http://127.0.0.1:8787
```

Untuk Android Emulator yang mengakses daemon di komputer host, ganti base URL ke `http://10.0.2.2:8787`. Untuk perangkat fisik, gunakan alamat host yang dapat dijangkau perangkat dan jangan membuka port tanpa perlindungan.

Build Flutter Web:

```bash
cd apps/agent_flutter
flutter pub get
flutter analyze
flutter test
flutter build web --release
```

## 6. Validasi lengkap

Dari root repository:

```bash
bash scripts/validate.sh
```

Workflow CI melakukan strict Dart analysis, test seluruh workspace member yang memiliki test, smoke CLI/config/daemon, compile entrypoint, dan Flutter analyze/test/web build. `scripts/validate.sh` menjalankan Flutter validation juga; jalankan `scripts/flutter_validate.sh` tersendiri bila hanya ingin menguji client.

## 7. Troubleshooting

| Gejala | Pemeriksaan |
|---|---|
| Konfigurasi ditolak | `tiko config validate`; secret harus berupa `env:NAMA_VAR`, bukan nilai mentah |
| Provider tidak tersedia | Periksa `providers.default_chat`, `providers.chat`, endpoint, model, dan variabel secret |
| API port dipakai proses lain | `tiko doctor`; cek `api.port` atau `API_PORT`; jangan membunuh PID yang tidak dikenal |
| UI offline | Periksa daemon, URL, token di Settings, dan `/health` |
| SQLite gagal dibuka | `tiko doctor`; runtime dapat beralih ke JSON fallback dengan status degraded |
| MCP tidak aktif | Periksa `mcp.servers`, allowlist, SecretRef, dan ketersediaan sandbox OS; proses dimulai oleh daemon setelah instance lock |
| Shell/MCP/script tidak aktif | Periksa hasil deteksi sandbox host; jangan menganggap `proot` setara isolasi OS |
| Job tidak terkirim ke channel | Pastikan gateway channel tersebut diaktifkan; scheduler tidak mengirim silang ke gateway lain |

Jangan commit `data/api.token`, `.env`, token bot, API key, atau file data runtime.
