/// Static catalog of well-known LLM provider endpoints (Hermes-parity
/// provider presets). A config entry may use a preset id as its `type`
/// (e.g. `type: deepseek`); the runtime resolves it to the right transport
/// and base URL. Any preset value can still be overridden per entry via
/// `base_url`, `model`, and `context_length`.
class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.baseUrl,
    this.defaultModel,
    this.transport = 'chat_completions',
    this.contextLength = 32768,
  });

  final String id;

  /// Endpoint root (OpenAI-style base without trailing slash).
  final String baseUrl;

  /// Fallback model when the config entry omits `model`.
  final String? defaultModel;

  /// chat_completions | anthropic_messages | responses | azure | bedrock
  final String transport;

  /// Approximate context window for capability metadata.
  final int contextLength;
}

const Map<String, ProviderPreset> providerPresets = {
  // Aggregators / gateways
  'openrouter': ProviderPreset(
    id: 'openrouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'anthropic/claude-sonnet-4',
    contextLength: 200000,
  ),
  'nous': ProviderPreset(
    id: 'nous',
    baseUrl: 'https://inference-api.nousresearch.com/v1',
    defaultModel: 'Hermes-4-405B',
    contextLength: 131072,
  ),
  'ai_gateway': ProviderPreset(
    id: 'ai_gateway',
    baseUrl: 'https://ai-gateway.vercel.sh/v1',
    contextLength: 128000,
  ),
  'litellm': ProviderPreset(
    id: 'litellm',
    baseUrl: 'http://127.0.0.1:4000/v1',
    contextLength: 128000,
  ),
  'router': ProviderPreset(
    id: 'router',
    baseUrl: 'https://openrouter.ai/api/v1',
    contextLength: 128000,
  ),

  // Cloud first-party
  'openai': ProviderPreset(
    id: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
    contextLength: 128000,
  ),
  'openai_codex': ProviderPreset(
    id: 'openai_codex',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-5-codex',
    transport: 'responses',
    contextLength: 400000,
  ),
  'deepseek': ProviderPreset(
    id: 'deepseek',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    contextLength: 65536,
  ),
  'anthropic': ProviderPreset(
    id: 'anthropic',
    baseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-sonnet-4-20250514',
    transport: 'anthropic_messages',
    contextLength: 200000,
  ),
  'gemini': ProviderPreset(
    id: 'gemini',
    baseUrl: 'https://generativelanguage.googleapis.com',
    defaultModel: 'gemini-2.0-flash',
    contextLength: 1000000,
  ),
  'azure': ProviderPreset(
    id: 'azure',
    baseUrl: 'https://YOUR-RESOURCE.openai.azure.com',
    defaultModel: 'gpt-4o',
    transport: 'azure',
    contextLength: 128000,
  ),
  'bedrock': ProviderPreset(
    id: 'bedrock',
    baseUrl: '',
    defaultModel: 'anthropic.claude-sonnet-4-20250514-v1:0',
    transport: 'bedrock',
    contextLength: 200000,
  ),

  // Model labs with OpenAI-compatible endpoints
  'groq': ProviderPreset(
    id: 'groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile',
    contextLength: 131072,
  ),
  'mistral': ProviderPreset(
    id: 'mistral',
    baseUrl: 'https://api.mistral.ai/v1',
    defaultModel: 'mistral-large-latest',
    contextLength: 131072,
  ),
  'xai': ProviderPreset(
    id: 'xai',
    baseUrl: 'https://api.x.ai/v1',
    defaultModel: 'grok-3',
    contextLength: 131072,
  ),
  'zai': ProviderPreset(
    id: 'zai',
    baseUrl: 'https://api.z.ai/api/paas/v4',
    defaultModel: 'glm-4.6',
    contextLength: 128000,
  ),
  'kimi': ProviderPreset(
    id: 'kimi',
    baseUrl: 'https://api.moonshot.ai/v1',
    defaultModel: 'kimi-k2-0905-preview',
    contextLength: 256000,
  ),
  'kimi_cn': ProviderPreset(
    id: 'kimi_cn',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-k2-0905-preview',
    contextLength: 256000,
  ),
  'minimax': ProviderPreset(
    id: 'minimax',
    baseUrl: 'https://api.minimax.io/v1',
    defaultModel: 'MiniMax-Text-01',
    contextLength: 1000192,
  ),
  'minimax_cn': ProviderPreset(
    id: 'minimax_cn',
    baseUrl: 'https://api.minimaxi.com/v1',
    defaultModel: 'MiniMax-Text-01',
    contextLength: 1000192,
  ),
  'alibaba': ProviderPreset(
    id: 'alibaba',
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-max',
    contextLength: 131072,
  ),
  'tencent': ProviderPreset(
    id: 'tencent',
    baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
    defaultModel: 'hunyuan-turbos-latest',
    contextLength: 256000,
  ),
  'xiaomi': ProviderPreset(
    id: 'xiaomi',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'MiMo-2508',
    contextLength: 262144,
  ),
  'stepfun': ProviderPreset(
    id: 'stepfun',
    baseUrl: 'https://api.stepfun.com/v1',
    defaultModel: 'step-2-16k',
    contextLength: 16384,
  ),

  // Inference hosts
  'together': ProviderPreset(
    id: 'together',
    baseUrl: 'https://api.together.xyz/v1',
    defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
    contextLength: 131072,
  ),
  'fireworks': ProviderPreset(
    id: 'fireworks',
    baseUrl: 'https://api.fireworks.ai/inference/v1',
    defaultModel: 'accounts/fireworks/models/llama-v3p3-70b-instruct',
    contextLength: 131072,
  ),
  'novita': ProviderPreset(
    id: 'novita',
    baseUrl: 'https://api.novita.ai/v3/openai',
    defaultModel: 'meta-llama/llama-3.3-70b-instruct',
    contextLength: 131072,
  ),
  'nvidia': ProviderPreset(
    id: 'nvidia',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    defaultModel: 'meta/llama-3.3-70b-instruct',
    contextLength: 131072,
  ),
  'nebius': ProviderPreset(
    id: 'nebius',
    baseUrl: 'https://api.studio.nebius.com/v1',
    defaultModel: 'meta-llama/Llama-3.3-70B-Instruct',
    contextLength: 131072,
  ),
  'huggingface': ProviderPreset(
    id: 'huggingface',
    baseUrl: 'https://router.huggingface.co/v1',
    contextLength: 128000,
  ),
  'arcee': ProviderPreset(
    id: 'arcee',
    baseUrl: 'https://models.arcee.ai/v1',
    contextLength: 128000,
  ),
  'gmi': ProviderPreset(
    id: 'gmi',
    baseUrl: 'https://api.gmi-serving.com/v1',
    contextLength: 131072,
  ),
  'actual': ProviderPreset(
    id: 'actual',
    baseUrl: 'https://api.actualai.io/v1',
    contextLength: 128000,
  ),
  'opencode_zen': ProviderPreset(
    id: 'opencode_zen',
    baseUrl: 'https://opencode.ai/zen/v1',
    contextLength: 200000,
  ),

  // Local / self-hosted
  'ollama_cloud': ProviderPreset(
    id: 'ollama_cloud',
    baseUrl: 'https://ollama.com/v1',
    contextLength: 128000,
  ),
  'lmstudio': ProviderPreset(
    id: 'lmstudio',
    baseUrl: 'http://127.0.0.1:1234/v1',
    contextLength: 32768,
  ),
  'vllm': ProviderPreset(
    id: 'vllm',
    baseUrl: 'http://127.0.0.1:8000/v1',
    contextLength: 32768,
  ),
};

/// Looks up a preset by id (case-insensitive, `-`/`_` equivalent).
ProviderPreset? findProviderPreset(String id) {
  final key = id.trim().toLowerCase().replaceAll('-', '_');
  final preset = providerPresets[key];
  if (preset != null) return preset;
  for (final p in providerPresets.values) {
    if (p.id.replaceAll('-', '_') == key) return p;
  }
  return null;
}

/// All preset ids accepted as `type:` values in config.
Set<String> get providerPresetIds => providerPresets.keys.toSet();
