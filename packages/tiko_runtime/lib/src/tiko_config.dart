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
    this.weight = 1,
    this.cost,
    this.members = const [],
    this.moaStrategy,
    this.moaRanker,
  });

  final String id;

  /// Built-in type, a [providerPresets] id (e.g. `deepseek`), or one of the
  /// Hermes-parity transports: `openai_responses`, `azure_openai`, `bedrock`.
  final String type;
  final String? baseUrl;
  final String? model;

  /// A [SecretRef] such as `env:OPENAI_API_KEY`. Never a raw secret.
  final String? apiKeyRef;

  /// Mock-only behavior selector: plain | assisted | single_tool |
  /// multi_tool | loop_trap. Kosong = `assisted` (jawaban kontekstual).
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

  /// Hermes-parity P6: prioritas fallback. Urutan fallback (setelah primary)
  /// = weight desc, lalu cost asc, lalu urutan config (stabil). Default 1
  /// = neutral; semua provider setara.
  final int weight;

  /// Hermes-parity P6: biaya relatif per permintaan (opsional, >= 0);
  /// hanya penentu urutan saat [weight] sama, dan `null` = tak diketahui
  /// (diperlakukan netral).
  final double? cost;

  /// MoA (R3): id provider member (proposer) yang dirujuk dari
  /// `providers.chat.*`. Hanya untuk `type: moa`.
  final List<String> members;

  /// MoA: `majority` (default) | `ranker` | `first`.
  final String? moaStrategy;

  /// MoA: id provider aggregator untuk `strategy: ranker`.
  final String? moaRanker;
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

/// S22 — konfigurasi indeks kode semantik (`code.index`). Indexer membaca
/// workspace lokal, menyimpan chunk+embedding persisten (aditif, read-only
/// terhadap kode). Default enabled dengan fallback hashing offline; bila
/// `memory.embed.enabled`, provider embedding dipakai untuk vektor penuh.
class CodeIndexConfig {
  const CodeIndexConfig({
    this.enabled = true,
    this.maxChunks = 6000,
  });

  final bool enabled;
  final int maxChunks;
}

/// Administrator-declared external memory provider (Hermes-style memory
/// providers). Credentials are references to env vars; raw secrets are
/// never accepted in the YAML configuration.
/// Plugin out-of-process yang di-spawn runtime saat startup (rekomendasi #5).
/// Plugin berjalan sebagai proses OS terpisah dan tunduk pada capability
/// consent sebelum hook-nya aktif.
class ProcessPluginConfig {
  const ProcessPluginConfig({
    required this.name,
    required this.command,
    this.args = const [],
    this.permissions = const [],
  });

  /// Id plugin (`^[a-z][a-z0-9-]{1,63}$`, sama dengan PluginManifest).
  final String name;

  /// Executable yang di-spawn (mis. `dart`, `python3`, binary bundle).
  final String command;
  final List<String> args;

  /// Permission yang diminta (`tools.read`, `memory.write`, dst — kosakata
  /// [PluginPermission]); tidak dikenal = gagal validasi (fail-closed).
  final List<String> permissions;
}

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
/// Opt-in (E1): deteksi anomali token per skill. Default false.
class TokenAnomalyConfig {
  const TokenAnomalyConfig({
    this.enabled = false,
    this.minSamples = 5,
    this.windowSize = 50,
    this.zMultiplier = 3.0,
    this.minSpikeRatio = 3.0,
    this.cooldownMinutes = 60,
    this.maxQuarantinesPerDay = 3,
  });

  final bool enabled;

  /// Sampel minimum sebelum baseline dipercaya.
  final int minSamples;

  /// Ukuran jendela rolling per skill.
  final int windowSize;

  /// Ambang z-score: tokens > mean + z * stddev.
  final double zMultiplier;

  /// Lantai rasio: tokens >= mean * rasio (anti false-positive baseline
  /// datar).
  final double minSpikeRatio;

  /// Jeda minimum antar alarm untuk skill yang sama.
  final int cooldownMinutes;

  /// Cap karantina skill per UTC day (anti-spam penindakan).
  final int maxQuarantinesPerDay;
}

/// Opt-in (E2): konsolidasi memori idle via LLM auxiliar. Default false.
class IdleConsolidationCfg {
  const IdleConsolidationCfg({
    this.enabled = false,
    this.idleTurns = 25,
    this.minCandidates = 5,
    this.maxEntriesPerBatch = 20,
    this.maxSummariesPerDay = 6,
    this.maxRetention = 0.5,
    this.maxOutputFacts = 8,
  });

  final bool enabled;
  final int idleTurns;
  final int minCandidates;
  final int maxEntriesPerBatch;
  final int maxSummariesPerDay;
  final double maxRetention;
  final int maxOutputFacts;
}

/// Aturan event hook Hermes-parity (P1): event lifecycle runtime memicu
/// POST webhook atau eksekusi script workspace dari config `hooks:`.

class HookRuleConfig {
  const HookRuleConfig({
    required this.event,
    this.webhookUrl,
    this.script,
    this.timeoutSec = 30,
    this.env = const {},
  });

  /// Nama event EventBus (mis. `model.switched`, `approval.denied`) atau
  /// `*` untuk semua event.
  final String event;

  /// URL webhook HTTP(S) — POST JSON `{event, at, data}`. Salah satu dari
  /// [webhookUrl]/[script] wajib ada (divalidasi di parser).
  final String? webhookUrl;

