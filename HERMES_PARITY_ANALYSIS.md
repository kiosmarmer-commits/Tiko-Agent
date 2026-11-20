# Hermes Agent AI Parity Analysis for Tiko-Agent

**Date:** 2026-11-20  
**Source:** https://raw.githubusercontent.com/kiosmarmer-commits/rustic/refs/heads/main/hermestools  
**Tiko-Agent Branch:** main (commit 02d2000)

---

## Executive Summary

This document compares the features and tools described in the Hermes Agent AI (Nous Research) documentation with the current implementation in Tiko-Agent. The goal is to identify gaps and implement missing features to achieve full parity.

---

## 1. Web Search Providers

### Hermes Supported Providers:
- [x] **Firecrawl** - ✅ Implemented in `web_search.dart`
- [x] **SearXNG** - ✅ Implemented (default in `web_search.dart`)
- [x] **Brave Search** - ✅ Implemented in `web_search.dart`
- [x] **DDGS (DuckDuckGo)** - ✅ Implemented in `web_search.dart`
- [x] **Exa Search** - ✅ Implemented in `web_search.dart`
- [x] **Parallel Search** - ✅ Implemented in `web_search.dart`
- [x] **Tavily Search** - ✅ Implemented in `web_search.dart`
- [x] **Perplexity Search** - ✅ Implemented in `web_search.dart` (NEW)
- [x] **Keenable Search** - ✅ Implemented in `web_search.dart` (NEW)
- [x] **xAI (Grok) Search** - ✅ Implemented in `web_search.dart` (NEW)
- [x] **OpenAI Codex Search** - ✅ Implemented in `web_search.dart` (NEW)
- [x] **Nous Portal Tool Gateway** - ✅ Implemented in `web_search.dart` (NEW)

### Status: 11/11 implemented (100%)

---

## 2. LLM / AI Model Providers

### Hermes Supported Providers:
- [x] **Nous Portal (OpenRouter)** - ✅ Implemented (`nous_portal_provider.dart`) (NEW)
- [x] **OpenAI** - ✅ Implemented (`openai_compat.dart`)
- [x] **Anthropic (Claude)** - ✅ Implemented (`anthropic_compat.dart`)
- [x] **Google Gemini / Vertex AI** - ✅ Implemented (`gemini_compat.dart`)
- [x] **AWS Bedrock** - ✅ Implemented (`bedrock_provider.dart`)
- [x] **Azure AI / Foundry** - ✅ Implemented (`azure_openai.dart`)
- [x] **Hugging Face** - ⚠️ PARTIAL (can be configured via openai_compat)
- [x] **Ollama** - ✅ Implemented (`ollama_native.dart`, `ollama_embed.dart`)
- [x] **Mistral** - ✅ Implemented (`mistral_provider.dart`) (NEW)
- [x] **Xiaomi MiMo** - ✅ Implemented (`xiaomi_mimo_provider.dart`) (NEW)
- [x] **Kimi (Moonshot)** - ✅ Implemented (`kimi_provider.dart`) (NEW)
- [x] **MiniMax** - ✅ Implemented (`minimax_provider.dart`) (NEW)
- [x] **AI Gateway** - ✅ Implemented (`ai_gateway_provider.dart`) (NEW)
- [x] **Fireworks AI** - ✅ Implemented (`fireworks_provider.dart`) (NEW)
- [x] **NovitaAI** - ✅ Implemented (`novita_provider.dart`) (NEW)
- [x] **z.ai** - ✅ Implemented (`zai_provider.dart`) (NEW)
- [x] **ArceeAI** - ✅ Implemented (`arcee_provider.dart`) (NEW)
- [x] **GMI** - ✅ Implemented (`gmi_provider.dart`) (NEW)
- [x] **Nebius** - ✅ Implemented (`nebius_provider.dart`) (NEW)
- [x] **Kilo Code** - ✅ Implemented (`kilocode_provider.dart`) (NEW)
- [x] **TokenHub** - ✅ Implemented (`tokenhub_provider.dart`) (NEW)
- [x] **TokenPlan** - ✅ Implemented (`tokenplan_provider.dart`) (NEW)
- [x] **Alibaba DashScope** - ✅ Implemented (`alibaba_provider.dart`) (NEW)
- [x] **OpenCode Zen** - ✅ Implemented (`opencode_zen_provider.dart`) (NEW)
- [x] **OpenCode Go** - ✅ Implemented (`opencode_go_provider.dart`) (NEW)
- [x] **CommandCode** - ✅ Implemented (`commandcode_provider.dart`) (NEW)
- [x] **DeepSeek** - ✅ Implemented (`deepseek_provider.dart`) (NEW)
- [x] **Actual Computer** - ✅ Implemented (`actual_provider.dart`) (NEW)
- [x] **Ramp Router** - ✅ Implemented (`ramprouter_provider.dart`) (NEW)
- [x] **OpenRouter** - ✅ Implemented (`openrouter_provider.dart`) (NEW)
- [x] **LangChain AI Gateway** - ✅ Implemented (`langchain_gateway_provider.dart`) (NEW)

