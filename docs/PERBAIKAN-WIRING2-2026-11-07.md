# MANIFEST Perbaikan — Wiring Round 2 (2026-11-07)

Kelanjutan dari `MANIFEST-PERBAIKAN-2026-11-07.md`. Fokus: menghubungkan komponen yang sebelumnya *dead code* / belum tersambung ke runtime, hasil analisis gap pasca-Fase A/B/C.

## File yang diunggah (6 file)

### tiko_runtime/lib/src
| File | Perubahan |
|---|---|
| `tiko_config.dart` | (1) Tipe provider `anthropic` & `gemini` di `knownProviderTypes`. (2) Seksi config baru `decision:` → class `DecisionConfig` (Jev/Laya SystemOne: `enabled=false` default, `base_url`, `model='jev-latest'`, `api_key_ref`, `llm_fallback`) dan `memory.embed:` → `MemoryEmbedConfig` (Ollama embedder, default `nomic-embed-text`). (3) `McpServerConfig` mendukung `type: stdio\|http`, `command` jadi nullable, +`url`, +`header_refs` (SecretRef untuk header HTTP MCP). (4) Validasi: type/url/headers dicek saat parse; `setup.yaml` contoh diperbarui. |
| `provider_factory.dart` | (1) Case `anthropic` → `AnthropicProvider` & `gemini` → `GeminiProvider` (api_key wajib, throw `ArgumentError` bila null). (2) `buildDecision(cfg, fallbackLlm)` → `SystemOneDecisionProvider` bila `decision.enabled`; `LlmJsonDecisionProvider` bila `llm_fallback` + LLM tersedia; null bila keduanya mati. (3) `buildEmbedder(cfg)` → closure `Future<List<double>> Function(String)` untuk SqliteMemoryStore, null bila disabled. |
| `tiko_runtime.dart` | (1) `create()` membangun decision provider & embedder via `ProviderFactory`, embedder diteruskan ke `SqliteMemoryStore.tryOpen`. (2) `WorkspaceCheckpointer` dibuat sekali & disuntik: `PatchFileTool` (auto-checkpoint sebelum menulis), `RollbackTool`, `ListCheckpointsTool`, `CdpBrowserTool` terdaftar di registry. (3) `Router` menerima `decision:` (pertanyaan butuh_tool/berbahaya/kompleksitas kini via Jev, fallback heuristik bila null). (4) `startMcp()` mengekspos `type`, `url` (http), `command` (stdio), header ter-resolve; server dinonaktifkan bila ada SecretRef yang unset. |

### agent_tools/lib/src/mcp
| File | Perubahan |
|---|---|
| `stdio_client.dart` | Interface `McpToolServer` (listTools/callTool/close) diekstrak; `StdioMcpClient implements McpTransport, McpToolServer`; `McpProxyTool` kini menerima `McpToolServer` (tidak lagi terikat stdio). |
| `http_client.dart` | `HttpMcpClient implements McpTransport, McpToolServer` — MCP over HTTP siap dipakai registry. |
| `registry_mcp.dart` | `loadServers` bercabang: `type: http` → `HttpMcpClient` (validasi URL http/https, headers pre-resolved), `stdio` → sandbox seperti semula. `allowed_tools` hanya berlaku untuk stdio. Status +field `transport`. |

## Contoh konfigurasi untuk mengaktifkan fitur baru

```yaml
providers:
  default: openai
  # tipe anthropic / gemini kini dikenali:
  # anthropic:
  #   api_key: "env:ANTHROPIC_API_KEY"
  #   model: "claude-sonnet-4-20250514"

decision:                      # Jev/Laya (T1)
  enabled: true
  base_url: "https://api.typesafe.ai"
  model: "jev-latest"
  api_key: "env:JEV_API_KEY"
  llm_fallback: true           # pakai LLM default bila Jev gagal

memory:
  embed:                       # embedding lokal via Ollama
    enabled: true
    base_url: "http://localhost:11434"
    model: "nomic-embed-text"

mcp:
  servers:
    - id: context7
      type: http               # BARU: transport http
      url: "https://mcp.context7.com/mcp"
      header_refs:
        Authorization: "env:CONTEXT7_TOKEN"
      allow: ["tools"]
      risk: medium
```

## 🔴 Hapus manual di Google Drive (duplikat versi lama)

`create_file` selalu membuat file baru (update API 403), jadi versi lama harus dihapus manual:
1. **tiko_runtime.dart** — kini ada **3 versi** (asli + v1 sesi lalu + v2 ini). Simpan yang terbaru (diunggah 2026-11-07 terakhir).
2. **tiko_config.dart, provider_factory.dart, stdio_client.dart, http_client.dart, registry_mcp.dart** — masing-masing kini punya 2 versi.
3. File test sisa sesi awal di folder root: `test-pipeline` (Google Doc) + `test-dart.dart`.

## Di-defer (dokumentasi desain ada di laporan P1)
- Voice loop orkestrasi penuh (STT→LLM→TTS streaming kontinu), dataset evaluasi 50 kalimat, reranker memori.
- Webhook server WhatsApp/Slack (gateway sudah ada; butuh HTTP listener terpisah), HMAC verify (butuh `package:crypto`).
- Subagent runner wiring di runtime, idempotency key (A4), cron IANA/DST (butuh `package:timezone`).

## Verifikasi wajib
```bash
dart pub get
bash scripts/validate.sh
bash scripts/flutter_validate.sh
```
Kode diverifikasi statis saja (tanpa Dart SDK di lingkungan kerja). Bila ada error compiler, laporkan dan akan diperbaiki di revisi berikutnya.