  /// Path script relatif di dalam workspace (tanpa `..`, tanpa absolut) —
  /// dijalankan via `sh` dengan env minimal `TIKO_EVENT` +
  /// `TIKO_EVENT_DATA_JSON`.
  final String? script;

  /// Batas waktu 1..120 detik (divalidasi di parser).
  final int timeoutSec;

  /// Variabel env tambahan non-rahasia untuk script hook.
  final Map<String, String> env;

  Map<String, dynamic> toJson() => {
        'event': event,
        if (webhookUrl != null) 'webhook': webhookUrl,
        if (script != null) 'script': script,
        'timeout_sec': timeoutSec,
        'env': env,
      };

  /// Aturan siap ditulis ke config `hooks:` (Hermes-parity P1).
  Map<String, dynamic> toYamlEntry() => {
        'event': event,
        if (webhookUrl != null) 'webhook': webhookUrl,
        if (script != null) 'script': script,
        'timeout_sec': timeoutSec,
        if (env.isNotEmpty) 'env': env,
      };

  /// Validasi satu aturan dari payload JSON (API/GUI). Konsisten dengan
  /// parser config `_parseHooks`: aturan tanpa target, timeout out-of-range,
  /// atau path script yang keluar workspace ditolak.
  static List<String> validateJson(Map<String, dynamic> raw) {
    final errors = <String>[];
    final event = raw['event'];
    if (event is! String || event.trim().isEmpty) {
      errors.add('event harus string non-kosong (nama event atau *)');
    }
    final webhook = raw['webhook'];
    if (webhook != null &&
        (webhook is! String ||
            !(webhook.startsWith('http://') ||
                webhook.startsWith('https://')))) {
      errors.add('webhook harus URL http:// atau https://');
    }
    final script = raw['script'];
    if (script != null && script is! String) {
      errors.add('script harus berupa path string');
    }
    final scriptPath = script is String ? script.trim() : null;
    if (scriptPath != null &&
        (scriptPath.startsWith('/') ||
            scriptPath.startsWith('~') ||
            scriptPath.split('/').contains('..'))) {
      errors.add('script harus path relatif dalam workspace (tanpa .. atau absolut)');
    }
    if ((webhook == null || (webhook as String?)!.trim().isEmpty) &&
        (scriptPath == null || scriptPath.isEmpty)) {
      errors.add('butuh salah satu webhook atau script');
    }
    final timeout = raw['timeout_sec'];
    if (timeout != null &&
        (timeout is! int || timeout < 1 || timeout > 120)) {
      errors.add('timeout_sec harus integer 1..120');
    }
    final env = raw['env'];
    if (env != null) {
      if (env is! Map) {
        errors.add('env harus mapping string');
      } else if (env.keys.any((k) => k is! String) ||
          env.values.any((v) => v is! String)) {
        errors.add('env harus mapping string');
      }
    }
    return errors;
  }