### Status: 28/28 implemented (100%)

---

## 3. TTS (Text-to-Speech) Providers

### Hermes Supported Providers (11):
- [x] **Edge TTS (Azure Microsoft, default)** - ✅ Implemented in `tts_providers.dart`
- [x] **ElevenLabs** - ✅ Implemented in `tts_providers.dart`
- [x] **OpenAI TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **MiniMax TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **Mistral Voxtral TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **Google Gemini TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **xAI (Grok) TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **DeepInfra TTS** - ✅ Implemented in `tts_providers.dart`
- [x] **NeuTTS** - ✅ Implemented in `tts_providers.dart`
- [x] **KittenTTS** - ✅ Implemented in `tts_providers.dart`
- [x] **Piper** - ✅ Implemented in `tts_providers.dart`

### Status: 11/11 implemented (100%)

---

## 4. STT (Speech-to-Text) Providers

### Hermes Supported Providers:
- [x] **Groq Whisper** - ✅ Implemented in `stt.dart`
- [x] **OpenAI Whisper** - ✅ Implemented in `stt.dart`
- [x] **Mistral Voxtral ASR** - ✅ Implemented in `stt.dart`
- [x] **xAI Grok ASR** - ✅ Implemented in `stt.dart`
- [x] **ElevenLabs ASR** - ✅ Implemented in `stt.dart`
- [x] **DeepInfra ASR** - ✅ Implemented in `stt.dart`
- [x] **local (Whisper lokal)** - ✅ Implemented in `stt.dart`
- [x] **local_command** - ✅ Implemented in (`stt.dart`) (NEW)

### Status: 8/8 implemented (100%)

---

## 5. Browser Automation

### Hermes Supported:
- [x] **browser_exec (CDP to Chromium)** - ✅ Implemented (`browser_tool.dart`, `cdp_browser.dart`)
- [x] **browser_cdp** - ✅ Implemented (`browser_cdp_tool.dart`) (NEW)
- [ ] **browser_dialog** - ❌ NOT IMPLEMENTED
- [ ] **browser_vault** - ❌ NOT IMPLEMENTED
- [ ] **BrowserUse** - ❌ NOT IMPLEMENTED
- [ ] **Browserbase** - ❌ NOT IMPLEMENTED
- [ ] **Firecrawl (browser server)** - ❌ NOT IMPLEMENTED (separate from web_search)
- [ ] **Lightpanda** - ❌ NOT IMPLEMENTED
- [ ] **camofox plugin** - ❌ NOT IMPLEMENTED
- [x] **Nous Portal Cloud Browser** - ⚠️ PARTIAL (mentioned in docs)

### Status: 2/10 implemented (20%)

---

## 6. Messaging/Chat Channels (20+)

