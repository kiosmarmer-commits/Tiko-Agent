import 'dart:io';

import 'package:agent_providers/agent_providers.dart' show findProviderPreset;
import 'package:yaml/yaml.dart';

/// One provider entry under `providers.chat.<id>`.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.type,
    this.baseUrl,
    this.model,
    this.apiKeyRef,
    this.scenario,
    this.enabled = true,
    this.apiKeyRefs = const [],
    this.requestTimeoutSec,
    this.modelTimeouts = const {},
    this.contextLength,
    this.discoverModels = false,
    this.apiVersion,
    this.region,
    this.accessKeyRef,
    this.secretKeyRef,
    this.sessionTokenRef,
    this.oauthDeviceUrl,
    this.oauthTokenUrl,
    this.oauthClientId,
    this.oauthScopes = const [],
    this.oauthTokenCache,
  });

  final String id;

  /// Built-in type, a [providerPresets] id (e.g. `deepseek`), or one of the
  /// Hermes-parity transports: `openai_responses`, `azure_openai`, `bedrock`.
  final String type;
  final String? baseUrl;
  final String? model;

  /// A [SecretRef] such as `env:OPENAI_API_KEY`. Never a raw secret.
  final String? apiKeyRef;

  /// Mock-only behavior selector: plain | single_tool | multi_tool | loop_trap.
  final String? scenario;
  final bool enabled;

  /// Credential pool (Hermes-parity): additional SecretRefs; rotated on
  /// 401/429 failures. [apiKeyRef] remains the primary key.
  final List<String> apiKeyRefs;

  /// Provider-wide request timeout in seconds (Hermes-parity
  /// `request_timeout_seconds`).
  final int? requestTimeoutSec;

  /// Per-model timeout override in seconds.
  final Map<String, int> modelTimeouts;

  /// Capability metadata: context window override for this provider.
  final int? contextLength;

  /// When true, `tiko models <id>` queries the endpoint's model catalog.
  final bool discoverModels;

  /// Azure OpenAI `api-version` query parameter.
  final String? apiVersion;

  /// Bedrock AWS region.
  final String? region;

  /// Bedrock credentials as SecretRefs (`env:AWS_ACCESS_KEY_ID`, …).
  final String? accessKeyRef;
  final String? secretKeyRef;
  final String? sessionTokenRef;

  /// OAuth2 device flow (Hermes-parity `*-oauth` providers). Endpoints are
  /// provider-specific; the token is cached at [oauthTokenCache].
  final String? oauthDeviceUrl;
  final String? oauthTokenUrl;
  final String? oauthClientId;
  final List<String> oauthScopes;
  final String? oauthTokenCache;
}

class ConfigValidationException implements Exception {
  ConfigValidationException(this.issues);
  final List<ConfigIssue> issues;

  @override
  String toString() => [
        'Konfigurasi Tiko tidak valid:',
        ...issues.where((issue) => issue.fatal).map((issue) => issue.toString()),
        'Jalankan `tiko doctor` untuk diagnosis atau `tiko config set` untuk perbaikan.',
      ].join('\n');
}

class ConfigIssue {
  const ConfigIssue(this.path, this.message, {this.fatal = true});
  final String path;
  final String message;
  final bool fatal;

  @override
  String toString() => '${fatal ? 'ERROR' : 'WARN'} $path: $message';
}


/// Decision model (Jev / Laya, AGD-02 §3): typed decisions over
/// `POST {baseUrl}/v1/systemone`. Disabled by default; when enabled the
/// Router consults it for need_tools / danger / complexity before picking
/// a tier. Thresholds live in agent_core's DecisionThresholds.
class DecisionConfig {
  const DecisionConfig({
    this.enabled = false,
    this.baseUrl = 'https://api.typesafe.ai',
    this.model = 'jev-latest',
    this.apiKeyRef,
    this.llmFallback = false,
  });

  final bool enabled;
  final String baseUrl;
  final String model;

  /// `env:JEV_API_KEY` — never a raw secret.
  final String? apiKeyRef;

  /// When true and systemone is unreachable, an LLM+JSON decision fallback
  /// is used instead of pure heuristics.
  final bool llmFallback;
}

/// Memory embedding (AGD-04): vectors for semantic recall are only
/// populated when an embedder is explicitly enabled. Default model runs on
/// a local Ollama instance.
class MemoryEmbedConfig {
  const MemoryEmbedConfig({
    this.enabled = false,
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'nomic-embed-text',
  });

  final bool enabled;
  final String baseUrl;
  final String model;
}

/// Administrator-declared external memory provider (Hermes-style memory
/// providers). Credentials are references to env vars; raw secrets are
/// never accepted in the YAML configuration.
class ExternalMemoryProviderConfig {
  const ExternalMemoryProviderConfig({
    required this.baseUrl,
    this.kind = 'http',
    this.name,
    this.apiKeyRef,
  });

  final String baseUrl;

  /// Adapter shape: `http` (generic REST contract), `mem0`, or `honcho`.
  final String kind;

  /// Optional provider id used in merged results and metrics. For `mem0`
  /// it doubles as the default user_id; for `honcho` as the session id.
  final String? name;

  /// SecretRef `env:NAME`; null means the endpoint needs no auth.
  final String? apiKeyRef;
}

