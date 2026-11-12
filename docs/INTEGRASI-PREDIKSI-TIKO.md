# Integrasi Paket `prediksi` ke Tiko-Agent

Dokumen ini menjelaskan cara memasukkan library prediksi pasar ke monorepo
Tiko-Agent secara lengkap (package + tool + skill).

## 1. Salin package

```bash
# Dari root monorepo Tiko-Agent
cp -a path/ke/tiko-prediksi-integration/packages/prediksi packages/
```

Struktur yang diharapkan:

```
Tiko-Agent/
  packages/
    prediksi/          ← package baru
    agent_tools/
    agent_core/
    ...
  skills/
    prediksi-pasar/    ← skill baru
```

## 2. Daftarkan di workspace

**Root `pubspec.yaml`** — tambah baris di bagian `workspace:`:

```yaml
workspace:
  - packages/prediksi
  - packages/agent_core
  - packages/agent_tools
  # ... sisanya
```

**`packages/agent_tools/pubspec.yaml`** — tambah dependency:

```yaml
dependencies:
  prediksi:
    path: ../prediksi
  # ... dependency lain yang sudah ada
```

Lalu:

```bash
dart pub get
```

## 3. Pasang tool

Salin file tool:

```bash
cp packages/agent_tools_patch/lib/src/prediksi_tool.dart \
   packages/agent_tools/lib/src/prediksi_tool.dart
```

Export di `packages/agent_tools/lib/agent_tools.dart` (tambah baris):

```dart
export 'src/prediksi_tool.dart';
```

Daftarkan tool di `createBuiltinTools` (atau composition root yang setara), contoh:

```dart
import 'prediksi_tool.dart';

// di dalam createBuiltinTools(...):
...createPrediksiTools(),
```

Atau daftarkan manual ke `ToolRegistry` di bootstrap daemon/runtime.

## 4. Pasang skill

```bash
cp -a path/ke/tiko-prediksi-integration/skills/prediksi-pasar skills/
```

Skill memakai frontmatter standar Tiko. Setelah load, jalankan evaluasi/approval sesuai lifecycle skill yang ada di proyekmu (`tiko skills evaluate prediksi-pasar` dll.).

## 5. Verifikasi

```bash
dart pub get
dart analyze --fatal-warnings
dart test
# uji tool secara manual lewat CLI / agent loop
```

## 6. Tool yang tersedia setelah integrasi

| Nama tool | Fungsi |
|-----------|--------|
| `prediksi_teknikal` | RSI + MACD + Bollinger + SMA → sinyal |
| `prediksi_ensemble` | Multi-metode + siklus opsional + kesepakatan |
| `prediksi_siklus` | Benner / Halving / Kondratiev / Juglar |
| `prediksi_backtest` | Walk-forward + return + max DD |
| `prediksi_risiko` | ATR stop, position size, Kelly, R:R |

## 7. Kompatibilitas

- SDK: `>=3.0.0 <4.0.0` (selaras dengan Tiko yang memakai ^3.8)
- Tidak ada dependency runtime eksternal di `prediksi`
- Model `Candle` / `Sinyal` murni Dart — mudah di-serialisasi ke JSON untuk tool I/O
- Sandbox: tool berjalan di proses agent (bukan script sandbox terpisah); aman karena pure compute

## 8. Catatan keamanan & etika

- Skill dan tool harus selalu menyampaikan bahwa hasil adalah **edukasi/analisis**, bukan nasihat investasi.
- Jangan otomatis mengeksekusi trade.
- Data harga nyata harus berasal dari sumber yang user setujui / tool data terpisah.