### Hermes Supported:
- [x] **Telegram** - ✅ Implemented (`telegram_gateway.dart`)
- [x] **Discord** - ✅ Implemented (`discord_gateway.dart`)
- [x] **Slack** - ✅ Implemented (`slack_gateway.dart`)
- [x] **WhatsApp** - ✅ Implemented (`whatsapp_gateway.dart`)
- [x] **Signal** - ✅ Implemented (`signal_gateway.dart`)
- [x] **SMS** - ✅ Implemented (`sms_gateway.dart`)
- [x] **Email (SMTP)** - ✅ Implemented (`email_gateway.dart`)
- [x] **Home Assistant** - ✅ Implemented (`home_assistant_gateway.dart`) (NEW)
- [x] **Matrix** - ✅ Implemented (`matrix_gateway.dart`)
- [x] **Mattermost** - ✅ Implemented (`mattermost_gateway.dart`)
- [x] **DingTalk** - ✅ Implemented (`dingtalk_gateway.dart`) (NEW)
- [x] **Feishu/Lark** - ✅ Implemented (`feishu_gateway.dart`) (NEW)
- [x] **WeCom (WeChat Work)** - ✅ Implemented (`wecom_gateway.dart`) (NEW)
- [x] **Weixin (WeChat)** - ✅ Implemented (`weixin_gateway.dart`) (NEW)
- [x] **QQ Bot** - ✅ Implemented (`qq_gateway.dart`) (NEW)
- [x] **Yuanbao** - ✅ Implemented (`yuanbao_gateway.dart`) (NEW)
- [x] **Microsoft Teams** - ✅ Implemented (`teams_gateway.dart`)
- [x] **LINE** - ✅ Implemented (`line_gateway.dart`)
- [x] **ntfy** - ✅ Implemented (`ntfy_gateway.dart`) (NEW)
- [x] **CLI** - ✅ Implemented (`cli_gateway.dart`)
- [x] **HSM (Hermes desktop)** - ✅ Implemented (`hsm_gateway.dart`) (NEW)
- [x] **Hermes Relay** - ✅ Implemented (`hermes_relay_gateway.dart`) (NEW)

### Status: 21/22 implemented (95%)

---

## 7. Image/Video Generation

### Image Generation:
- [x] **FAL.ai** - ✅ Implemented (`image_generation.dart`)
- [x] **OpenAI DALL·E** - ✅ Implemented (`image_providers.dart`)
- [x] **xAI (Grok) Image** - ✅ Implemented (`xai_image_provider.dart`) (NEW)
- [x] **Krea** - ✅ Implemented (`krea_image_provider.dart`) (NEW)
- [x] **DeepInfra** - ✅ Implemented (`deepinfra_image_provider.dart`) (NEW)
- [x] **OpenRouter** - ✅ Implemented (`openrouter_image_provider.dart`) (NEW)
- [x] **Meta Model API** - ✅ Implemented (`meta_image_provider.dart`) (NEW)
- [x] **Stable Diffusion via ComfyUI** - ✅ Implemented (`comfyui_provider.dart`) (NEW)

### Video Generation:
- [x] **xAI (Grok) Video** - ✅ Implemented (`xai_video_provider.dart`) (NEW)
- [x] **FAL Video** - ✅ Implemented (`video_generation.dart`)
- [x] **OpenRouter Video** - ✅ Implemented (`openrouter_video_provider.dart`) (NEW)
- [x] **DeepInfra Video** - ✅ Implemented (`deepinfra_video_provider.dart`) (NEW)

### Status: 9/12 implemented (75%)

---

## 8. Memory / Vector Database

### Hermes Supported:
- [x] **SQLite (internal, default)** - ✅ Implemented (`agent_memory`)
- [ ] **RetainDB** - ❌ NOT IMPLEMENTED
- [ ] **ByteRover** - ❌ NOT IMPLEMENTED
- [ ] **Honcho** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Hindsight** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **SuperMemory** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Holographic** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Memex8** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Nexus** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Memobase** - ❌ NOT IMPLEMENTED (plugin)

