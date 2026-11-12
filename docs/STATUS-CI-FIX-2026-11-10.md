# Status CI Fix — 10 November 2026

## Baseline rusak

- HEAD saat diagnosis: `396b55d` (P1-09 subagent)
- CI gagal beruntun: runs **#186–#192**
- Last known green terkait SSRF docs: **#185** (`7ae2dd9`) sebelum regresi test/search + commit P1

## Akar penyebab

1. **P0-03** menghapus default SearXNG localhost → test masih mengasumsikan default.
2. **P1-09** memakai `ToolResult.metadata` dan `TikoConfig.allowedTools` yang tidak ada di model/config.
3. **P1-03** menambah `final SkillApi? skillApi` tanpa parameter konstruktor.
4. **P1-04** menaruh `createInboundProcessor` **di luar** class (brace berlebih) → `pushInbound` “undefined”.
5. **P1-07** test memanggil widget privat `_XxxPage`.

## Status setelah bundle

| Item | Status |
|------|--------|
| Source patch di atas | Siap apply |
| CI pada SHA baru | **verification pending** (jalankan validate + push) |
| Laporan audit item P1 “Closes” | Tetap **Implemented — verification pending** sampai Actions hijau |

## Perintah bukti

```bash
dart pub get
cd packages/agent_tools && dart test test/web_search_tavily_test.dart test/subagent_test.dart
cd ../agent_gateway && dart analyze --fatal-warnings
cd ../tiko_runtime && dart analyze --fatal-warnings
cd ../../apps/agent_flutter && flutter analyze && flutter test
cd ../..
bash scripts/validate.sh
bash scripts/flutter_validate.sh
```
