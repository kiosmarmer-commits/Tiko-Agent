import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';

import 'tiko_config.dart';

/// Builds runtime providers from `providers.chat.*` (PRD P0: provider factory
/// from config, so `providers.default_chat` really selects the runtime model).
class ProviderFactory {
  ProviderFactory({Map<String, String>? env}) : _env = env;
  final Map<String, String>? _env;

  LlmProvider build(ProviderConfig c) {
    switch (c.type) {
      case 'mock':
        return MockLlmProvider(scenario: MockScenario.plain);
      case 'openai_compat':
        return OpenAiCompatProvider(
          id: c.id,
          baseUrl: c.baseUrl ?? 'http://127.0.0.1:11434/v1',
          model: c.model ?? 'qwen2.5:3b',
          apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: _env),
        );
      case 'ollama_native':
        return OllamaNativeProvider(
          id: c.id,
          baseUrl: (c.baseUrl ?? 'http://127.0.0.1:11434').replaceAll('/v1', ''),
          model: c.model ?? 'qwen2.5:3b',
        );
      case 'anthropic':
        final key = TikoConfig.resolveSecretRef(c.apiKeyRef, env: _env);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (anthropic) membutuhkan api_key (SecretRef env:)",
          );
        }
        return AnthropicProvider(
          apiKey: key,
          model: c.model ?? 'claude-sonnet-4-20250514',
          baseUrl: c.baseUrl ?? 'https://api.anthropic.com',
        );
      case 'gemini':
        final key = TikoConfig.resolveSecretRef(c.apiKeyRef, env: _env);
        if (key == null || key.isEmpty) {
          throw ArgumentError(
            "provider '${c.id}' (gemini) membutuhkan api_key (SecretRef env:)",
          );
        }
        return GeminiProvider(
          apiKey: key,
          model: c.model ?? 'gemini-2.0-flash',
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