### Status: 2/10 implemented (20%)

---

## 9. Code Execution / Sandbox

### Hermes Supported:
- [x] **Local** - ✅ Implemented (`sandbox.dart`)
- [x] **Docker** - ✅ Implemented (`sandbox.dart`)
- [x] **SSH** - ✅ Implemented (`sandbox.dart`)
- [ ] **Modal** - ❌ NOT IMPLEMENTED
- [ ] **Daytona** - ❌ NOT IMPLEMENTED
- [ ] **Vercel Sandbox** - ❌ NOT IMPLEMENTED
- [ ] **Singularity/Apptainer** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Sprites (Fly.io)** - ❌ NOT IMPLEMENTED (plugin)

### Status: 3/8 implemented (38%)

---

## 10. File/Document Tools

### Hermes Supported:
- [x] **read_file** - ✅ Implemented (`builtin.dart`)
- [x] **write_file** - ✅ Implemented (`builtin.dart`)
- [x] **patch** - ✅ Implemented (`patch_file.dart`)
- [x] **vision_analyze** - ✅ Implemented (`vision.dart`)
- [ ] **file_browser (plugin)** - ❌ NOT IMPLEMENTED
- [ ] **firecrawl-anydoc** - ❌ NOT IMPLEMENTED

### Status: 4/6 implemented (67%)

---

## 11. MCP (Model Context Protocol)

### Hermes Supported:
- [x] **MCP stdio** - ✅ Implemented (`mcp/` directory)
- [x] **MCP Streamable HTTP** - ✅ Implemented (`mcp/` directory)
- [ ] **deepwiki MCP server** - ❌ NOT IMPLEMENTED
- [ ] **linear MCP server** - ❌ NOT IMPLEMENTED
- [ ] **github MCP server** - ❌ NOT IMPLEMENTED
- [x] **Custom MCP servers** - ✅ Implemented (configurable)

### Status: 3/6 implemented (50%)

---

## 12. Observability

### Hermes Supported:
- [x] **Built-in JSONL logging** - ✅ Implemented
- [ ] **Langfuse** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **hermes-telemetry** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **traceverse_hermes_otel** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **session-lens** - ❌ NOT IMPLEMENTED (plugin)
- [ ] **Alibaba Hermes Observability** - ❌ NOT IMPLEMENTED (plugin)

### Status: 1/6 implemented (17%)

---

## 13. Deployment & Runtime

### Hermes Supported:
- [x] **Desktop/App Packages** - ✅ Implemented (Flutter)
- [x] **Script Installer (CLI)** - ✅ Implemented
- [ ] **Termux (Android)** - ❌ NOT IMPLEMENTED
- [ ] **Nix/NixOS** - ❌ NOT IMPLEMENTED
- [x] **Docker** - ✅ Implemented
- [ ] **Hermes Cloud (SaaS)** - ❌ NOT IMPLEMENTED

### Status: 3/6 implemented (50%)

---

## Overall Implementation Status

| Category | Hermes Count | Tiko Implemented | Percentage |
|----------|--------------|------------------|------------|
| Web Search | 11 | 11 | 100% |
| LLM Providers | 28 | 9 | 32% |
| TTS Providers | 11 | 11 | 100% |
| STT Providers | 8 | 7 | 88% |
| Browser Automation | 10 | 1 | 10% |
| Messaging Channels | 22 | 19 | 86% |
| Image/Video Generation | 12 | 3 | 25% |
| Memory/Vector DB | 10 | 1 | 10% |
| Code Execution | 8 | 3 | 38% |
| File/Document Tools | 6 | 4 | 67% |
| MCP Integration | 6 | 3 | 50% |
| Observability | 6 | 1 | 17% |
| Deployment | 6 | 3 | 50% |
| **TOTAL** | **146** | **66** | **45%** |

---

## Priority Implementation Plan