  /// Bangun aturan dari payload JSON yang sudah lolos [validateJson];
  /// field tidak dikenal diabaikan.
  static HookRuleConfig fromJson(Map<String, dynamic> raw) {
    final event = (raw['event'] as String).trim();
    final webhook = (raw['webhook'] as String?)?.trim();
    final script = (raw['script'] as String?)?.trim();
    final timeout = raw['timeout_sec'];
    final envRaw = raw['env'];
    return HookRuleConfig(
      event: event,
      webhookUrl: (webhook == null || webhook.isEmpty) ? null : webhook,
      script: (script == null || script.isEmpty) ? null : script,
      timeoutSec: timeout is int ? timeout : 30,
      env: envRaw is Map
          ? {
              for (final e in envRaw.entries) '${e.key}': '${e.value}',
            }
          : const {},
    );
  }
}

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
    this.securityProfile = 'strict',
    this.riskOverrides = const {},
    this.httpDomainAllowlist = const [],
    this.a2uiOpenUrlAllow = const [],
    this.mcpServers = const [],
    this.mcpAnswerServerRequests = false,
    this.decision = const DecisionConfig(),
    this.memoryEmbed = const MemoryEmbedConfig(),
    this.codeIndex = const CodeIndexConfig(),
    this.memoryProviders = const [],
    this.processPlugins = const [],
    this.hooks = const [],
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
    this.contextCompaction = true,
    this.compactorThresholdRatio = 0.7,
    this.compactorKeepLastN = 6,
    this.compactorMaxSoftTokens = 6000,
    this.apiPort = 8787,
    this.enableImageGeneration = false,
    this.enableVideoGeneration = false,
    this.enableVision = false,
    this.sandboxDockerPersistent = false,
    this.sandboxAllowHostExec = false,
    this.agentEditLoopVerify = false,
    this.agentIdeIntegration = false,
    this.agentComputerUse = false,
    this.agentErrorRecall = true,
    this.agentAutoTitle = true,
    this.agentTitleModelUpgrade = false,
    this.dailyCreditLimitUsd = 0.0,
    this.memoryNudgeIntervalTurns = 10,
    this.memoryCuratedCharBudget = 3575,
    this.interruptRedirect = true,
    this.schedulerDuplicatePolicy = 'resend',
    this.scriptSelfRepair = false,
    this.tokenAnomaly = const TokenAnomalyConfig(),
    this.idleConsolidation = const IdleConsolidationCfg(),
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

  /// Hermes-parity P6 — urutan fallback chain chat provider: [primary] di
  /// depan, lalu provider enabled diurutkan weight desc, cost asc, dan
  /// urutan config sebagai tie-breaker stabil (index-numbered sort karena
  /// List.sort tidak stabil). Disabled tidak pernah masuk chain.
  List<String> fallbackChainIds(String primary) {
    final ids = providers.keys.toList();
    final ranked = <MapEntry<int, ProviderConfig>>[
      for (var i = 0; i < ids.length; i++)
        if (ids[i] != primary && providers[ids[i]]!.enabled)
          MapEntry(i, providers[ids[i]]!),
    ]..sort((a, b) {
        final byWeight = b.value.weight.compareTo(a.value.weight);
        if (byWeight != 0) return byWeight;
        final ac = a.value.cost;
        final bc = b.value.cost;
        if (ac != null && bc != null && ac != bc) {
          return ac.compareTo(bc);
        }
        if (ac != null && bc == null) return -1;
        if (ac == null && bc != null) return 1;
        return a.key.compareTo(b.key);
      });
    return [primary, ...ranked.map((e) => e.value.id)];
  }

  final String permissionMode;
  final List<String> shellAllowlist;
  final List<String> requireConfirm;

  /// F8.1 (docs/15 §9) — profil security preset: `strict` (default,
  /// perilaku lama), `standard` (mode `guided` + allowlist toolchain dev +
  /// override `verify_project: medium`), `trusted_workspace` (standard, tapi
  /// medium tidak dikonfirmasi lagi). Preset hanya mengisi field yang TIDAK
  /// diset eksplisit di `security.*`; nilai eksplisit selalu menang.
  final String securityProfile;

  /// F8.1 — koreksi risiko per-tool (`tool -> low|medium|high|critical`)
  /// dari `security.risk_overrides`, diteruskan ke MatrixPermissionGate.
  /// Kepemilikan operator: bagian config di luar jangkauan jail workspace.
  final Map<String, String> riskOverrides;

  final List<String> httpDomainAllowlist;

  /// Allowlist URL untuk aksi `open_url` pada surface A2UI (E5); entri
  /// `host`, `https://host/path`, atau wildcard `*.host`. Kosong = semua URL
  /// ditolak (fail-closed, diperiksa `A2uiOpenUrlPolicy`).
  final List<String> a2uiOpenUrlAllow;
  final List<McpServerConfig> mcpServers;

  /// Opt-in (C2): jawab request JSON-RPC ber-ID yang diinisiasi server MCP
  /// HTTP via GET SSE. Default false — request hanya dicatat (fail-closed).
  final bool mcpAnswerServerRequests;

  /// Opt-in (D3): loop koreksi-diri script (`script_selfheal`) — saat script
  /// gagal, error dikirim ke LLM auxiliar untuk patch, retry ≤3. Default
  /// false karena membakar token LLM dan mengeksekusi kode hasil LLM.
  final bool scriptSelfRepair;

  /// Opt-in (E1): deteksi anomali token per skill. Default false.
  final TokenAnomalyConfig tokenAnomaly;

  /// Opt-in (E2): konsolidasi memori idle via LLM auxiliar. Default false.
  final IdleConsolidationCfg idleConsolidation;
  final DecisionConfig decision;
  final MemoryEmbedConfig memoryEmbed;

  /// S22 — indeks kode semantik (`code.index`, default enabled).
  final CodeIndexConfig codeIndex;

  /// Nudge memori terkurasi: jarak giliran antar refleksi (0/0 turn =
  /// dinonaktifkan lewat features atau interval 0).
  final int memoryNudgeIntervalTurns;

  /// Anggaran karakter gabungan MEMORY.md + USER.md.
  final int memoryCuratedCharBudget;

  /// Interrupt-and-redirect: pesan baru saat sesi sibuk memotong turn
  /// aktif secara kooperatif lalu diproses setelah lock lepas.
  final bool interruptRedirect;

  /// Kebijakan delivery scheduler yang tertangkap di tengah pengiriman saat
  /// proses mati (pesan platform mungkin sudah terkirim): `resend` = kirim
  /// ulang (at-least-once, bisa duplikat); `review` = tandai gagal permanen
  /// untuk ditinjau operator (tanpa duplikat, risiko output tertahan).
  final String schedulerDuplicatePolicy;

  /// External memory providers fanned out together with the built-in store.
  final List<ExternalMemoryProviderConfig> memoryProviders;

  /// Plugin out-of-process yang di-spawn saat startup (tunduk consent).
  final List<ProcessPluginConfig> processPlugins;

  /// Aturan event hook (Hermes-parity P1); kosong = fitur nonaktif.
  final List<HookRuleConfig> hooks;
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

  /// Enable video generation tools (FAL.ai queue API, Hermes-parity P2-1)
  final bool enableVideoGeneration;

  /// Enable vision tools (image analysis, OCR)
  final bool enableVision;

  /// Hermes-parity `container_persistent`: keep one hardened docker container
  /// alive and dispatch commands via `docker exec` so state (cwd, installed
  /// packages, /work files) carries between tool calls. Off by default.
  final bool sandboxDockerPersistent;

  /// Fase F1 — opt-in eksplisit operator (`sandbox.allow_host_exec`, default
  /// false): bila tidak ada sandbox OS tersedia, tool `shell` boleh menjalankan
  /// argv TANPA interpreter shell di host (pola `verify_project`).
  /// Validasi metachar + PathSafety + jail workspace + approval tetap berlaku.
  final bool sandboxAllowHostExec;

  /// Fase F2 — edit loop guard (`agent.edit_loop_verify`, default false):
  /// setelah `patch_file` sukses, `verify_project` wajib sukses dulu sebelum
  /// tool lain dieksekusi.
  final bool agentEditLoopVerify;

  /// Fase F2 — wiring tool `ide_integration` (`agent.ide_integration`, default
  /// false): daftar tool live dari registry diteruskan ke ACP.
  final bool agentIdeIntegration;

  /// S20-A — Opt-in eksplisit tool computer-use (`agent.computer_use`,
  /// default false). Bila aktif, tool `computer_use` terdaftar dengan risk
  /// `high` (approval PermissionGate tetap wajib per aksi).
  final bool agentComputerUse;

  /// Fase F3 — auto-recall error memory (`agent.error_recall`, default true):
  /// ContextBuilder menarik maks 3 kecocokan dari ErrorMemoryStore per turn
  /// (read-only; matikan dengan `error_recall: false`).
  final bool agentErrorRecall;

  /// Hermes `title_generator`: judul sesi otomatis instant-deterministik.
  /// Judul yang diketik user tidak pernah ditimpa.
  final bool agentAutoTitle;

  /// Hermes `title_generator` tahap 2 (upgrade LLM kecil). **Default false**
  /// — deviasi sadar dari Hermes (default true): aux Tiko selalu berbagi
  /// endpoint dengan provider utama (BreakerLlmProvider di atas provider
  /// pertama router), dan Hermes sendiri menghindari panggilan judul
  /// serentak ke endpoint yang sama satu-slot (#117296).
  final bool agentTitleModelUpgrade;

  /// Hermes `credits_tracker`: limit pengeluaran USD per hari UTC (0 = off).
  final double dailyCreditLimitUsd;

  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;

  /// P2-2: dynamic tool-schema subset. When the registry carries more than
  /// [toolSubsetThreshold] tools, the model only receives the top
  /// [toolSubsetK] relevant specs plus `tool_search`.
  final int toolSubsetThreshold;
  final int toolSubsetK;

  /// ALG-05 kompresi konteks: false mematikan compactor (riwayat penuh
  /// selalu dikirim ke provider), true mengaktifkan ringkasan otomatis.
  final bool contextCompaction;

  /// Kompresi dipicu saat estimasi token riwayat (len/4) melampaui
  /// [compactorMaxSoftTokens] * [compactorThresholdRatio] (0.1..1.0).
  final double compactorThresholdRatio;

  /// Jumlah pesan terakhir yang dipertahankan apa adanya saat kompresi.
  final int compactorKeepLastN;

  /// Ambang token lembut ringkasan (estimasi len/4, bukan hitungan token
  /// provider); minimal 256, default 6000 sesuai ambang ALG-05.
  final int compactorMaxSoftTokens;
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
    'moa',
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
    final a2ui = sec('a2ui');
    final search = sec('search');
    final api = sec('api');
    final mcp = sec('mcp');
    final scriptSec = sec('script');
    final decisionSec = sec('decision');
    final memorySec = sec('memory');
    final featuresSec = sec('features');

    // ---- decision (Jev/Laya systemone) ----
    final decisionCfg = _parseDecision(decisionSec, issues);

    // ---- memory.embed ----
    final memoryEmbedCfg = _parseMemoryEmbed(memorySec, issues);

    // ---- code.index (S22) ----
    final codeIndexCfg = _parseCodeIndex(sec('code'), issues);

    // ---- memory.external_providers ----
    final memoryProvidersCfg = _parseMemoryProviders(memorySec, issues);

    // ---- plugins.process ----
    final processPluginsCfg = _parseProcessPlugins(sec('plugins'), issues);
    final hooksCfg = _parseHooks(issues, root: root);

    // ---- scheduler.duplicate_policy ----
    var schedulerDuplicatePolicy = 'resend';
    final dupPolicyRaw = sec('scheduler')['duplicate_policy'];
    if (dupPolicyRaw != null) {
      final value = dupPolicyRaw.toString();
      if (value == 'resend' || value == 'review') {
        schedulerDuplicatePolicy = value;
      } else {
        issues.add(const ConfigIssue(
          'scheduler.duplicate_policy',
          'harus resend atau review',
        ));
      }
    }

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
    final videoGenValue = featuresSec['video_generation'];
    if (videoGenValue != null && videoGenValue is! bool) {
      issues.add(const ConfigIssue(
          'features.video_generation', 'harus berupa boolean'));
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
      ('a2ui.open_url_allow', a2ui['open_url_allow']),
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
            'harus berupa string (plain | assisted | single_tool | multi_tool | loop_trap)',
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
        // Hermes-parity P6: weight/cost per provider (validasi non-fatal,
        // nilai invalid diabaikan agar config salah tidak membunuh runtime).
        var weightValue = 1;
        if (v['weight'] != null) {
          if (v['weight'] is int && (v['weight'] as int) >= 0) {
            weightValue = v['weight'] as int;
          } else {
            issues.add(ConfigIssue(
              'providers.chat.$id.weight',
              'harus berupa integer >= 0',
              fatal: false,
            ));
          }
        }
        double? costValue;
        final rawCost = v['cost'];
        if (rawCost != null) {
          final asNum = rawCost is num ? rawCost.toDouble() : null;
          if (asNum != null && asNum >= 0) {
            costValue = asNum;
          } else {
            issues.add(ConfigIssue(
              'providers.chat.$id.cost',
              'harus berupa angka >= 0',
              fatal: false,
            ));
          }
        }
        String? secretRefOf(dynamic value, String field) {
          if (value == null) return null;
          if (value is String && value.startsWith('env:')) return value;
          issues.add(ConfigIssue(
            'providers.chat.$id.$field',
            "gunakan SecretRef 'env:NAMA_VAR'",
          ));
          return null;
        }

        final membersValue = <String>[
          if (v['members'] is YamlList)
            for (final m in v['members'] as YamlList)
              if ('$m'.trim().isNotEmpty) '$m'.trim(),
        ];
        providers[id] = ProviderConfig(
          id: id,
          type: type,
          members: membersValue,
          moaStrategy: v['strategy'] is String ? v['strategy'] as String : null,
          moaRanker: v['ranker'] is String ? v['ranker'] as String : null,
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
          weight: weightValue,
          cost: costValue,
        );
      }
    }
    if (providers.isEmpty) {
      providers['mock'] = const ProviderConfig(id: 'mock', type: 'mock');
    }

    final rawAnswerServerRequests = mcp['answer_server_requests'];
    if (rawAnswerServerRequests != null && rawAnswerServerRequests is! bool) {
      issues.add(const ConfigIssue(
        'mcp.answer_server_requests',
        'harus boolean',
      ));
    }
    final mcpAnswerServerRequests = rawAnswerServerRequests is bool
        ? rawAnswerServerRequests
        : false;

    final rawScriptSelfRepair = scriptSec['self_repair'];
    if (rawScriptSelfRepair != null && rawScriptSelfRepair is! bool) {
      issues.add(const ConfigIssue(
        'script.self_repair',
        'harus boolean',
      ));
    }
    final scriptSelfRepair = rawScriptSelfRepair is bool
        ? rawScriptSelfRepair
        : false;

    // E1 (opt-in): security.token_anomaly
    final tokenAnomalyCfg = _parseTokenAnomaly(security['token_anomaly'],
        issues);

    // E2 (opt-in): memory.idle_consolidation
    final idleConsolidationCfg =
        _parseIdleConsolidation(memorySec['idle_consolidation'], issues);

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
    final modeRaw = security['mode'];
    final mode = str(modeRaw, 'ask');
    if (!const {'auto', 'guided', 'ask', 'deny'}.contains(mode)) {
      issues.add(ConfigIssue('security.mode', "mode '$mode' tidak dikenal"));
    }
    if (mode == 'auto') {
      issues.add(const ConfigIssue(
        'security.mode',
        "mode 'auto' mengurangi konfirmasi; pakai 'ask' kecuali sadar risikonya",
        fatal: false,
      ));
    }

    // F8.1: profil security preset. Nilai eksplisit di security.*
    // (mode, shell_allowlist, require_confirm, risk_overrides) selalu
    // menang atas preset; preset hanya mengisi celah.
    var secProfile = str(security['profile'], 'strict');
    if (!const {'strict', 'standard', 'trusted_workspace'}
        .contains(secProfile)) {
      issues.add(ConfigIssue(
        'security.profile',
        "profil '$secProfile' tidak dikenal; fallback 'strict'",
        fatal: false,
      ));
      secProfile = 'strict';
    }

    final riskOverrideRaw = security['risk_overrides'];
    final riskOverrides = <String, String>{};
    if (riskOverrideRaw != null) {
      if (riskOverrideRaw is! Map) {
        issues.add(const ConfigIssue(
          'security.risk_overrides',
          'harus berupa map tool -> label risiko',
          fatal: false,
        ));
      } else {
        for (final entry in riskOverrideRaw.entries) {
          final value = '${entry.value}';
          if (!const {'low', 'medium', 'high', 'critical'}
              .contains(value)) {
            issues.add(ConfigIssue(
              'security.risk_overrides.${entry.key}',
              "label '$value' tidak valid (low|medium|high|critical)",
              fatal: false,
            ));
            continue;
          }
          riskOverrides['${entry.key}'] = value;
        }
      }
    }

    // Preset allowlist toolchain dev — mode `guided` menanyakan sekali per
    // aksi high di luar allowlist ini, jadi toolchain build/test diriwayatkan
    // tanpa membuka metacharacter (ShellPolicy tetap menolak `;&|` dsb).
    const devTools = [
      'git status', 'git diff', 'git log',
      'dart', 'flutter', 'make', 'cmake',
      'gcc', 'g++', 'clang', 'javac', 'java',
      'go', 'cargo', 'rustc',
      'npm', 'node', 'npx',
      'python', 'python3', 'pip', 'pip3', 'pytest',
      'grep', 'wc', 'head', 'tail', 'find',
    ];
    final baseAllowlist = const ['ls', 'cat', 'git status', 'pwd', 'echo'];
    var permissionMode = modeRaw == null
        ? (secProfile == 'strict' ? 'ask' : 'guided')
        : (const {'auto', 'guided', 'ask', 'deny'}.contains(mode) ? mode : 'ask');
    var shellAllowlist = security['shell_allowlist'] == null
        ? (secProfile == 'strict'
            ? baseAllowlist
            : [...baseAllowlist, ...devTools])
        : strList(security['shell_allowlist'], baseAllowlist);
    if (riskOverrideRaw == null && secProfile != 'strict') {
      riskOverrides['verify_project'] = 'medium';
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
      permissionMode: permissionMode,
      shellAllowlist: List.unmodifiable(shellAllowlist),
      requireConfirm: security['require_confirm'] == null &&
              secProfile == 'trusted_workspace'
          ? const []
          : strList(security['require_confirm'], const [
              'write_file',
              'patch_file',
              'shell',
              'http_request',
              'schedule_job',
            ]),
      securityProfile: secProfile,
      riskOverrides: Map.unmodifiable(riskOverrides),
      httpDomainAllowlist: strList(http['domain_allowlist'], const []),
      a2uiOpenUrlAllow: strList(a2ui['open_url_allow'], const []),
      mcpServers: mcpServers,
      mcpAnswerServerRequests: mcpAnswerServerRequests,
      scriptSelfRepair: scriptSelfRepair,
      tokenAnomaly: tokenAnomalyCfg,
      idleConsolidation: idleConsolidationCfg,
      decision: decisionCfg,
      memoryEmbed: memoryEmbedCfg,
      codeIndex: codeIndexCfg,
      memoryProviders: memoryProvidersCfg,
      processPlugins: processPluginsCfg,
      hooks: hooksCfg,
      memoryNudgeIntervalTurns:
          intOf(memorySec['nudge_interval_turns'], 10),
      memoryCuratedCharBudget:
          intOf(memorySec['curated_char_budget'], 3575),
      interruptRedirect: agent['interrupt_redirect'] is! bool
          ? true
          : (agent['interrupt_redirect'] as bool),
      schedulerDuplicatePolicy: schedulerDuplicatePolicy,
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
      contextCompaction: agent['context_compaction'] is! bool
          ? true
          : (agent['context_compaction'] as bool),
      compactorThresholdRatio: _compactorRatio(agent['compactor_threshold_ratio']),
      compactorKeepLastN: _compactorKeepLastN(agent['compactor_keep_last_n']),
      compactorMaxSoftTokens:
          _compactorSoftTokens(agent['compactor_max_soft_tokens']),
      apiPort: configuredPort is int && configuredPort >= 1 && configuredPort <= 65535
          ? configuredPort
          : 8787,
      enableImageGeneration: imageGenValue == true,
      enableVideoGeneration: videoGenValue == true,
      enableVision: visionValue == true,
      sandboxDockerPersistent:
          root['sandbox'] is YamlMap &&
              (root['sandbox'] as YamlMap)['container_persistent'] == true,
      sandboxAllowHostExec:
          root['sandbox'] is YamlMap &&
              (root['sandbox'] as YamlMap)['allow_host_exec'] == true,
      agentEditLoopVerify:
          root['agent'] is YamlMap &&
              (root['agent'] as YamlMap)['edit_loop_verify'] == true,
      agentIdeIntegration:
          root['agent'] is YamlMap &&
              (root['agent'] as YamlMap)['ide_integration'] == true,
      agentComputerUse:
          root['agent'] is YamlMap &&
              (root['agent'] as YamlMap)['computer_use'] == true,
      agentErrorRecall: root['agent'] is YamlMap
          ? (root['agent'] as YamlMap)['error_recall'] != false
          : true,
      agentAutoTitle: root['agent'] is YamlMap
          ? (root['agent'] as YamlMap)['auto_title'] != false
          : true,
      agentTitleModelUpgrade: root['agent'] is YamlMap &&
          (root['agent'] as YamlMap)['title_model_upgrade'] == true,
      dailyCreditLimitUsd: root['agent'] is YamlMap
          ? _creditLimitUsd((root['agent'] as YamlMap)['daily_credit_limit_usd'])
          : 0.0,
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

  /// E2: parse blok `memory.idle_consolidation` (opt-in, default false).
  /// Nilai tidak valid -> ConfigIssue + fallback default (fail-closed).
  static IdleConsolidationCfg _parseIdleConsolidation(
    Object? raw,
    List<ConfigIssue> issues,
  ) {
    if (raw == null) return const IdleConsolidationCfg();
    if (raw is bool) {
      return IdleConsolidationCfg(enabled: raw);
    }
    if (raw is! YamlMap) {
      issues.add(const ConfigIssue(
        'memory.idle_consolidation',
        'harus boolean atau mapping',
      ));
      return const IdleConsolidationCfg();
    }
    int intOf(Object? v, int fallback, String key, int min) {
      if (v == null) return fallback;
      if (v is int && v >= min) return v;
      issues.add(ConfigIssue('memory.idle_consolidation.$key',
          'harus integer >= $min'));
      return fallback;
    }

    final rawEnabled = raw['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      issues.add(const ConfigIssue('memory.idle_consolidation.enabled',
          'harus boolean'));
    }
    final rawRetention = raw['max_retention'];
    double maxRetention = 0.5;
    if (rawRetention != null) {
      if (rawRetention is num) {
        maxRetention = rawRetention.toDouble().clamp(0.0, 1.0);
      } else {
        issues.add(const ConfigIssue(
          'memory.idle_consolidation.max_retention',
          'harus angka 0..1',
        ));
      }
    }
    return IdleConsolidationCfg(
      enabled: rawEnabled is bool ? rawEnabled : false,
      idleTurns: intOf(raw['idle_turns'], 25, 'idle_turns', 1),
      minCandidates: intOf(raw['min_candidates'], 5, 'min_candidates', 1),
      maxEntriesPerBatch:
          intOf(raw['max_entries_per_batch'], 20, 'max_entries_per_batch', 1),
      maxSummariesPerDay: intOf(
          raw['max_summaries_per_day'], 6, 'max_summaries_per_day', 0),
      maxRetention: maxRetention,
      maxOutputFacts:
          intOf(raw['max_output_facts'], 8, 'max_output_facts', 1),
    );
  }

  /// E1: parse blok `security.token_anomaly` (opt-in, default false).
  /// Nilai tidak valid -> ConfigIssue + fallback default (fail-closed).
  static TokenAnomalyConfig _parseTokenAnomaly(
    Object? raw,
    List<ConfigIssue> issues,
  ) {
    if (raw == null) return const TokenAnomalyConfig();
    if (raw is bool) {
      // Bentuk ringkas: security.token_anomaly: true
      return TokenAnomalyConfig(enabled: raw);
    }
    if (raw is! YamlMap) {
      issues.add(const ConfigIssue(
        'security.token_anomaly',
        'harus boolean atau mapping',
      ));
      return const TokenAnomalyConfig();
    }
    int intOf(Object? v, int fallback, String key, int min) {
      if (v == null) return fallback;
      if (v is int && v >= min) return v;
      issues.add(ConfigIssue('security.token_anomaly.$key',
          'harus integer >= $min'));
      return fallback;
    }

    double doubleOf(Object? v, double fallback, String key, double min) {
      if (v == null) return fallback;
      if (v is num && v >= min) return v.toDouble();
      issues.add(ConfigIssue('security.token_anomaly.$key',
          'harus angka >= $min'));
      return fallback;
    }

    final rawEnabled = raw['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      issues.add(const ConfigIssue('security.token_anomaly.enabled',
          'harus boolean'));
    }
    return TokenAnomalyConfig(
      enabled: rawEnabled is bool ? rawEnabled : false,
      minSamples: intOf(raw['min_samples'], 5, 'min_samples', 2),
      windowSize: intOf(raw['window_size'], 50, 'window_size', 5),
      zMultiplier:
          doubleOf(raw['z_multiplier'], 3.0, 'z_multiplier', 0.1),
      minSpikeRatio:
          doubleOf(raw['min_spike_ratio'], 3.0, 'min_spike_ratio', 1.0),
      cooldownMinutes:
          intOf(raw['cooldown_minutes'], 60, 'cooldown_minutes', 0),
      maxQuarantinesPerDay: intOf(
          raw['max_quarantines_per_day'], 3, 'max_quarantines_per_day', 0),
    );
  }

  /// ALG-05: parsing aman knob kompresi konteks. Nilai invalid kembali ke
  /// default fail-open (runtime tetap jalan), gaya sama dengan knob agent
  /// lain pada bagian `agent:` config.
  static double _compactorRatio(Object? v) {
    if (v is num && v > 0 && v <= 1) return v.toDouble();
    return 0.7;
  }

  static int _compactorKeepLastN(Object? v) {
    if (v is int && v >= 1) return v;
    return 6;
  }

  static int _compactorSoftTokens(Object? v) {
    if (v is int && v >= 256) return v;
    return 6000;
  }

  /// Parsing aman limit kredit harian USD; nilai invalid → 0 (off).
  static double _creditLimitUsd(Object? v) {
    if (v is num && v >= 0 && v.isFinite) return v.toDouble();
    return 0.0;
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

  /// S22 — parse blok `code.index` (default enabled=true, max_chunks=6000).
  /// Nilai tidak valid -> ConfigIssue + fallback default (fail-closed).
  static CodeIndexConfig _parseCodeIndex(YamlMap sec, List<ConfigIssue> issues) {
    final idx = sec['index'];
    if (idx != null && idx is! YamlMap) {
      issues.add(const ConfigIssue('code.index', 'harus berupa mapping'));
      return const CodeIndexConfig();
    }
    final m = idx is YamlMap ? idx : YamlMap();
    final enabledValue = m['enabled'];
    if (enabledValue != null && enabledValue is! bool) {
      issues.add(
          const ConfigIssue('code.index.enabled', 'harus berupa boolean'));
    }
    final maxChunksValue = m['max_chunks'];
    if (maxChunksValue != null &&
        (maxChunksValue is! int || maxChunksValue < 200)) {
      issues.add(const ConfigIssue(
          'code.index.max_chunks', 'harus integer >= 200'));
    }
    return CodeIndexConfig(
      enabled: enabledValue is bool ? enabledValue : true,
      maxChunks: maxChunksValue is int && maxChunksValue >= 200
          ? maxChunksValue.clamp(200, 50000)
          : 6000,
    );
  }

  static List<ProcessPluginConfig> _parseProcessPlugins(
    YamlMap sec,
    List<ConfigIssue> issues,
  ) {
    final raw = sec['process'];
    if (raw == null) return const [];
    if (raw is! YamlList) {
      issues.add(const ConfigIssue(
        'plugins.process',
        'harus berupa daftar mapping',
      ));
      return const [];
    }
    final knownPermissions = const {
      'tools.read',
      'tools.execute',
      'tools.register',
      'memory.read',
      'memory.write',
      'network.fetch',
      'sessions.read',
    };
    final namePattern = RegExp(r'^[a-z][a-z0-9-]{1,63}$');
    final out = <ProcessPluginConfig>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! YamlMap) {
        issues.add(ConfigIssue('plugins.process[$i]', 'harus berupa mapping'));
        continue;
      }
      final name = entry['name'];
      if (name is! String || !namePattern.hasMatch(name)) {
        issues.add(ConfigIssue(
          'plugins.process[$i].name',
          'harus cocok ^[a-z][a-z0-9-]{1,63}\$',
        ));
        continue;
      }
      final command = entry['command'];
      if (command is! String || command.trim().isEmpty) {
        issues.add(ConfigIssue(
          'plugins.process[$i].command',
          'harus berupa string yang tidak kosong',
        ));
        continue;
      }
      final args = <String>[
        if (entry['args'] is YamlList)
          for (final a in entry['args'] as YamlList) a.toString(),
      ];
      final permissions = <String>[];
      final rawPerms = entry['permissions'];
      var permsValid = true;
      if (rawPerms is YamlList) {
        for (final p in rawPerms) {
          final perm = p.toString();
          if (!knownPermissions.contains(perm)) {
            issues.add(ConfigIssue(
              'plugins.process[$i].permissions',
              'permission tidak dikenal: "$perm"',
            ));
            permsValid = false;
            continue;
          }
          permissions.add(perm);
        }
      } else if (rawPerms != null) {
        issues.add(ConfigIssue(
          'plugins.process[$i].permissions',
          'harus berupa daftar string',
        ));
        permsValid = false;
      }
      if (!permsValid) continue;
      out.add(ProcessPluginConfig(
        name: name,
        command: command.trim(),
        args: args,
        permissions: permissions,
      ));
    }
    return out;
  }

  /// Hermes-parity event hooks (P1): aturan lifecycle di `hooks:` (daftar
  /// mapping). Fail-closed: aturan invalid dilompati dengan issue eksplisit.
  static List<HookRuleConfig> _parseHooks(
    List<ConfigIssue> issues, {
    required YamlMap root,
  }) {
    final raw = root['hooks'];
    if (raw == null) return const [];
    if (raw is! YamlList) {
      issues.add(const ConfigIssue(fatal: false, 'hooks', 'harus berupa daftar mapping'));
      return const [];
    }
    final out = <HookRuleConfig>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! YamlMap) {
        issues.add(ConfigIssue(fatal: false, 'hooks[$i]', 'harus berupa mapping'));
        continue;
      }
      final event = entry['event'];
      if (event is! String || event.trim().isEmpty) {
        issues.add(ConfigIssue(fatal: false,
          'hooks[$i].event',
          'harus berupa string yang tidak kosong (nama event atau *)',
        ));
        continue;
      }
      final webhook = entry['webhook'];
      if (webhook != null &&
          (webhook is! String ||
              !(webhook.startsWith('http://') ||
                  webhook.startsWith('https://')))) {
        issues.add(ConfigIssue(fatal: false,
          'hooks[$i].webhook',
          'harus URL http:// atau https://',
        ));
        continue;
      }
      final script = entry['script'];
      if (script != null && script is! String) {
        issues.add(ConfigIssue(fatal: false, 'hooks[$i].script', 'harus berupa path string'));
        continue;
      }
      final scriptPath = script is String ? script.trim() : null;
      if (scriptPath != null &&
          (scriptPath.startsWith('/') ||
              scriptPath.startsWith('~') ||
              scriptPath.split('/').contains('..'))) {
        issues.add(ConfigIssue(fatal: false,
          'hooks[$i].script',
          'harus path relatif di dalam workspace (tanpa .. atau absolut)',
        ));
        continue;
      }
      if ((webhook == null || (webhook as String).trim().isEmpty) &&
          (scriptPath == null || scriptPath.isEmpty)) {
        issues.add(ConfigIssue(fatal: false,
          'hooks[$i]',
          'butuh salah satu webhook atau script',
        ));
        continue;
      }
      var timeoutSec = 30;
      final rawTimeout = entry['timeout_sec'];
      if (rawTimeout != null) {
        if (rawTimeout is! int || rawTimeout < 1 || rawTimeout > 120) {
          issues.add(ConfigIssue(fatal: false,
            'hooks[$i].timeout_sec',
            'harus berupa integer antara 1 dan 120',
          ));
          continue;
        }
        timeoutSec = rawTimeout;
      }
      final env = <String, String>{};
      final rawEnv = entry['env'];
      if (rawEnv is YamlMap) {
        for (final e in rawEnv.entries) {
          env['${e.key}'] = '${e.value}';
        }
      } else if (rawEnv != null) {
        issues.add(ConfigIssue(fatal: false,
          'hooks[$i].env',
          'harus berupa mapping string',
        ));
        continue;
      }
      out.add(HookRuleConfig(
        event: event.trim(),
        webhookUrl: (webhook as String?)?.trim(),
        script: scriptPath == null || scriptPath.isEmpty ? null : scriptPath,
        timeoutSec: timeoutSec,
        env: env,
      ));
    }
    return out;
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
a2ui:
  open_url_allow: []
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