/// Administrator-declared MCP server. Credentials are references to env vars;
/// raw secrets are never accepted in the YAML configuration.
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.type,
    this.command,
    this.args = const [],
    this.url,
    this.protocolVersion = '2025-11-25',
    this.maxReadRetries = 2,
    this.headerRefs = const {},
    this.allow = const [],
    this.risk = 'high',
    this.enabled = true,
    this.environmentRefs = const {},
    this.allowPrivateNetwork = false,
    this.oauthTokenUrl,
    this.oauthClientId,
    this.oauthClientSecretRef,
    this.oauthScopes = const [],
  });

  final String id;

  /// stdio (local child process) | http (remote Streamable HTTP endpoint).
  final String type;

  /// Executable for stdio servers; null for http servers.
  final String? command;
  final List<String> args;

  /// MCP endpoint URL for http servers; null for stdio servers.
  final String? url;

  /// Streamable HTTP protocol version offered to the server.
  final String protocolVersion;

  /// Maximum retries for safe/read-only HTTP JSON-RPC methods (0–3).
  final int maxReadRetries;

  /// HTTP header name → `env:VAR` SecretRef (e.g. Authorization).
  final Map<String, String> headerRefs;
  final List<String> allow;
  final String risk;
  final bool enabled;
  final Map<String, String> environmentRefs;
  final bool allowPrivateNetwork;

  /// OAuth 2.0 client-credentials (P2-14): token endpoint URL. Null disables
  /// OAuth for this server.
  final String? oauthTokenUrl;

  /// OAuth client id (public identifier, not a secret).
  final String? oauthClientId;

  /// OAuth client secret as `env:VAR` SecretRef.
  final String? oauthClientSecretRef;

  /// OAuth scopes requested from the token endpoint.
  final List<String> oauthScopes;

  bool get hasOauth =>
      oauthTokenUrl != null &&
      oauthClientId != null &&
      oauthClientSecretRef != null;
}

/// Typed, validated configuration (PRD P0: typed config schema).
/// Reads the existing `config/agent.yaml` layout so old files keep working.
class TikoConfig {
  TikoConfig({
    this.profile = 'default',
    this.workspace = '.',
    this.dataDir = 'data',
    this.logsDir = 'logs',
    this.dbPath = 'data/agent.db',
    this.defaultProvider = 'mock',
    this.providers = const {},
    this.tierProviders = const {},
    this.permissionMode = 'ask',
    this.shellAllowlist = const ['ls', 'cat', 'git status', 'pwd', 'echo'],
    this.requireConfirm = const [
      'write_file',
      'patch_file',
      'shell',
      'http_request',
      'schedule_job',
    ],
    this.httpDomainAllowlist = const [],
    this.mcpServers = const [],
    this.decision = const DecisionConfig(),
    this.memoryEmbed = const MemoryEmbedConfig(),
    this.memoryProviders = const [],
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.tavilyApiKeyRef,
    this.falApiKeyRef,
    this.openaiApiKeyRef,
    this.maxIterations = 12,
    this.maxTokensPerTask = 60000,
    this.maxWallClockSec = 300,
    this.maxToolCalls = 30,
    this.toolSubsetThreshold = 24,
    this.toolSubsetK = 20,
    this.apiPort = 8787,
    this.enableImageGeneration = false,
    this.enableVision = false,
    this.sandboxDockerPersistent = false,
  });

  final String profile;
  final String workspace;
  final String dataDir;
  final String logsDir;
  final String dbPath;
  final String defaultProvider;
  final Map<String, ProviderConfig> providers;

  /// Pemetaan tier routing adaptif (tier 1, 2, atau 3) ke id provider dari
  /// providers.tiers di config; kosong berarti semua tier memakai default.
  final Map<int, String> tierProviders;
  final String permissionMode;
  final List<String> shellAllowlist;
  final List<String> requireConfirm;
  final List<String> httpDomainAllowlist;
  final List<McpServerConfig> mcpServers;
  final DecisionConfig decision;
  final MemoryEmbedConfig memoryEmbed;

  /// External memory providers fanned out together with the built-in store.
  final List<ExternalMemoryProviderConfig> memoryProviders;
  final String searxngBaseUrl;

  /// SecretRef `env:TAVILY_API_KEY` untuk cadangan Tavily (AGD-04 §7);
  /// null berarti fallback nonaktif.
  final String? tavilyApiKeyRef;

  /// SecretRef `env:FAL_KEY` untuk FAL.ai image generation
  final String? falApiKeyRef;

  /// SecretRef `env:OPENAI_API_KEY` untuk OpenAI vision
  final String? openaiApiKeyRef;

  /// Enable image generation tools (FAL.ai)
  final bool enableImageGeneration;

  /// Enable vision tools (image analysis, OCR)
  final bool enableVision;

  /// Hermes-parity `container_persistent`: keep one hardened docker container
  /// alive and dispatch commands via `docker exec` so state (cwd, installed
  /// packages, /work files) carries between tool calls. Off by default.
  final bool sandboxDockerPersistent;

  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;

  /// P2-2: dynamic tool-schema subset. When the registry carries more than
  /// [toolSubsetThreshold] tools, the model only receives the top
  /// [toolSubsetK] relevant specs plus `tool_search`.
  final int toolSubsetThreshold;
  final int toolSubsetK;
  final int apiPort;

  static const knownProviderTypes = {
    'mock',
    'openai_compat',
    'openai_responses',
    'azure_openai',
    'bedrock',
    'ollama_native',
    'anthropic',
    'gemini',
  };