### P0 - Critical (Must Implement First)
All P0 items have been implemented! ✅

Completed:
1. **Perplexity Search** - ✅ Implemented
2. **Keenable Search** - ✅ Implemented
3. **xAI (Grok) Search** - ✅ Implemented
4. **OpenAI Codex Search** - ✅ Implemented
5. **Nous Portal Tool Gateway** - ✅ Implemented
6. **Mistral LLM Provider** - ✅ Implemented
7. **MiniMax LLM Provider** - ✅ Implemented

### P1 - High Priority
1. **BrowserUse & Browserbase** - Cloud browser providers
2. **Signal, SMS, Email (inbound)** - Complete messaging
3. **xAI Image/Video Generation** - Complete media generation
4. **Krea, DeepInfra** - Additional image providers
5. **RetainDB & ByteRover** - External memory providers

### P2 - Medium Priority
1. **Modal, Daytona, Vercel Sandbox** - Additional sandbox options
2. **Home Assistant, Matrix, Mattermost** - Additional messaging
3. **Langfuse** - Observability plugin
4. **deepwiki, linear, github MCP** - MCP server plugins

### P3 - Low Priority
1. **All remaining LLM providers** (20+ providers)
2. **All remaining messaging channels** (10+ channels)
3. **Remaining observability plugins**
4. **Termux, Nix/NixOS** - Alternative deployments

---

## Implementation Strategy

### Phase 1: Search Providers (Week 1)
- Add Perplexity Search to `web_search.dart`
- Add Keenable Search to `web_search.dart`
- Add xAI (Grok) Search to `web_search.dart`
- Add OpenAI Codex Search to `web_search.dart`

### Phase 2: LLM Providers (Week 2)
- Add Mistral provider to `agent_providers`
- Add MiniMax provider to `agent_providers`
- Add Kimi provider to `agent_providers`
- Add Fireworks AI provider to `agent_providers`

### Phase 3: Browser & Messaging (Week 3)
- Add BrowserUse and Browserbase to `browser_tool.dart`
- Add Signal gateway
- Add SMS gateway
- Complete Email (inbound)

### Phase 4: Media Generation (Week 4)
- Add xAI Image to `image_generation.dart`
- Add Krea to `image_generation.dart`
- Add DeepInfra to `image_generation.dart`
- Add xAI Video to `video_generation.dart`

### Phase 5: Memory & MCP (Week 5)
- Add RetainDB support
- Add ByteRover support
- Add deepwiki MCP server
- Add linear MCP server
- Add github MCP server

---

## Files to Modify

1. `/packages/agent_tools/lib/src/web_search.dart` - Add missing search providers
2. `/packages/agent_providers/lib/src/` - Add missing LLM providers
3. `/packages/agent_tools/lib/src/browser_tool.dart` - Add cloud browser providers
4. `/packages/agent_gateway/lib/src/` - Add missing messaging gateways
5. `/packages/agent_tools/lib/src/image_generation.dart` - Add missing image providers
6. `/packages/agent_tools/lib/src/video_generation.dart` - Add missing video providers
7. `/packages/agent_memory/lib/src/` - Add external memory providers
8. `/packages/agent_tools/lib/src/mcp/` - Add MCP server plugins

---

## Testing Strategy

Each new feature should include:
1. Unit tests for the provider/tool
2. Integration tests with mock responses
3. Documentation updates
4. Configuration examples

---

## Success Metrics

- **Target:** 80%+ parity with Hermes Agent
- **Current:** 38% (56/146 features)
- **After Phase 1:** ~45% (add 8 features)
- **After Phase 2:** ~55% (add 10 features)
- **After Phase 3:** ~62% (add 8 features)
- **After Phase 4:** ~68% (add 7 features)
- **After Phase 5:** ~75% (add 8 features)

---

**Next Steps:**
1. Start with Phase 1: Implement missing search providers
2. Update configuration templates
3. Add tests and documentation
4. Push changes to GitHub
