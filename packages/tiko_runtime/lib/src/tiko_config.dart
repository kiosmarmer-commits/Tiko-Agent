import 'dart:io';

import 'package:yaml/yaml.dart';

/// One provider entry under `providers.chat.<id>`.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.type,
    this.baseUrl,
    this.model,
    this.apiKeyRef,
    this.enabled = true,
  });

  final String id;

  /// mock | openai_compat | ollama_native | anthropic | gemini
  final String type;
  final String? baseUrl;
  final String? model;

  /// A [SecretRef] such as `env:OPENAI_API_KEY`. Never a raw secret.
  final String? apiKeyRef;
  final bool enabled;
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
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.tavilyApiKeyRef,
    this.maxIterations = 12,
    this.maxTokensPerTask = 60000,
    this.maxWallClockSec = 300,
    this.maxToolCalls = 30,
    this.apiPort = 8787,
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
  final String searxngBaseUrl;

  /// SecretRef `env:TAVILY_API_KEY` untuk cadangan Tavily (AGD-04 §7);
  /// null berarti fallback nonaktif.
  final String? tavilyApiKeyRef;
  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;
  final int apiPort;

  static const knownProviderTypes = {
    'mock',
    'openai_compat',
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

    // ---- decision (Jev/Laya systemone) ----
    final decisionCfg = _parseDecision(decisionSec, issues);

    // ---- memory.embed ----
    final memoryEmbedCfg = _parseMemoryEmbed(memorySec, issues);

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
        final enabledValue = v['enabled'];
        var invalidField = false;
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
        if (!knownProviderTypes.contains(type)) {
          issues.add(ConfigIssue(
            'providers.chat.$id.type',
            "tipe '$type' tidak didukung (${knownProviderTypes.join('|')})",
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
        providers[id] = ProviderConfig(
          id: id,
          type: type,
          baseUrl: baseUrlValue as String?,
          model: modelValue as String?,
          apiKeyRef: keyRef is String && keyRef.isNotEmpty ? keyRef : null,
          enabled: enabledValue is bool ? enabledValue : true,
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
      searxngBaseUrl: str(search['searxng_base_url'], 'http://127.0.0.1:8080'),
      tavilyApiKeyRef:
          tavilyKeyValue is String && tavilyKeyValue.startsWith('env:')
              ? tavilyKeyValue
              : null,
      maxIterations: intOf(agent['max_iterations'], 12),
      maxTokensPerTask: intOf(agent['max_tokens_per_task'], 60000),
      maxWallClockSec: intOf(agent['max_wall_clock_sec'], 300),
      maxToolCalls: intOf(agent['max_tool_calls'], 30),
      apiPort: configuredPort is int && configuredPort >= 1 && configuredPort <= 65535
          ? configuredPort
          : 8787,
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
