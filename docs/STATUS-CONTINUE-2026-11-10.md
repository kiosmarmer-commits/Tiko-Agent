# Status lanjut perbaikan — 10 Nov 2026 (malam)

## HEAD

- `main` = `05576ac` (force/squash “fix bug”)
- Actions UI terakhir yang terlihat: gagal di `396b55d` (#192)
- **Belum ada run CI publik untuk `05576ac`** → P0-01 masih *verification pending*

## Sudah di source (compile CI breakers)

| Item | State |
|------|--------|
| ToolResult.metadata | fixed |
| TikoConfig.allowedTools | fixed |
| skillApi ctor | fixed |
| EmailGateway createInboundProcessor brace | fixed |
| EmailGateway test host | fixed |
| admin_ui private widgets | fixed |
| web_search explicit base URL | fixed |

## Lanjutan di patch ini (P1-09 nyata)

| Item | State |
|------|--------|
| Subagent allowlist hanya “komentar” | **Diperbaiki**: `_AllowlistToolGate` |
| Budget subagent tidak masuk AgentConfig | **Diperbaiki**: `configOverride` (maxTokens/time/toolCalls) |
| `chatWithStatus` tidak bisa override gate/config | **Diperbaiki**: parameter opsional |

## Masih terbuka (prioritas)

1. **P0-01** — push commit baru agar Actions jalan; `validate.sh` + `flutter_validate.sh` hijau
2. **P0-03** — uji MCP HTTP + SSRF dengan server nyata / fixture
3. **P0-04** — e2e delivery ACK + DLQ recovery
4. Filter **tool specs** di context subagent (model masih bisa *melihat* semua tool; gate menolak eksekusi)
5. P1-02 MCP lifecycle, P1-08 Android, P2 OAuth

## Cara apply patch lanjut

```bash
cd Tiko-Agent
bash scripts/from-bundle/apply_continue.sh .   # atau salin file dari zip
dart pub get && bash scripts/validate.sh && bash scripts/flutter_validate.sh
git add -A && git commit -m "fix(p1-09): enforce subagent allowlist + budget via chatWithStatus overrides"
git push
```
