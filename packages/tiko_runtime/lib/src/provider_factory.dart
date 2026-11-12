import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';

import 'tiko_config.dart';

/// Builds runtime providers from `providers.chat.*` (PRD P0: provider factory
/// from config, so `providers.default_chat` really selects the runtime model).
///
/// Hermes-parity provider layer:
/// - `type` may be a built-in type or a [providerPresets] id (e.g. `deepseek`).
/// - Extended fields: credential pools (`api_keys`), OAuth device flow,
///   per-provider/model timeouts, context-length metadata, model discovery.
class ProviderFactory {
  ProviderFactory({Map<String, String>? env}) : _env = env;
  final Map<String, String>? _env;

  /// Shared cross-session prompt prefix cache; consulted by the Anthropic
  /// and OpenAI-compatible adapters to attach cache markers/hints.
  final PromptCacheManager promptCache = PromptCacheManager();

  String? _secret(String? ref) => TikoConfig.resolveSecretRef(ref, env: _env);

  CredentialPool? _pool(ProviderConfig c) {
    final keys = <String>[
      if (_secret(c.apiKeyRef) != null) _secret(c.apiKeyRef)!,
      for (final ref in c.apiKeyRefs)
        if (_secret(ref) != null) _secret(ref)!,
    ];
    if (keys.length < 2) return null;
    return CredentialPool(keys);
  }

  OAuthDeviceFlow? _oauth(ProviderConfig c) {
    if (c.oauthDeviceUrl == null ||
        c.oauthTokenUrl == null ||
        c.oauthClientId == null) {
      return null;
    }
    return OAuthDeviceFlow(
      OAuthDeviceConfig(
        clientId: c.oauthClientId!,
        deviceAuthUrl: c.oauthDeviceUrl!,
        tokenUrl: c.oauthTokenUrl!,
        scopes: c.oauthScopes,
        tokenCachePath: c.oauthTokenCache,
      ),
    );
  }

  Duration? _timeout(ProviderConfig c) =>
      c.requestTimeoutSec != null && c.requestTimeoutSec! > 0
          ? Duration(seconds: c.requestTimeoutSec!)
          : null;

  Capabilities _capabilities(
    ProviderConfig c,
    ProviderPreset? preset, {
    bool streaming = true,
  }) =>
      Capabilities(
        toolCalling: true,
        streaming: streaming,
        maxContext: c.contextLength ?? preset?.contextLength ?? 32768,
      );

