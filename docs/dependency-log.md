# Dependency verification log

Tanggal: 2026-11-04 (sesi implementasi M0)

## Hasil pencarian web (bukan skrip pub.dev langsung)

| Paket | Versi di AGD-08 | Versi terbaru ditemukan | Catatan |
|-------|-----------------|-------------------------|---------|
| openai_dart | 11.0.1 | 11.0.1 | ✅ MIT, davidmiguel.com |
| ollama_dart | 4.0.0 | 4.0.0 | ✅ termasuk System One decisions |
| anthropic_sdk_dart | 9.0.0 | (tidak dicek ulang) | — |
| googleai_dart | 13.0.0 | (tidak dicek ulang) | — |
| dart_mcp | 0.4.1 | 0.5.2 (pub), GitHub support 2026-07-28 | ✅ aktif; stdio masih negotiate ≤2025-11-25 |
| mcp_dart (komunitas) | — | 2.4.3 | Alternatif yang klaim full 2026-07-28 |
| drift | 2.32.0 | **2.35.3** | Naikkan saat TASK-04-01 |
| televerse | 3.3.0 | **3.6.0** | Bot API 10.2 |
| nyxx | 6.8.1 | (tidak dicek) | — |
| Ollama | 0.40.6 | aktif | MIT |

## MCP 2026-07-28

- Spec resmi: stateless, tanpa handshake `initialize`, request membawa protocol version di `_meta`.
- `dart_mcp` (dart-lang): mendukung versi di GitHub; Streamable HTTP untuk 2026-07-28, stdio masih handshake lama.
- Strategi tetap DEC-06: mulai stdio + interface `McpTransport`.

## Laya / Jev

- Laya: Apache-2.0, `pip install laya`, checkpoint multilingual + typed-decisions, kompatibel bentuk `/v1/systemone`.
- Jev: proprietary hosted TypeSafe AI.
- Akurasi ID masih perlu uji sendiri (TASK-02-05).

## Tindakan

1. Pin versi di `pubspec.lock` setelah `dart pub get` di mesin target.
2. Update AGD-08 kolom drift & televerse saat M1/M2.
3. Jalankan `scripts/verify_deps.py` di mesin yang punya internet + Python.