  /// Parses YAML text with a real YAML parser (duplicate keys are an error).
  /// Returns the config plus validation issues; never throws on bad content.
  static (TikoConfig, List<ConfigIssue>) parse(String text) {
    final issues = <ConfigIssue>[];
    var root = YamlMap();
    try {
      final doc = loadYaml(text);
      if (doc == null) {
        // keep the empty mapping
      } else if (doc is YamlMap) {
        root = doc;
      } else {
        return (
          TikoConfig(),
          [const ConfigIssue('/', 'root harus berupa mapping')],
        );
      }
    } on YamlException catch (e) {
      return (TikoConfig(), [ConfigIssue('/', 'YAML tidak valid: ${e.message}')]);
    }

    for (final section in [
      'agent',
      'providers',
      'security',
      'storage',
      'api',
      'search',
      'http',
      'mcp',
      'decision',
      'memory',
    ]) {
      final value = root[section];
      if (value != null && value is! YamlMap) {
        issues.add(ConfigIssue(section, 'harus berupa mapping'));
      }
    }
    if (root['profile'] != null && root['profile'] is! String) {
      issues.add(const ConfigIssue('profile', 'harus berupa string'));
    }
    for (final key in ['workspace', 'logs_dir']) {
      final value = root[key];
      if (value != null && value is! String) {
        issues.add(ConfigIssue(key, 'harus berupa string'));
      } else if (value is String && value.trim().isEmpty) {
        issues.add(ConfigIssue(key, 'tidak boleh kosong'));
      }
    }

    final positiveIntFields = <String, int>{
      'max_iterations': 100,
      'max_tokens_per_task': 10000000,
      'max_wall_clock_sec': 86400,
      'max_tool_calls': 10000,
    };
    final agentSection = root['agent'];
    if (agentSection is YamlMap) {
      for (final entry in positiveIntFields.entries) {
        final value = agentSection[entry.key];
        if (value != null &&
            (value is! int || value < 1 || value > entry.value)) {
          issues.add(ConfigIssue(
            'agent.${entry.key}',
            'harus berupa integer antara 1 dan ${entry.value}',
          ));
        }
      }
    }

    String str(Object? v, String d) => v is String && v.isNotEmpty ? v : d;
    int intOf(Object? v, int d) => v is int ? v : d;
    List<String> strList(Object? v, List<String> d) =>
        v is YamlList ? v.map((e) => '$e').toList() : d;
    YamlMap sec(String k) {
      final v = root[k];
      return v is YamlMap ? v : YamlMap();
    }

    final agent = sec('agent');
    final security = sec('security');
    final providersSec = sec('providers');
    final storage = sec('storage');
    final http = sec('http');
    final search = sec('search');
    final api = sec('api');
    final mcp = sec('mcp');
    final decisionSec = sec('decision');
    final memorySec = sec('memory');
    final featuresSec = sec('features');

    // ---- decision (Jev/Laya systemone) ----
    final decisionCfg = _parseDecision(decisionSec, issues);

    // ---- memory.embed ----
    final memoryEmbedCfg = _parseMemoryEmbed(memorySec, issues);

    // ---- memory.external_providers ----
    final memoryProvidersCfg = _parseMemoryProviders(memorySec, issues);

    if (providersSec['default_chat'] != null &&
        providersSec['default_chat'] is! String) {
      issues.add(const ConfigIssue('providers.default_chat', 'harus berupa string'));
    }
    if (security['mode'] != null && security['mode'] is! String) {
      issues.add(const ConfigIssue('security.mode', 'harus berupa string'));
    }
    for (final field in ['data_dir', 'db_path']) {
      final value = storage[field];
      if (value != null && value is! String) {
        issues.add(ConfigIssue('storage.$field', 'harus berupa string'));
      }
    }
    final searchUrl = search['searxng_base_url'];
    if (searchUrl != null && searchUrl is! String) {
      issues.add(const ConfigIssue('search.searxng_base_url', 'harus berupa string'));
    }
    final tavilyKeyValue = search['tavily_api_key'];
    if (tavilyKeyValue != null && tavilyKeyValue is! String) {
      issues.add(const ConfigIssue('search.tavily_api_key', 'harus berupa string'));
    }
    if (tavilyKeyValue is String &&
        tavilyKeyValue.isNotEmpty &&
        !tavilyKeyValue.startsWith('env:')) {
      issues.add(const ConfigIssue(
        'search.tavily_api_key',
        "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
      ));
    }
    // ---- features (image generation / vision) ----
    final imageGenValue = featuresSec['image_generation'];
    if (imageGenValue != null && imageGenValue is! bool) {
      issues.add(const ConfigIssue(
          'features.image_generation', 'harus berupa boolean'));
    }
    final visionValue = featuresSec['vision'];
    if (visionValue != null && visionValue is! bool) {
      issues.add(
          const ConfigIssue('features.vision', 'harus berupa boolean'));
    }
    final falKeyValue = featuresSec['fal_api_key'];
    if (falKeyValue != null && falKeyValue is! String) {
      issues.add(
          const ConfigIssue('features.fal_api_key', 'harus berupa string'));
    }
    if (falKeyValue is String &&
        falKeyValue.isNotEmpty &&
        !falKeyValue.startsWith('env:')) {
      issues.add(const ConfigIssue(
        'features.fal_api_key',
        "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
      ));
    }
    final featuresOpenaiKeyValue = featuresSec['openai_api_key'];
    if (featuresOpenaiKeyValue != null && featuresOpenaiKeyValue is! String) {
      issues.add(const ConfigIssue(
          'features.openai_api_key', 'harus berupa string'));
    }
    if (featuresOpenaiKeyValue is String &&
        featuresOpenaiKeyValue.isNotEmpty &&
        !featuresOpenaiKeyValue.startsWith('env:')) {
      issues.add(const ConfigIssue(
        'features.openai_api_key',
        "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
      ));
    }
    for (final entry in [
      ('security.shell_allowlist', security['shell_allowlist']),
      ('security.require_confirm', security['require_confirm']),
      ('http.domain_allowlist', http['domain_allowlist']),
    ]) {
      final value = entry.$2;
      if (value != null &&
          (value is! YamlList || value.any((item) => item is! String))) {
        issues.add(ConfigIssue(entry.$1, 'harus berupa daftar string'));
      }
    }

    final providers = <String, ProviderConfig>{};
    final chat = providersSec['chat'];
    if (chat != null && chat is! YamlMap) {
      issues.add(const ConfigIssue('providers.chat', 'harus berupa mapping'));
    }
    if (chat is YamlMap) {
      for (final e in chat.entries) {
        final id = '${e.key}';
        final v = e.value;
        if (v is! YamlMap) {
          issues.add(ConfigIssue('providers.chat.$id', 'harus berupa mapping'));
          continue;
        }
        final type = str(v['type'], '');
        final baseUrlValue = v['base_url'];
        final modelValue = v['model'];
        final apiKeyValue = v['api_key'];
        final scenarioValue = v['scenario'];
        final enabledValue = v['enabled'];
        var invalidField = false;
        if (scenarioValue != null && scenarioValue is! String) {
          issues.add(const ConfigIssue(
            'providers.chat.scenario',
            'harus berupa string (plain | single_tool | multi_tool | loop_trap)',
          ));
          invalidField = true;
        }
        if (baseUrlValue != null &&
            (baseUrlValue is! String || baseUrlValue.trim().isEmpty)) {
          issues.add(ConfigIssue(
            'providers.chat.$id.base_url',
            'harus berupa URL string yang tidak kosong',
          ));
          invalidField = true;
        } else if (baseUrlValue is String) {
          final uri = Uri.tryParse(baseUrlValue);
          if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
            issues.add(ConfigIssue(
              'providers.chat.$id.base_url',
              'harus berupa URL HTTP/HTTPS yang valid',
            ));
            invalidField = true;
          }
        }
        if (modelValue != null &&
            (modelValue is! String || modelValue.trim().isEmpty)) {
          issues.add(ConfigIssue(
            'providers.chat.$id.model',
            'harus berupa string yang tidak kosong',
          ));
          invalidField = true;
        }
        if (apiKeyValue != null && apiKeyValue is! String) {
          issues.add(ConfigIssue(
            'providers.chat.$id.api_key',
            'harus berupa SecretRef string env:NAMA_VAR',
          ));
          invalidField = true;
        }
        if (enabledValue != null && enabledValue is! bool) {
          issues.add(ConfigIssue('providers.chat.$id.enabled', 'harus berupa boolean'));
          invalidField = true;
        }
        if (invalidField) continue;
        if (!knownProviderTypes.contains(type) && findProviderPreset(type) == null) {
          issues.add(ConfigIssue(
            'providers.chat.$id.type',
            "tipe '$type' tidak didukung (${knownProviderTypes.join('|')} "
                'atau id preset provider)',
          ));
          continue;
        }
        final keyRef = apiKeyValue;
        if (keyRef is String && keyRef.isNotEmpty && !keyRef.startsWith('env:')) {
          issues.add(ConfigIssue(
            'providers.chat.$id.api_key',
            "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
          ));
          continue;
        }

        // Hermes-parity extended provider fields.
        final apiKeysValue = v['api_keys'];
        final extraKeyRefs = <String>[];
        if (apiKeysValue is YamlList) {
          for (final k in apiKeysValue) {
            if (k is String && k.startsWith('env:')) extraKeyRefs.add(k);
          }
        } else if (apiKeysValue != null) {
          issues.add(ConfigIssue(
            'providers.chat.$id.api_keys',
            'harus berupa daftar SecretRef env:NAMA_VAR',
          ));
        }
        final timeoutValue = v['request_timeout_sec'];
        if (timeoutValue != null && timeoutValue is! int) {
          issues.add(ConfigIssue(
            'providers.chat.$id.request_timeout_sec',
            'harus berupa integer detik',
          ));
        }
        final modelTimeouts = <String, int>{};
        final mtValue = v['model_timeouts'];
        if (mtValue is YamlMap) {
          mtValue.forEach((k, val) {
            if (val is int) modelTimeouts['$k'] = val;
          });
        } else if (mtValue != null) {
          issues.add(ConfigIssue(
            'providers.chat.$id.model_timeouts',
            'harus berupa mapping model -> detik',
          ));
        }
        final contextValue = v['context_length'];
        if (contextValue != null && contextValue is! int) {
          issues.add(ConfigIssue(
            'providers.chat.$id.context_length',
            'harus berupa integer',
          ));
        }
        final discoverValue = v['discover_models'];
        if (discoverValue != null && discoverValue is! bool) {
          issues.add(ConfigIssue(
            'providers.chat.$id.discover_models',
            'harus berupa boolean',
          ));
        }
        final apiVersionValue = v['api_version'];
        final regionValue = v['region'];
        String? secretRefOf(dynamic value, String field) {
          if (value == null) return null;
          if (value is String && value.startsWith('env:')) return value;
          issues.add(ConfigIssue(
            'providers.chat.$id.$field',
            "gunakan SecretRef 'env:NAMA_VAR'",
          ));
          return null;
        }

        providers[id] = ProviderConfig(
          id: id,
          type: type,
          baseUrl: baseUrlValue as String?,
          model: modelValue as String?,
          apiKeyRef: keyRef is String && keyRef.isNotEmpty ? keyRef : null,
          scenario: scenarioValue is String ? scenarioValue : null,
          enabled: enabledValue is bool ? enabledValue : true,
          apiKeyRefs: extraKeyRefs,
          requestTimeoutSec: timeoutValue is int ? timeoutValue : null,
          modelTimeouts: modelTimeouts,
          contextLength: contextValue is int ? contextValue : null,
          discoverModels: discoverValue == true,
          apiVersion: apiVersionValue is String ? apiVersionValue : null,
          region: regionValue is String ? regionValue : null,
          accessKeyRef: secretRefOf(v['access_key_id'], 'access_key_id'),
          secretKeyRef: secretRefOf(v['secret_access_key'], 'secret_access_key'),
          sessionTokenRef: secretRefOf(v['session_token'], 'session_token'),
          oauthDeviceUrl: v['oauth_device_url'] is String ? v['oauth_device_url'] as String : null,
          oauthTokenUrl: v['oauth_token_url'] is String ? v['oauth_token_url'] as String : null,
          oauthClientId: v['oauth_client_id'] is String ? v['oauth_client_id'] as String : null,
          oauthScopes: v['oauth_scopes'] is YamlList
              ? [for (final s in v['oauth_scopes'] as YamlList) '$s']
              : const [],
          oauthTokenCache: v['oauth_token_cache'] is String
              ? v['oauth_token_cache'] as String
              : null,
        );
      }
    }
    if (providers.isEmpty) {
      providers['mock'] = const ProviderConfig(id: 'mock', type: 'mock');
    }

