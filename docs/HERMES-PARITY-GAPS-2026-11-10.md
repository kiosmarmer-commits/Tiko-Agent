# Paritas Hermes — Penutupan Gap Utama: 10 November 2026

**Status:** Implemented (kode + unit test). Dart/Flutter SDK tidak tersedia di lingkungan penyusunan; validasi penuh ditunggu pada CI.

Dokumen ini mendeskripsikan implementasi tiga gap terbesar hasil perbandingan dengan Hermes Agent: plugins system + memory providers eksternal, prompt caching, dan API server OpenAI-compatible + ACP IDE integration.

## 1. Plugins System

**Modul:** `packages/agent_core/lib/src/plugin_system.dart`
**Test:** `packages/agent_core/test/plugin_system_test.dart`

Tiga tipe plugin ala Hermes, semua tanpa dependency baru:

- **General plugins** — `Plugin` dengan hook lifecycle: `beforeToolCall` (veto via `HookVerdict.deny` atau rewrite args via `HookVerdict.modify`), `afterToolCall`, `onSessionStart/End`, `onMessage`. `PluginRegistry` menjalankan hook berurutan; **plugin pertama yang menolak menang**; exception plugin terisolasi dan tercatat sebagai `PluginEvent` — loop agent tidak pernah mati karena plugin.
- **Memory providers** — kontrak `MemoryProvider` (`upsert`/`search`/`forget` + `MemoryRecord`), diimplementasi adapter eksternal di `agent_memory` (lihat §2).
- **Context engines** — kontrak `ContextEngine.buildContext()` untuk strategi perakitan konteks alternatif.

Registrasi nama sama menggantikan instance lama (dispose dipanggil). Pemakaian:

```dart
final plugins = PluginRegistry();
await plugins.register(MyGuardPlugin());
final verdict = await plugins.dispatchBeforeToolCall(
    ToolHookInput(toolName: 'shell', args: cmd, sessionId: sid));
if (!verdict.allowed) return; // veto
```

## 2. Memory Providers Eksternal

**Modul:** `packages/agent_memory/lib/src/memory_providers.dart`
**Test:** `packages/agent_memory/test/memory_providers_test.dart`

- `HttpMemoryProvider` — adapter REST untuk backend eksternal (RetainDB/ByteRover/Mem0-style atau self-hosted): `POST /memories`, `POST /memories/search`, `DELETE /memories/{id}`; auth Bearer opsional; retry dengan delay linear; memakai `dart:io HttpClient` (tanpa dependency baru).
- `MemoryProviderRouter` — write fan-out ke store lokal + semua provider eksternal; read merge dengan bobot per-provider (`weights`), dedupe by (owner, text) mempertahankan skor tertinggi; policy `interleave` atau `fallback` (pakai lokal sampai hit < threshold).
- **Prinsip degradasi:** kegagalan satu provider tidak menghentikan retrieval; error hanya dilempar bila semua provider gagal.
- Test memakai stub server HTTP loopback nyata (port ephemeral).

## 3. Prompt Caching

**Modul:** `packages/agent_providers/lib/src/prompt_cache.dart`
**Test:** `packages/agent_providers/test/prompt_cache_test.dart`
**Integrasi:** `AnthropicProvider(promptCache: ...)` di `anthropic_compat.dart`

- `PromptCacheManager` — melacak prefix stabil (model + system prompt + toolset hash) lintas sesi dengan TTL 1 jam, eviksi LRU di `maxEntries`, statistik hit/miss/eviction (`PromptCacheStats`). Prefix pendek (< `minPrefixChars`) tidak di-cache.
- `AnthropicCacheBreaker` — membangun blok `system` Anthropic dengan `cache_control: {"type": "ephemeral"}`; prompt panjang dipecah maksimal 4 breakpoint (batas provider) pada batas paragraf sehingga pertumbuhan prefix hanya meng-invalidate blok ekor.
- `estimatedSavings()` — estimasi hemat biaya dengan faktor cache-read 0.1.
- `AnthropicProvider` otomatis memasang breakpoint saat `promptCache` disuntik; tanpa injeksi, perilaku tidak berubah.

## 4. API Server OpenAI-Compatible

**Modul:** `packages/agent_tools/lib/src/openai_api.dart`
**Test:** `packages/agent_tools/test/openai_api_test.dart`

- `POST /v1/chat/completions` — format wire OpenAI penuh: non-streaming (`chat.completion` + `usage`) dan streaming SSE (`chat.completion.chunk` + `data: [DONE]`).
- `GET /v1/models` — daftar model `{"object": "list"}`.
- `GET /health` — tanpa auth; route lain wajib `Authorization: Bearer`.
- Error mengikuti format OpenAI (`error.type`: `authentication_error`, `invalid_request_error`, `server_error`).
- Handler agent disuntik (`OpenAiChatHandler`), default bind `127.0.0.1`, port ephemeral didukung (`port: 0`). Kompatibel dengan Open WebUI/LobeChat/LibreChat.

## 5. ACP IDE Integration

**Modul:** `packages/agent_tools/lib/src/acp_agent.dart`
**Test:** `packages/agent_tools/test/acp_agent_test.dart`

Agent-side Agent Client Protocol (JSON-RPC 2.0, ndjson over stdio) — protokol yang sama dipakai Zed/VS Code/JetBrains:

| Method | Perilaku |
|---|---|
| `initialize` | `protocolVersion`, `agentCapabilities`, `agentInfo` |
| `session/new` | session id baru |
| `session/prompt` | menjalankan handler, streaming `session/update` (`agent_message_chunk`), hasil `{stopReason: end_turn}` |
| `session/cancel` | menandai sesi cancel → `stopReason: cancelled` |
| `session/load` | error `-32601` (belum didukung) |

Prompt diterima sebagai `ContentBlock[]` (blok `text` digabung) atau string polos. Kegagalan handler menghasilkan `stopReason: error` + update `error`, bukan crash protokol. I/O bisa diinjeksi (stdin/stdout di produksi, StreamController di test).

## Cakupan dan batasan

- Modul berdiri sendiri dengan injection mengikuti pola repo; wiring penuh ke `TikoRuntime` (mendaftarkan plugin dari config, menjalankan `OpenAiCompatServer`/`AcpAgent` dari daemon) adalah langkah lanjutan yang tidak mengubah kontrak publik.
- ACP: belum mendukung `fs/*` client-side methods dan permission requests; cukup untuk chat + streaming chunk.
- Prompt cache: marker Anthropic-style; provider lain mengabaikan blok cache (fallback aman).
