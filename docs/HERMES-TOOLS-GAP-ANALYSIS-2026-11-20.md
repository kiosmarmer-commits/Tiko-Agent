# Analisis Gap Tools Hermes vs Tiko-Agent

**Tanggal:** 2026-11-20  
**Sumber Hermes:** [hermestools](https://raw.githubusercontent.com/kiosmarmer-commits/rustic/refs/heads/main/hermestools) (ringkasan provider resmi Hermes Agent / Nous Research per 19 Nov 2026)  
**Sumber Tiko:** `main` Tiko-Agent (`packages/agent_tools`, `packages/agent_providers`, `packages/agent_gateway`, `packages/agent_memory`, sandbox)

## Ringkasan eksekutif

| Kategori | Hermes (resmi) | Tiko-Agent | Status |
|---|---|---|---|
| Web Search providers | 11+ (Firecrawl, SearXNG, Brave, DDGS, Exa, Parallel, Tavily, Perplexity, Keenable, xAI, OpenAI Codex, Nous Portal) | SearXNG, Tavily, DDGS, Brave, Exa, Firecrawl, **Parallel (baru)**, Perplexity, Keenable, xAI, OpenAI Codex, Nous Portal | ✅ Paritas provider utama |
| Browser automation | Local CDP, Browserbase, Browser Use, Firecrawl, Lightpanda | Local CDP, Browserbase, Browser Use, Firecrawl cloud | ✅ ~95% |
| Code / terminal sandbox | Local, Docker, SSH, Modal, Daytona, Vercel, Singularity, Sprites | `SandboxKind`: none, bubblewrap, docker, ssh, modal, daytona, vercel, singularity, sprites | ✅ Paritas backend |
| Image generation | FAL, OpenAI, xAI, Krea, DeepInfra, OpenRouter, Meta, ComfyUI | FAL, OpenAI, xAI, Krea, DeepInfra, OpenRouter, Meta, ComfyUI | ✅ |
| Video generation | xAI, FAL, OpenRouter, DeepInfra | xAI, FAL, OpenRouter, DeepInfra | ✅ |
| TTS / STT | 11 TTS + multi STT (Edge, ElevenLabs, OpenAI, MiniMax, Mistral, Gemini, xAI, DeepInfra, local…) | Multi-provider TTS (HTTP template + Edge/Piper CLI) + Discord voice STT/TTS loop | ⚠️ Sebagian; provider cloud TTS/STT lebih sempit dari Hermes |
| Messaging channels | 20+ (Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Teams, LINE, …) | Telegram, Discord, Slack, WhatsApp, Email, webhook | ⚠️ Core populer ada; Signal/Matrix/Teams/LINE/dll belum |
| Memory external | RetainDB, ByteRover + plugin (Honcho, Mem0-style, …) | Layered memory lokal + adapter REST eksternal (RetainDB/ByteRover/Mem0-style) | ✅ Infrastruktur siap; adapter spesifik cloud opsional |
| MCP | Katalog resmi (deepwiki, linear, github, …) | MCP stdio + Streamable HTTP; deepwiki/linear/github loaders | ✅ |
| LLM providers | Lusinan (Nous Portal, OpenAI, Anthropic, Gemini, Bedrock, Azure, HF, Ollama, Mistral, Kimi, MiniMax, …) | OpenAI-compat, Anthropic, Gemini, Ollama + circuit breaker / tiers | ⚠️ Core kuat; daftar enterprise (Bedrock/Azure/HF native) lebih sempit |

## Detail: Web Search (fokus implementasi kali ini)

### Sudah ada di Tiko sebelum patch

- SearXNG (self-host)
- Tavily
- DDGS (DuckDuckGo, tanpa key)
- Brave Search
- Exa
- Firecrawl
- Perplexity
- Keenable
- xAI (Grok) Search
- OpenAI Codex Search
- Nous Portal Tool Gateway

### Gap yang ditutup (2026-11-20)

| Provider | Status sebelumnya | Perubahan |
|---|---|---|
| **Parallel Search** (`PARALLEL_API_KEY`, `https://api.parallel.ai/v1/search`) | ❌ Belum ada | ✅ Ditambahkan di `WebSearchTool`: field `parallelApiKey` / `parallelBaseUrl`, urutan fallback setelah Firecrawl, `_searchParallel`, wiring di `createBuiltinTools` |

### Catatan integrasi Parallel

- Mode default: `fast`
- Body: `objective` + `search_queries` (satu query agent → objective & keyword list)
- Header: `x-api-key`
- Parsing hasil toleran terhadap `results` / `data` dan field `excerpts` / `content` / `snippet`
- SSRF guard pada base URL; fallback eligible pada 5xx/429

### Wiring kunci yang dilengkapi

`createBuiltinTools` kini juga meneruskan `braveApiKey`, `exaApiKey`, `firecrawlApiKey`, dan `parallelApiKey` ke `WebSearchTool` (sebelumnya beberapa key hanya di constructor class, belum di factory builtin).

## Yang masih gap (prioritas saran)

1. **TTS/STT breadth** — samakan daftar provider cloud Hermes (ElevenLabs, MiniMax, Mistral Voxtral, Groq Whisper, dll.) di layer voice runtime.
2. **Messaging** — Signal, Matrix, Microsoft Teams, LINE, Mattermost, dll. (gateway package).
3. **LLM enterprise adapters** — AWS Bedrock, Azure AI Foundry, Hugging Face Inference native (bukan hanya OpenAI-compat).
4. **Memory cloud first-party** — adapter khusus RetainDB/ByteRover di luar REST generik (jika API berbeda).
5. **RL / Atropos pipeline** — di luar scope tools; effort tinggi (sudah dicatat di dokumen perbandingan sebelumnya).

## File diubah

- `packages/agent_tools/lib/src/web_search.dart` — provider Parallel
- `packages/agent_tools/lib/src/builtin.dart` — wiring API keys search
- `docs/HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md` — dokumen ini

## Verifikasi yang disarankan

```bash
dart analyze packages/agent_tools
dart test packages/agent_tools
# Smoke: set PARALLEL_API_KEY lalu panggil tool web_search
```

## Referensi

- Hermes tools inventory: `https://raw.githubusercontent.com/kiosmarmer-commits/rustic/refs/heads/main/hermestools`
- Parallel Search API: `https://docs.parallel.ai/search/search-quickstart`
- Tiko `WebSearchTool` fallback chain di `web_search.dart`