    final mcpServers = <McpServerConfig>[];
    final rawMcpServers = mcp['servers'];
    if (rawMcpServers != null && rawMcpServers is! YamlList) {
      issues.add(const ConfigIssue('mcp.servers', 'harus berupa daftar mapping'));
    } else if (rawMcpServers is YamlList) {
      if (rawMcpServers.length > 8) {
        issues.add(const ConfigIssue('mcp.servers', 'maksimal 8 server MCP'));
      }
      final seenMcpIds = <String>{};
      for (var index = 0; index < rawMcpServers.length && index < 8; index++) {
        final entry = rawMcpServers[index];
        final path = 'mcp.servers[$index]';
        if (entry is! YamlMap) {
          issues.add(ConfigIssue(path, 'harus berupa mapping'));
          continue;
        }
        final idValue = entry['id'];
        final typeValue = entry['type'] ?? 'stdio';
        final commandValue = entry['command'];
        final urlValue = entry['url'];
        final protocolVersionValue = entry['protocol_version'] ?? '2025-11-25';
        final maxReadRetriesValue = entry['max_read_retries'] ?? 2;
        final headersValue = entry['headers'];
        final argsValue = entry['args'];
        final allowValue = entry['allow'];
        final riskValue = entry['risk'] ?? 'high';
        final enabledValue = entry['enabled'] ?? true;
        final envValue = entry['env'];
        var valid = true;
        if (idValue is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(idValue) || !seenMcpIds.add(idValue)) {
          issues.add(ConfigIssue('$path.id', 'id wajib unik dan cocok [a-z][a-z0-9_-]{0,31}'));
          valid = false;
        }
        if (typeValue is! String || !const {'stdio', 'http'}.contains(typeValue)) {
          issues.add(ConfigIssue('$path.type', "type harus 'stdio' atau 'http'"));
          valid = false;
        }
        if (typeValue == 'http' &&
            (protocolVersionValue is! String ||
                !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(protocolVersionValue))) {
          issues.add(ConfigIssue('$path.protocol_version', 'harus berupa versi protokol YYYY-MM-DD'));
          valid = false;
        }
        if (typeValue == 'stdio' && entry.containsKey('protocol_version')) {
          issues.add(ConfigIssue('$path.protocol_version', 'hanya berlaku untuk server MCP type http'));
          valid = false;
        }
        if (typeValue == 'http' &&
            (maxReadRetriesValue is! int ||
                maxReadRetriesValue < 0 ||
                maxReadRetriesValue > 3)) {
          issues.add(ConfigIssue('$path.max_read_retries', 'harus berupa bilangan bulat 0–3'));
          valid = false;
        }
        if (typeValue == 'stdio' && entry.containsKey('max_read_retries')) {
          issues.add(ConfigIssue('$path.max_read_retries', 'hanya berlaku untuk server MCP type http'));
          valid = false;
        }
        if (typeValue == 'stdio') {
          if (commandValue is! String || commandValue.trim().isEmpty || commandValue.contains('\u0000')) {
            issues.add(ConfigIssue('$path.command', 'command wajib berupa string executable untuk server stdio'));
            valid = false;
          }
        } else {
          if (commandValue != null) {
            issues.add(ConfigIssue('$path.command', 'command hanya berlaku untuk server stdio'));
            valid = false;
          }
          if (urlValue is! String || urlValue.trim().isEmpty) {
            issues.add(ConfigIssue('$path.url', 'url wajib untuk server http'));
            valid = false;
          } else {
            final uri = Uri.tryParse(urlValue);
            if (uri == null ||
                !const {'http', 'https'}.contains(uri.scheme) ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty ||
                uri.hasFragment ||
                RegExp(r'[\x00-\x20\x7F]').hasMatch(urlValue)) {
              issues.add(ConfigIssue(
                '$path.url',
                'harus berupa URL HTTP/HTTPS tanpa user-info, fragment, atau karakter kontrol',
              ));
              valid = false;
            }
          }
        }
        if (argsValue != null && (argsValue is! YamlList || argsValue.length > 32 || argsValue.any((v) => v is! String || v.length > 2048))) {
          issues.add(ConfigIssue('$path.args', 'args harus berupa daftar string (maksimal 32)'));
          valid = false;
        }
        if (allowValue is! YamlList || allowValue.isEmpty || allowValue.length > 128 || allowValue.any((v) => v is! String || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$').hasMatch(v))) {
          issues.add(ConfigIssue('$path.allow', 'allow wajib berupa allowlist nama tool yang tidak kosong'));
          valid = false;
        }
        if (riskValue is! String || !const {'medium', 'high', 'critical'}.contains(riskValue)) {
          issues.add(ConfigIssue('$path.risk', 'risiko MCP minimal medium'));
          valid = false;
        }
        if (enabledValue is! bool) {
          issues.add(ConfigIssue('$path.enabled', 'harus berupa boolean'));
          valid = false;
        }
        final envRefs = <String, String>{};
        if (envValue != null && envValue is! YamlMap) {
          issues.add(ConfigIssue('$path.env', 'harus berupa mapping nama variabel ke SecretRef env:'));
          valid = false;
        } else if (envValue is YamlMap) {
          for (final item in envValue.entries) {
            final key = item.key;
            final ref = item.value;
            if (key is! String || !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(key) ||
                ref is! String || !RegExp(r'^env:[A-Z_][A-Z0-9_]{0,127}$').hasMatch(ref)) {
              issues.add(ConfigIssue('$path.env', 'setiap nilai wajib berupa SecretRef env:NAMA_VAR; secret mentah dilarang'));
              valid = false;
            } else {
              envRefs[key] = ref;
            }
          }
        }
        final headerRefs = <String, String>{};
        if (headersValue != null && headersValue is! YamlMap) {
          issues.add(ConfigIssue('$path.headers', 'harus berupa mapping nama header ke SecretRef env:'));
          valid = false;
        } else if (headersValue is YamlMap) {
          if (headersValue.length > 32) {
            issues.add(ConfigIssue('$path.headers', 'maksimal 32 header MCP'));
            valid = false;
          }
          for (final item in headersValue.entries) {
            final key = item.key;
            final ref = item.value;
            if (key is! String ||
                !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(key) ||
                const {
                  'content-type',
                  'accept',
                  'mcp-session-id',
                  'mcp-protocol-version',
                }.contains(key.toLowerCase()) ||
                ref is! String ||
                !RegExp(r'^env:[A-Z_][A-Z0-9_]{0,127}$').hasMatch(ref)) {
              issues.add(ConfigIssue('$path.headers', 'header harus aman dan bernilai SecretRef env:NAMA_VAR; header protokol tidak boleh ditimpa'));
              valid = false;
            } else {
              headerRefs[key] = ref;
            }
          }
        }
        var oauthTokenUrl = '';
        var oauthClientId = '';
        var oauthClientSecretRef = '';
        final oauthScopes = <String>[];
        final oauthValue = entry['oauth'];
        if (oauthValue != null) {
          if (typeValue != 'http') {
            issues.add(ConfigIssue('$path.oauth', 'oauth hanya berlaku untuk server type http'));
            valid = false;
          } else if (oauthValue is! YamlMap) {
            issues.add(ConfigIssue('$path.oauth', 'harus berupa mapping'));
            valid = false;
          } else {
            final tokenUrlValue = oauthValue['token_url'];
            final clientIdValue = oauthValue['client_id'];
            final clientSecretValue = oauthValue['client_secret'];
            final scopesValue = oauthValue['scopes'];
            if (tokenUrlValue is! String || tokenUrlValue.trim().isEmpty) {
              issues.add(ConfigIssue('$path.oauth.token_url', 'wajib berupa URL token endpoint'));
              valid = false;
            } else {
              final uri = Uri.tryParse(tokenUrlValue);
              if (uri == null ||
                  !const {'http', 'https'}.contains(uri.scheme) ||
                  uri.host.isEmpty ||
                  uri.userInfo.isNotEmpty ||
                  uri.hasFragment ||
                  RegExp(r'[\x00-\x20\x7F]').hasMatch(tokenUrlValue)) {
                issues.add(ConfigIssue(
                  '$path.oauth.token_url',
                  'harus berupa URL HTTP/HTTPS tanpa user-info, fragment, atau karakter kontrol',
                ));
                valid = false;
              } else {
                oauthTokenUrl = tokenUrlValue;
              }
            }
            if (clientIdValue is! String || clientIdValue.trim().isEmpty || clientIdValue.length > 128) {
              issues.add(ConfigIssue('$path.oauth.client_id', 'wajib berupa string 1-128 karakter'));
              valid = false;
            } else {
              oauthClientId = clientIdValue;
            }
            if (clientSecretValue is! String ||
                !RegExp(r'^env:[A-Z_][A-Z0-9_]{0,127}$').hasMatch(clientSecretValue)) {
              issues.add(ConfigIssue(
                '$path.oauth.client_secret',
                "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
              ));
              valid = false;
            } else {
              oauthClientSecretRef = clientSecretValue;
            }
            if (scopesValue != null) {
              if (scopesValue is! YamlList ||
                  scopesValue.length > 32 ||
                  scopesValue.any((v) => v is! String || v.isEmpty || v.length > 128)) {
                issues.add(ConfigIssue('$path.oauth.scopes', 'harus berupa daftar string (maksimal 32)'));
                valid = false;
              } else {
                oauthScopes.addAll(scopesValue.cast<String>());
              }
            }
          }
        }
        if (valid) {
          mcpServers.add(McpServerConfig(
            id: idValue as String,
            type: typeValue as String,
            command: commandValue is String ? commandValue : null,
            args: (argsValue as YamlList?)?.cast<String>().toList() ?? const [],
            url: urlValue is String ? urlValue : null,
            protocolVersion: protocolVersionValue as String,
            maxReadRetries: maxReadRetriesValue as int,
            headerRefs: headerRefs,
            allow: (allowValue as YamlList).cast<String>().toList(),
            risk: riskValue as String,
            enabled: enabledValue as bool,
            environmentRefs: envRefs,
            oauthTokenUrl: oauthTokenUrl.isEmpty ? null : oauthTokenUrl,
            oauthClientId: oauthClientId.isEmpty ? null : oauthClientId,
            oauthClientSecretRef: oauthClientSecretRef.isEmpty ? null : oauthClientSecretRef,
            oauthScopes: oauthScopes,
          ));
        }
      }
    }

    final defaultProvider = str(providersSec['default_chat'], 'mock');
    if (!providers.containsKey(defaultProvider)) {
      issues.add(ConfigIssue(
        'providers.default_chat',
        "provider '$defaultProvider' tidak terdefinisi",
      ));
    } else if (!providers[defaultProvider]!.enabled) {
      issues.add(ConfigIssue(
        'providers.default_chat',
        "provider '$defaultProvider' dipilih sebagai default tetapi disabled",
      ));
    }
    // ---- providers.tiers: pemetaan tier routing adaptif (ALG-06) ----
    final tierProviders = <int, String>{};
    final tiersValue = providersSec['tiers'];
    if (tiersValue != null && tiersValue is! YamlMap) {
      issues.add(const ConfigIssue(
        'providers.tiers',
        'harus berupa mapping tier (1|2|3) ke id provider',
      ));
    } else if (tiersValue is YamlMap) {
      for (final entry in tiersValue.entries) {
        final key = entry.key;
        final value = entry.value;
        final tier = key is int ? key : int.tryParse('$key');
        if (tier == null || tier < 1 || tier > 3) {
          issues.add(ConfigIssue(
            'providers.tiers.$key',
            'tier harus 1, 2, atau 3',
          ));
          continue;
        }
        if (value is! String || value.trim().isEmpty) {
          issues.add(ConfigIssue(
            'providers.tiers.$key',
            'harus berupa id provider yang tidak kosong',
          ));
          continue;
        }
        if (!providers.containsKey(value)) {
          issues.add(ConfigIssue(
            'providers.tiers.$key',
            "provider '$value' tidak terdefinisi",
          ));
          continue;
        }
        if (!providers[value]!.enabled) {
          issues.add(ConfigIssue(
            'providers.tiers.$key',
            "provider '$value' disabled",
          ));
          continue;
        }
        tierProviders[tier] = value;
      }
    }

    final configuredPort = api['port'];
    if (configuredPort != null &&
        (configuredPort is! int || configuredPort < 1 || configuredPort > 65535)) {
      issues.add(const ConfigIssue('api.port', 'harus berupa integer 1 sampai 65535'));
    }
    final mode = str(security['mode'], 'ask');
    if (!const {'auto', 'ask', 'deny'}.contains(mode)) {
      issues.add(ConfigIssue('security.mode', "mode '$mode' tidak dikenal"));
    }
    if (mode == 'auto') {
      issues.add(const ConfigIssue(
        'security.mode',
        "mode 'auto' mengurangi konfirmasi; pakai 'ask' kecuali sadar risikonya",
        fatal: false,
      ));
    }

    final cfg = TikoConfig(
      profile: str(root['profile'], 'default'),
      workspace: str(root['workspace'], '.'),
      dataDir: str(storage['data_dir'], 'data'),
      logsDir: str(root['logs_dir'], 'logs'),
      dbPath: str(storage['db_path'], 'data/agent.db'),
      defaultProvider: providers.containsKey(defaultProvider)
          ? defaultProvider
          : providers.keys.first,
      providers: providers,
      tierProviders: tierProviders,
      permissionMode: const {'auto', 'ask', 'deny'}.contains(mode) ? mode : 'ask',
      shellAllowlist: strList(security['shell_allowlist'],
          const ['ls', 'cat', 'git status', 'pwd', 'echo']),
      requireConfirm: strList(security['require_confirm'], const [
        'write_file',
        'patch_file',
        'shell',
        'http_request',
        'schedule_job',
      ]),
      httpDomainAllowlist: strList(http['domain_allowlist'], const []),
      mcpServers: mcpServers,
      decision: decisionCfg,
      memoryEmbed: memoryEmbedCfg,
      memoryProviders: memoryProvidersCfg,
      searxngBaseUrl: str(search['searxng_base_url'], 'http://127.0.0.1:8080'),
      tavilyApiKeyRef:
          tavilyKeyValue is String && tavilyKeyValue.startsWith('env:')
              ? tavilyKeyValue
              : null,
      maxIterations: intOf(agent['max_iterations'], 12),
      maxTokensPerTask: intOf(agent['max_tokens_per_task'], 60000),
      maxWallClockSec: intOf(agent['max_wall_clock_sec'], 300),
      maxToolCalls: intOf(agent['max_tool_calls'], 30),
      toolSubsetThreshold: intOf(agent['tool_subset_threshold'], 24),
      toolSubsetK: intOf(agent['tool_subset_k'], 20),
      apiPort: configuredPort is int && configuredPort >= 1 && configuredPort <= 65535
          ? configuredPort
          : 8787,
      enableImageGeneration: imageGenValue == true,
      enableVision: visionValue == true,
      sandboxDockerPersistent:
          root['sandbox'] is YamlMap &&
              (root['sandbox'] as YamlMap)['container_persistent'] == true,
      falApiKeyRef:
          falKeyValue is String && falKeyValue.startsWith('env:')
              ? falKeyValue
              : null,
      openaiApiKeyRef:
          featuresOpenaiKeyValue is String &&
                  featuresOpenaiKeyValue.startsWith('env:')
              ? featuresOpenaiKeyValue
              : null,
    );
    return (cfg, issues);
  }

