import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_providers/src/mistral_provider.dart';
import 'package:agent_providers/src/minimax_provider.dart';
import 'package:agent_providers/src/openrouter_provider.dart';
import 'package:agent_providers/src/deepseek_provider.dart';
import 'package:agent_providers/src/fireworks_provider.dart';
import 'package:agent_providers/src/novita_provider.dart';
import 'package:agent_providers/src/nous_portal_provider.dart';
import 'package:agent_providers/src/xiaomi_mimo_provider.dart';
import 'package:agent_providers/src/kimi_provider.dart';


import 'package:agent_providers/src/ai_gateway_provider.dart';
import 'package:agent_providers/src/zai_provider.dart';
import 'package:agent_providers/src/arcee_provider.dart';
import 'package:agent_providers/src/gmi_provider.dart';
import 'package:agent_providers/src/nebius_provider.dart';
import 'package:agent_providers/src/kilocode_provider.dart';
import 'package:agent_providers/src/tokenhub_provider.dart';
import 'package:agent_providers/src/tokenplan_provider.dart';
import 'package:agent_providers/src/alibaba_provider.dart';
import 'package:agent_providers/src/opencode_zen_provider.dart';
import 'package:agent_providers/src/opencode_go_provider.dart';
import 'package:agent_providers/src/commandcode_provider.dart';
import 'package:agent_providers/src/actual_provider.dart';
import 'package:agent_providers/src/ramprouter_provider.dart';
import 'package:agent_providers/src/langchain_gateway_provider.dart';

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
      case 'mistral':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (mistral) membutuhkan api_key (SecretRef env:)",
          );
        }
        return MistralProvider(
          apiKey: key,
          model: model ?? 'mistral-tiny',
          baseUrl: baseUrl ?? 'https://api.mistral.ai',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'minimax':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (minimax) membutuhkan api_key (SecretRef env:)",
          );
        }
        return MiniMaxProvider(
          apiKey: key,
          model: model ?? 'abab6-chat',
          baseUrl: baseUrl ?? 'https://api.minimax.chat',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'openrouter':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (openrouter) membutuhkan api_key (SecretRef env:)",
          );
        }
        return OpenRouterProvider(
          apiKey: key,
          model: model ?? 'openai/gpt-4o-mini',
          baseUrl: baseUrl ?? 'https://openrouter.ai/api/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'deepseek':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (deepseek) membutuhkan api_key (SecretRef env:)",
          );
        }
        return DeepSeekProvider(
          apiKey: key,
          model: model ?? 'deepseek-chat',
          baseUrl: baseUrl ?? 'https://api.deepseek.com',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'fireworks':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (fireworks) membutuhkan api_key (SecretRef env:)",
          );
        }
        return FireworksProvider(
          apiKey: key,
          model: model ?? 'accounts/fireworks/models/llama-v3p1-70b',
          baseUrl: baseUrl ?? 'https://api.fireworks.ai/inference/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'novita':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (novita) membutuhkan api_key (SecretRef env:)",
          );
        }
        return NovitaProvider(
          apiKey: key,
          model: model ?? 'novita-llama-3.2-1B',
          baseUrl: baseUrl ?? 'https://api.novita.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'nous_portal':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (nous_portal) membutuhkan api_key (SecretRef env:)",
          );
        }
        return NousPortalProvider(
          apiKey: key,
          model: model ?? 'nous-hermes-2-pro',
          baseUrl: baseUrl ?? 'https://api.nousresearch.com/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'xiaomi_mimo':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (xiaomi_mimo) membutuhkan api_key (SecretRef env:)",
          );
        }
        return XiaomiMimoProvider(
          apiKey: key,
          model: model ?? 'MiMo-7B',
          baseUrl: baseUrl ?? 'https://api.mimo.xiaomi.com/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'kimi':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (kimi) membutuhkan api_key (SecretRef env:)",
          );
        }
        return KimiProvider(
          apiKey: key,
          model: model ?? 'moonshot-v1-8k',
          baseUrl: baseUrl ?? 'https://api.moonshot.cn/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );

      case 'ai_gateway':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (ai_gateway) membutuhkan api_key (SecretRef env:)",
          );
        }
        return AiGatewayProvider(
          apiKey: key,
          model: model ?? 'gpt-4o',
          baseUrl: baseUrl ?? 'https://api.aigateway.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'zai':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (zai) membutuhkan api_key (SecretRef env:)",
          );
        }
        return ZaiProvider(
          apiKey: key,
          model: model ?? 'glm-4.6',
          baseUrl: baseUrl ?? 'https://api.z.ai/api/paas/v4',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'arcee':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (arcee) membutuhkan api_key (SecretRef env:)",
          );
        }
        return ArceeProvider(
          apiKey: key,
          model: model ?? 'arcee-hermes-2.5',
          baseUrl: baseUrl ?? 'https://models.arcee.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'gmi':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (gmi) membutuhkan api_key (SecretRef env:)",
          );
        }
        return GMIProvider(
          apiKey: key,
          model: model ?? 'gmi-70b',
          baseUrl: baseUrl ?? 'https://api.gmi-serving.com/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'nebius':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (nebius) membutuhkan api_key (SecretRef env:)",
          );
        }
        return NebiusProvider(
          apiKey: key,
          model: model ?? 'nebius-70b',
          baseUrl: baseUrl ?? 'https://api.studio.nebius.com/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'kilocode':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (kilocode) membutuhkan api_key (SecretRef env:)",
          );
        }
        return KiloCodeProvider(
          apiKey: key,
          model: model ?? 'kilocode-70b',
          baseUrl: baseUrl ?? 'https://api.kilo.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'tokenhub':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (tokenhub) membutuhkan api_key (SecretRef env:)",
          );
        }
        return TokenHubProvider(
          apiKey: key,
          model: model ?? 'tokenhub-70b',
          baseUrl: baseUrl ?? 'https://api.tokenhub.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'tokenplan':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (tokenplan) membutuhkan api_key (SecretRef env:)",
          );
        }
        return TokenPlanProvider(
          apiKey: key,
          model: model ?? 'tokenplan-70b',
          baseUrl: baseUrl ?? 'https://api.tokenplan.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'alibaba':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (alibaba) membutuhkan api_key (SecretRef env:)",
          );
        }
        return AlibabaDashScopeProvider(
          apiKey: key,
          model: model ?? 'qwen-max',
          baseUrl: baseUrl ?? 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'opencode_zen':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (opencode_zen) membutuhkan api_key (SecretRef env:)",
          );
        }
        return OpenCodeZenProvider(
          apiKey: key,
          model: model ?? 'opencode-zen-70b',
          baseUrl: baseUrl ?? 'https://opencode.ai/zen/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'opencode_go':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (opencode_go) membutuhkan api_key (SecretRef env:)",
          );
        }
        return OpenCodeGoProvider(
          apiKey: key,
          model: model ?? 'opencode-go-70b',
          baseUrl: baseUrl ?? 'https://opencode.ai/go/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'commandcode':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (commandcode) membutuhkan api_key (SecretRef env:)",
          );
        }
        return CommandCodeProvider(
          apiKey: key,
          model: model ?? 'command-r-plus',
          baseUrl: baseUrl ?? 'https://api.commandcode.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'actual':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (actual) membutuhkan api_key (SecretRef env:)",
          );
        }
        return ActualComputerProvider(
          apiKey: key,
          model: model ?? 'actual-70b',
          baseUrl: baseUrl ?? 'https://api.actualai.io/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'ramprouter':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (ramprouter) membutuhkan api_key (SecretRef env:)",
          );
        }
        return RampRouterProvider(
          apiKey: key,
          model: model ?? 'ramp-70b',
          baseUrl: baseUrl ?? 'https://api.ramp.ai/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
        );
      case 'langchain_gateway':
        final key = _secret(c.apiKeyRef);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (langchain_gateway) membutuhkan api_key (SecretRef env:)",
          );
        }
        return LangChainGatewayProvider(
          apiKey: key,
          model: model ?? 'langchain-70b',
          baseUrl: baseUrl ?? 'https://gateway.langchain.com/v1',
          requestTimeout: timeout ?? const Duration(seconds: 120),
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
      'plain' => MockScenario.plain,
      'assisted' || 'auto' || null => MockScenario.assisted,
      'single_tool' => MockScenario.singleTool,
      'multi_tool' => MockScenario.multiTool,
      'loop_trap' => MockScenario.loopTrap,
      _ => MockScenario.plain,
    };
