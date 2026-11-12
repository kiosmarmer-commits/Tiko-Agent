# Provider Parity Hermes — 12 November 2026

Batch ini menyamakan cakupan provider AI Tiko-Agent dengan Hermes Agent (Nous
Research) yang mendukung 40+ provider melalui 3 transport
(`chat_completions`, `anthropic_messages`, `codex_responses`) plus fitur
credential pool, OAuth, timeout per provider/model, dan model discovery.

## Ringkasan

| Kemampuan | Sebelum | Sesudah |
|-----------|---------|---------|
| Tipe provider | 5 (`mock`, `openai_compat`, `ollama_native`, `anthropic`, `gemini`) | 5 + 3 transport baru (`openai_responses`, `azure_openai`, `bedrock`) + 36 preset katalog |
| Provider preset | Tidak ada (base_url manual) | 36 preset: `type: deepseek` otomatis memakai baseUrl/model/transport preset |
| Credential pool | 1 api_key | `api_key` + `api_keys[]` — rotasi round-robin pada 401/403/429 |
| OAuth | Tidak ada | Device flow RFC 8628 generik (`oauth_device_url` + `oauth_token_url` + `oauth_client_id`) |
| Timeout | Default http | `request_timeout_sec` provider-wide + `model_timeouts` per-model |
| Model discovery | Tidak ada | `tiko models <provider>` → GET `{base}/models` |
| Azure OpenAI | Tidak ada | `AzureOpenAIProvider` — URL deployment + header `api-key` |
| AWS Bedrock | Tidak ada | `BedrockProvider` — SigV4 + Converse API (non-streaming) |
| OpenAI Responses API | Tidak ada | `OpenAiResponsesProvider` — SSE `response.output_text.delta`, function call, usage |

## Katalog preset (37 entri)

`openrouter`, `nous`, `ai_gateway`, `litellm`, `router`, `openai`,
`openai_codex` (transport `responses`), `deepseek`, `anthropic`
(`anthropic_messages`), `gemini`, `azure`, `bedrock`, `groq`, `mistral`,
`xai`, `zai`, `kimi`, `kimi_cn`, `minimax`, `minimax_cn`, `alibaba`,
`tencent`, `xiaomi`, `stepfun`, `together`, `fireworks`, `novita`, `nvidia`,
`nebius`, `huggingface`, `arcee`, `gmi`, `actual`, `opencode_zen`,
`ollama_cloud`, `lmstudio`, `vllm`.

Lookup id case-insensitive dan `-` ≡ `_` (`Kimi-Coding` ≡ `kimi`).
Semua field preset bisa dioverride `base_url`/`model` di config.

**Catatan kejujuran**: baseUrl preset untuk `nous`, `ai_gateway`, `arcee`,
`gmi`, `actual`, `opencode_zen`, `xiaomi`, `tencent` adalah estimasi endpoint
publik dan bisa meleset — selalu bisa dikoreksi via `base_url`.

## Contoh config

```yaml
providers:
  default_chat: deepseek
  chat:
    # Preset: cukup type + api_key; baseUrl/model dari katalog.
    deepseek:
      type: deepseek
      api_key: "env:DEEPSEEK_API_KEY"

    # OpenRouter dengan credential pool + timeout.
    openrouter:
      type: openrouter
      api_key: "env:OPENROUTER_KEY_1"
      api_keys: ["env:OPENROUTER_KEY_2", "env:OPENROUTER_KEY_3"]
      request_timeout_sec: 60
      model_timeouts:
        "anthropic/claude-sonnet-4": 180

    # Azure OpenAI (deployment + api-version).
    azure:
      type: azure_openai
      base_url: "https://RESOURCE.openai.azure.com"
      model: gpt-4o-deploy
      api_key: "env:AZURE_OPENAI_KEY"
      api_version: "2024-10-21"

    # AWS Bedrock (SigV4 + Converse; streaming belum didukung).
    bedrock:
      type: bedrock
      region: us-east-1
      model: anthropic.claude-sonnet-4-20250514-v1:0
      access_key_id: "env:AWS_ACCESS_KEY_ID"
      secret_access_key: "env:AWS_SECRET_ACCESS_KEY"
      # session_token: "env:AWS_SESSION_TOKEN"

    # OAuth device flow (RFC 8628) untuk provider Hermes-parity *-oauth.
    oauth_provider:
      type: openai_compat
      base_url: "https://api.example.com/v1"
      oauth_device_url: "https://auth.example.com/device/code"
      oauth_token_url: "https://auth.example.com/oauth/token"
      oauth_client_id: "client-id"
      oauth_scopes: ["read", "write"]
      oauth_token_cache: "/tmp/tiko-oauth-token.json"
```

## Pemetaan provider Hermes → Tiko

| Provider Hermes | Cara pakai di Tiko |
|-----------------|--------------------|
| openai, deepseek, groq, mistral, xai, zai, kimi(+cn), minimax(+cn), together, fireworks, novita, nvidia, nebius, stepfun, alibaba, qwen, lmstudio, vllm, huggingface, openrouter | `type: <preset-id>` + `api_key` (transport chat_completions otomatis) |
| anthropic | `type: anthropic` atau preset `anthropic` (transport anthropic_messages) |
| gemini | `type: gemini` |
| ollama-cloud | preset `ollama_cloud` |
| openai-codex / codex_responses | preset `openai_codex` atau `type: openai_responses` |
| azure-foundry / Azure OpenAI | `type: azure_openai` |
| bedrock | `type: bedrock` |
| ai-gateway, litellm, router, opencode-zen, arcee, gmi, actual, xiaomi, tencent-tokenhub | preset (baseUrl estimasi, override `base_url` bila perlu) |
| Provider OAuth spesifik Hermes (qwen-oauth, xai-oauth, minimax-oauth, alibaba coding-plan, dll.) | `oauth_device_url`/`oauth_token_url`/`oauth_client_id` per provider (device flow generik RFC 8628, bukan integrasi OAuth proprietary 1:1) |
| Provider lain yang belum ada | `type: openai_compat` + `base_url` arbitrer (OpenAI-compatible) |

## Detail teknis

- **Credential pool** (`credential_pool.dart`): aktif bila ≥2 key valid;
  rotasi round-robin pada HTTP 401/403/429; sticky saat sukses.
- **OAuth device flow** (`oauth_device.dart`): cache memory + file JSON,
  support `refresh_token`, polling dengan `interval` + `slow_down` (+5s).
- **SigV4** (`bedrock_provider.dart`): fungsi murni `awsSigV4Headers(...)`
  testable dengan timestamp tetap; diverifikasi terhadap vektor referensi
  python (hashlib/hmac) yang independen.
- **Responses API** (`openai_responses.dart`): sistem → `instructions`,
  tool call → item `function_call`, hasil tool → `function_call_output`;
  SSE events delta/usage/done; fallback non-streaming.
- **Model discovery**: `tiko models` (tanpa arg → tabel provider) dan
  `tiko models <id>` (GET `{base}/models`, best-effort, hanya
  OpenAI-compatible).
- **Timeout**: fallback `Duration(hours: 1)` pada send/post bila tidak
  dikonfigurasi.

## Status

- CODE + WIRED + TESTED: 44 test agent_providers (preset, pool, rotasi 401,
  Responses API non-stream + SSE, Azure URL/header, SigV4 vector, Converse
  parse) + 13 test tiko_runtime (parse field parity, factory preset/responses/
  azure/bedrock/pool/oauth/timeout).
- Belum VERIFIED live: panggilan nyata ke Azure/Bedrock/OpenAI Responses
  butuh kredensial cloud — belum dijalankan e2e live.