  static DecisionConfig _parseDecision(YamlMap sec, List<ConfigIssue> issues) {
    final enabledValue = sec['enabled'];
    if (enabledValue != null && enabledValue is! bool) {
      issues.add(const ConfigIssue('decision.enabled', 'harus berupa boolean'));
    }
    final baseUrlValue = sec['base_url'];
    if (baseUrlValue != null &&
        (baseUrlValue is! String || baseUrlValue.trim().isEmpty)) {
      issues.add(const ConfigIssue(
        'decision.base_url',
        'harus berupa URL string yang tidak kosong',
      ));
    } else if (baseUrlValue is String) {
      final uri = Uri.tryParse(baseUrlValue);
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        issues.add(const ConfigIssue(
          'decision.base_url',
          'harus berupa URL HTTP/HTTPS yang valid',
        ));
      }
    }
    final modelValue = sec['model'];
    if (modelValue != null && (modelValue is! String || modelValue.trim().isEmpty)) {
      issues.add(const ConfigIssue('decision.model', 'harus berupa string yang tidak kosong'));
    }
    final apiKeyValue = sec['api_key'];
    if (apiKeyValue is String &&
        apiKeyValue.isNotEmpty &&
        !apiKeyValue.startsWith('env:')) {
      issues.add(const ConfigIssue(
        'decision.api_key',
        "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
      ));
    }
    final llmFallbackValue = sec['llm_fallback'];
    if (llmFallbackValue != null && llmFallbackValue is! bool) {
      issues.add(const ConfigIssue('decision.llm_fallback', 'harus berupa boolean'));
    }
    return DecisionConfig(
      enabled: enabledValue is bool ? enabledValue : false,
      baseUrl: baseUrlValue is String && baseUrlValue.trim().isNotEmpty
          ? baseUrlValue
          : 'https://api.typesafe.ai',
      model: modelValue is String && modelValue.trim().isNotEmpty
          ? modelValue
          : 'jev-latest',
      apiKeyRef: apiKeyValue is String && apiKeyValue.isNotEmpty
          ? apiKeyRefOf(apiKeyValue)
          : null,
      llmFallback: llmFallbackValue is bool ? llmFallbackValue : false,
    );
  }

  static String? apiKeyRefOf(String value) =>
      value.startsWith('env:') ? value : null;

  static MemoryEmbedConfig _parseMemoryEmbed(
    YamlMap sec,
    List<ConfigIssue> issues,
  ) {
    final embed = sec['embed'];
    if (embed != null && embed is! YamlMap) {
      issues.add(const ConfigIssue('memory.embed', 'harus berupa mapping'));
      return const MemoryEmbedConfig();
    }
    final m = embed is YamlMap ? embed : YamlMap();
    final enabledValue = m['enabled'];
    if (enabledValue != null && enabledValue is! bool) {
      issues.add(const ConfigIssue('memory.embed.enabled', 'harus berupa boolean'));
    }
    final baseUrlValue = m['base_url'];
    if (baseUrlValue != null && (baseUrlValue is! String || baseUrlValue.trim().isEmpty)) {
      issues.add(const ConfigIssue('memory.embed.base_url', 'harus berupa string yang tidak kosong'));
    }
    final modelValue = m['model'];
    if (modelValue != null && (modelValue is! String || modelValue.trim().isEmpty)) {
      issues.add(const ConfigIssue('memory.embed.model', 'harus berupa string yang tidak kosong'));
    }
    return MemoryEmbedConfig(
      enabled: enabledValue is bool ? enabledValue : false,
      baseUrl: baseUrlValue is String && baseUrlValue.trim().isNotEmpty
          ? baseUrlValue
          : 'http://127.0.0.1:11434',
      model: modelValue is String && modelValue.trim().isNotEmpty
          ? modelValue
          : 'nomic-embed-text',
    );
  }

  static List<ExternalMemoryProviderConfig> _parseMemoryProviders(
    YamlMap sec,
    List<ConfigIssue> issues,
  ) {
    final raw = sec['external_providers'];
    if (raw == null) return const [];
    if (raw is! YamlList) {
      issues.add(const ConfigIssue(
        'memory.external_providers',
        'harus berupa daftar mapping',
      ));
      return const [];
    }
    final out = <ExternalMemoryProviderConfig>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! YamlMap) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i]',
          'harus berupa mapping',
        ));
        continue;
      }
      final kindValue = entry['kind'];
      final kind = kindValue is String && kindValue.trim().isNotEmpty
          ? kindValue.trim()
          : 'http';
      if (!const {
        'http',
        'mem0',
        'honcho',
        'supermemory',
        'hindsight',
      }.contains(kind)) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i].kind',
          'harus salah satu dari: http, mem0, honcho, supermemory, hindsight',
        ));
        continue;
      }
      final baseUrl = entry['base_url'];
      final needsBaseUrl = kind == 'http' || kind == 'hindsight';
      final hasBaseUrl = baseUrl is String && baseUrl.trim().isNotEmpty;
      if (needsBaseUrl && !hasBaseUrl) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i].base_url',
          needsBaseUrl
              ? 'harus berupa string yang tidak kosong'
              : 'harus berupa string (opsional untuk kind mem0/honcho/supermemory)',
        ));
        continue;
      }
      final nameValue = entry['name'];
      if (nameValue != null && nameValue is! String) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i].name',
          'harus berupa string',
        ));
      }
      final keyValue = entry['api_key'];
      if (keyValue != null && keyValue is! String) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i].api_key',
          'harus berupa string',
        ));
      }
      if (keyValue is String &&
          keyValue.isNotEmpty &&
          !keyValue.startsWith('env:')) {
        issues.add(ConfigIssue(
          'memory.external_providers[$i].api_key',
          "gunakan SecretRef 'env:NAMA_VAR', jangan menulis secret di file",
        ));
      }
      out.add(ExternalMemoryProviderConfig(
        baseUrl: hasBaseUrl ? baseUrl.trim() : '',
        kind: kind,
        name: nameValue is String && nameValue.trim().isNotEmpty
            ? nameValue.trim()
            : null,
        apiKeyRef: keyValue is String && keyValue.startsWith('env:')
            ? keyValue
            : null,
      ));
    }
    return out;
  }

  /// Generates the canonical onboarding configuration consumed by [parse].
  /// Only the documented first-run providers are accepted to avoid silently
  /// generating a config that cannot be constructed by ProviderFactory.
  static String setupYaml({
    String provider = 'mock',
    String workspace = '.',
  }) {
    final providerId = switch (provider) {
      'mock' => 'mock',
      'ollama' || 'ollama_native' => 'ollama_local',
      _ => throw ArgumentError.value(
          provider,
          'provider',
          'pilih mock atau ollama',
        ),
    };
    if (workspace.trim().isEmpty) {
      throw ArgumentError.value(workspace, 'workspace', 'tidak boleh kosong');
    }
    final selectedType = providerId == 'mock' ? 'mock' : 'ollama_native';
    String quote(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\r', '\\r').replaceAll('\n', '\\n').replaceAll('\t', '\\t')}"';

    return '''
# Generated by `tiko setup`; schema is validated by TikoConfig.
profile: default
workspace: ${quote(workspace)}
logs_dir: "logs"
agent:
  max_iterations: 12
  max_tokens_per_task: 60000
  max_wall_clock_sec: 300
  max_tool_calls: 30
providers:
  default_chat: $providerId
  tiers: {}
  chat:
    mock:
      type: mock
      enabled: ${selectedType == 'mock'}
    ollama_local:
      type: ollama_native
      base_url: "http://127.0.0.1:11434"
      model: "qwen2.5:3b"
      enabled: ${selectedType == 'ollama_native'}
security:
  mode: ask
  shell_allowlist: ["ls", "pwd", "echo", "git status"]
  require_confirm: ["write_file", "patch_file", "shell", "http_request"]
storage:
  data_dir: "data"
  db_path: "data/agent.db"
api:
  port: 8787
search:
  searxng_base_url: "http://127.0.0.1:8080"
http:
  domain_allowlist: []
mcp:
  servers: []
decision:
  enabled: false
  base_url: "https://api.typesafe.ai"
  model: "jev-latest"
  llm_fallback: false
memory:
  embed:
    enabled: false
    base_url: "http://127.0.0.1:11434"
    model: "nomic-embed-text"
'''.trimLeft();
  }

  static (TikoConfig, List<ConfigIssue>) load(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      final (defaults, _) = parse('');
      return (
        defaults,
        [ConfigIssue(path, 'file config tidak ditemukan, memakai default', fatal: false)],
      );
    }
    return parse(f.readAsStringSync());
  }

  /// Resolves `env:NAME` to the environment value; returns null when unset.
  static String? resolveSecretRef(String? ref, {Map<String, String>? env}) {
    if (ref == null || !ref.startsWith('env:')) return null;
    final v = (env ?? Platform.environment)[ref.substring(4)];
    return (v == null || v.isEmpty) ? null : v;
  }
}