  LlmProvider build(ProviderConfig c) {
    final preset = findProviderPreset(c.type);
    final rawType = preset?.transport ?? c.type;
    final effectiveType = switch (rawType) {
      'openai_responses' => 'responses',
      'azure_openai' => 'azure',
      'chat_completions' => 'openai_compat',
      'anthropic_messages' => 'anthropic',
      final t => t,
    };
    final oauth = _oauth(c);
    final pool = _pool(c);
    final timeout = _timeout(c);
    final baseUrl = c.baseUrl ?? preset?.baseUrl;
    final model = c.model ?? preset?.defaultModel;

    switch (effectiveType) {
      case 'mock':
        return MockLlmProvider(scenario: _mockScenario(c.scenario));
      case 'openai_compat':
        return OpenAiCompatProvider(
          id: c.id,
          baseUrl: baseUrl ?? 'http://127.0.0.1:11434/v1',
          model: model ?? 'qwen2.5:3b',
          apiKey: _secret(c.apiKeyRef),
          promptCache: promptCache,
          credentialPool: pool,
          tokenProvider: oauth?.getAccessToken,
          requestTimeout: timeout,
          modelTimeouts: c.modelTimeouts,
          capabilities: _capabilities(c, preset),
        );
      case 'responses':
        return OpenAiResponsesProvider(
          id: c.id,
          baseUrl: baseUrl ?? 'https://api.openai.com/v1',
          model: model ?? 'gpt-5-codex',
          apiKey: _secret(c.apiKeyRef),
          promptCache: promptCache,
          credentialPool: pool,
          tokenProvider: oauth?.getAccessToken,
          requestTimeout: timeout,
          modelTimeouts: c.modelTimeouts,
          capabilities: _capabilities(c, preset),
        );
      case 'azure':
        return AzureOpenAIProvider(
          id: c.id,
          baseUrl: baseUrl ?? 'https://YOUR-RESOURCE.openai.azure.com',
          model: model ?? 'gpt-4o',
          apiKey: _secret(c.apiKeyRef),
          promptCache: promptCache,
          credentialPool: pool,
          tokenProvider: oauth?.getAccessToken,
          requestTimeout: timeout,
          modelTimeouts: c.modelTimeouts,
          capabilities: _capabilities(c, preset),
          apiVersion: c.apiVersion ?? '2024-10-21',
        );
      case 'bedrock':
        final accessKey = _secret(c.accessKeyRef);
        final secretKey = _secret(c.secretKeyRef);
        if (c.region == null ||
            accessKey == null ||
            accessKey.isEmpty ||
            secretKey == null ||
            secretKey.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (bedrock) butuh region + access_key_id + "
            'secret_access_key (SecretRef env:)',
          );
        }
        return BedrockProvider(
          id: c.id,
          region: c.region!,
          model: model ?? 'anthropic.claude-sonnet-4-20250514-v1:0',
          accessKeyId: accessKey,
          secretAccessKey: secretKey,
          sessionToken: _secret(c.sessionTokenRef),
          requestTimeout: timeout,
          capabilities: _capabilities(c, preset, streaming: false),
        );
      case 'ollama_native':
        return OllamaNativeProvider(
          id: c.id,
          baseUrl: (baseUrl ?? 'http://127.0.0.1:11434').replaceAll('/v1', ''),
          model: model ?? 'qwen2.5:3b',
        );
      case 'anthropic_messages':
      case 'anthropic':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (anthropic) membutuhkan api_key (SecretRef env:)",
          );
        }
        return AnthropicProvider(
          apiKey: key,
          model: model ?? 'claude-sonnet-4-20250514',
          baseUrl: baseUrl ?? 'https://api.anthropic.com',
          promptCache: promptCache,
        );
      case 'gemini':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (gemini) membutuhkan api_key (SecretRef env:)",
          );
        }
        return GeminiProvider(
          apiKey: key,
          model: model ?? 'gemini-2.0-flash',
        );
      default:
        throw ArgumentError('Tipe provider tidak didukung: ${c.type}');
    }
  }

  /// Builds every enabled provider; returns the map keyed by provider id.
  Map<String, LlmProvider> buildAll(TikoConfig cfg) => {
        for (final c in cfg.providers.values)
          if (c.enabled) c.id: build(c),
      };

  /// Builds the decision provider (Jev/Laya systemone, AGD-02) from the
  /// `decision:` config section. Returns null when disabled — the Router
  /// then falls back to its keyword heuristics.
  DecisionProvider? buildDecision(TikoConfig cfg, [LlmProvider? fallbackLlm]) {
    final d = cfg.decision;
    if (!d.enabled) {
      return (d.llmFallback && fallbackLlm != null)
          ? LlmJsonDecisionProvider(fallbackLlm)
          : null;
    }
    return SystemOneDecisionProvider(
      baseUrl: d.baseUrl,
      model: d.model,
      apiKey: TikoConfig.resolveSecretRef(d.apiKeyRef, env: _env),
    );
  }

  /// Builds the memory embedding function from `memory.embed`. Returns null
  /// when disabled — the vector recall path then stays dormant (BM25/FTS
  /// remains authoritative).
  Future<List<double>> Function(String text)? buildEmbedder(TikoConfig cfg) {
    final e = cfg.memoryEmbed;
    if (!e.enabled) return null;
    final embedder = OllamaEmbedder(baseUrl: e.baseUrl, model: e.model);
    return embedder.embed;
  }
}

MockScenario _mockScenario(String? raw) => switch (raw) {
      'single_tool' => MockScenario.singleTool,
      'multi_tool' => MockScenario.multiTool,
      'loop_trap' => MockScenario.loopTrap,
      _ => MockScenario.plain,
    };
