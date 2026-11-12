part of 'tiko_runtime.dart';

/// PRD §6 `tiko doctor`: environment diagnosis with actionable details.
extension TikoRuntimeDoctor on TikoRuntime {
  /// PRD §6 `tiko doctor`: environment diagnosis with actionable details.
  Future<List<DoctorCheck>> doctor({
    bool probe = false,
    int? apiPort,
    LockInfo? lock,
  }) async {
    final out = <DoctorCheck>[];

    // Configuration is one diagnostic category, not a guard around the host
    // checks. A broken config must never hide the information needed to fix it.
    if (issues.isEmpty) {
      out.add(const DoctorCheck('config', CheckStatus.ok, 'valid'));
    } else {
      for (final issue in issues) {
        out.add(DoctorCheck(
          'config ${issue.path}',
          issue.fatal ? CheckStatus.fail : CheckStatus.warn,
          issue.message,
        ));
      }
    }

    final resources = ResourceMonitor.capture(dataDir: dataDir);
    lastResources = resources;
    resourceProfile = resources.profile;
    out.add(DoctorCheck(
      'resource_profile',
      resources.profile == 'eco' ? CheckStatus.warn : CheckStatus.ok,
      resources.profile,
    ));
    out.add(DoctorCheck(
      'ram',
      resources.memAvailableMb == null
          ? CheckStatus.warn
          : resources.memAvailableMb! < ResourceMonitor.criticalRamMb
              ? CheckStatus.fail
              : resources.memAvailableMb! < ResourceMonitor.ecoRamMb
                  ? CheckStatus.warn
                  : CheckStatus.ok,
      resources.memAvailableMb == null
          ? 'unknown (host tidak menyediakan /proc/meminfo)'
          : '${resources.memAvailableMb} MB available / '
              '${resources.memTotalMb ?? "?"} MB total',
    ));
    out.add(DoctorCheck(
      'disk',
      resources.diskFreeMb == null
          ? CheckStatus.warn
          : resources.diskFreeMb! < ResourceMonitor.criticalDiskMb
              ? CheckStatus.fail
              : CheckStatus.ok,
      resources.diskFreeMb == null
          ? 'unknown (df tidak tersedia atau path tidak dapat dibaca)'
          : '${resources.diskFreeMb} MB free',
    ));
    out.add(DoctorCheck(
      'termux',
      CheckStatus.ok,
      resources.isTermux ? 'detected' : 'not termux',
    ));
    out.add(DoctorCheck(
      'sqlite_native',
      resources.hasSqliteNative ? CheckStatus.ok : CheckStatus.warn,
      resources.hasSqliteNative ? 'native library found' : 'missing — JSON memory fallback',
    ));
    out.add(DoctorCheck(
      'network',
      resources.networkLikely ? CheckStatus.ok : CheckStatus.warn,
      resources.networkLikely
          ? 'default route detected'
          : 'no default route — offline queue available',
    ));
    try {
      final count = await offlineQueue.length();
      out.add(DoctorCheck(
        'offline_queue',
        count == 0 ? CheckStatus.ok : CheckStatus.warn,
        count == 0 ? 'empty' : '$count pending item(s)',
      ));
    } catch (error) {
      out.add(DoctorCheck('offline_queue', CheckStatus.warn, 'unavailable: $error'));
    }

    out.add(
      Directory(workspace).existsSync()
          ? DoctorCheck('workspace', CheckStatus.ok, workspace)
          : DoctorCheck('workspace', CheckStatus.fail, 'tidak ada: $workspace'),
    );
    try {
      final probeFile = File(p.join(dataDir, '.doctor_write_test'));
      await probeFile.writeAsString('ok', flush: true);
      await probeFile.delete();
      out.add(DoctorCheck('data_dir', CheckStatus.ok, dataDir));
    } catch (error) {
      out.add(DoctorCheck('data_dir', CheckStatus.fail, 'tidak bisa menulis: $error'));
    }

    if (jobs.loadError != null) {
      out.add(DoctorCheck('scheduler_store', CheckStatus.fail, jobs.loadError!));
    } else {
      out.add(DoctorCheck('scheduler_store', CheckStatus.ok, '${jobs.all.length} job(s) loaded'));
    }
    final mcpStatus = mcpLoader.statuses;
    out.add(DoctorCheck(
      'mcp',
      mcpStatus.any((status) => status['status'] != 'ready')
          ? CheckStatus.warn
          : CheckStatus.ok,
      mcpStatus.isEmpty ? 'no MCP servers configured' : mcpStatus.toString(),
    ));

    out.add(DoctorCheck(
      'memory',
      memoryBackend.startsWith('sqlite') ? CheckStatus.ok : CheckStatus.warn,
      memoryBackend,
    ));
    out.add(DoctorCheck(
      'sandbox',
      sandboxKind == SandboxKind.none ? CheckStatus.warn : CheckStatus.ok,
      sandboxKind == SandboxKind.none
          ? 'tidak ada sandbox OS; shell, script, dan MCP dinonaktifkan'
          : sandboxKind.name,
    ));

    if (lock != null) {
      out.add(DoctorCheck(
        'daemon',
        CheckStatus.ok,
        'pid ${lock.pid} port ${lock.port ?? '-'} '
            'sejak ${lock.startedAt.toIso8601String()}',
      ));
    }
    if (apiPort != null) {
      final free = await _runtimePortFree(apiPort);
      out.add(DoctorCheck(
        'port $apiPort',
        free || lock?.port == apiPort ? CheckStatus.ok : CheckStatus.warn,
        free
            ? 'bebas'
            : lock?.port == apiPort
                ? 'dipakai instance Tiko sendiri'
                : 'dipakai proses lain; ubah api.port atau hentikan prosesnya',
      ));
    }

    if (config.providers.isEmpty) {
      out.add(const DoctorCheck(
        'provider',
        CheckStatus.fail,
        'tidak ada provider yang terkonfigurasi',
      ));
    } else {
      for (final provider in config.providers.values) {
        if (!provider.enabled) {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            provider.id == config.defaultProvider
                ? CheckStatus.fail
                : CheckStatus.warn,
            'disabled',
          ));
        } else if (!probe && provider.type != 'mock') {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            CheckStatus.warn,
            '${provider.type} belum diprobe; gunakan --probe',
          ));
        } else if (provider.type == 'mock') {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            CheckStatus.ok,
            'mock ready',
          ));
        } else {
          out.add(await _probeProvider(provider));
        }
      }
    }
    return out;
  }

  Future<DoctorCheck> _probeProvider(ProviderConfig c) async {
    final base = (c.baseUrl ?? 'http://127.0.0.1:11434').replaceAll(RegExp(r'/+$'), '');
    final url = c.type == 'ollama_native' ? '$base/api/tags' : '$base/models';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      final status = res.statusCode >= 200 && res.statusCode < 400
          ? CheckStatus.ok
          : res.statusCode == 401 || res.statusCode == 403 || res.statusCode == 404
              ? CheckStatus.warn
              : CheckStatus.fail;
      final detail = switch (res.statusCode) {
        401 || 403 => 'HTTP ${res.statusCode}: host aktif tetapi autentikasi ditolak ($url)',
        404 => 'HTTP 404: endpoint tidak ditemukan ($url)',
        _ => 'HTTP ${res.statusCode} dari $url',
      };
      return DoctorCheck('provider ${c.id}', status, detail);
    } catch (e) {
      return DoctorCheck('provider ${c.id}', CheckStatus.fail, 'tidak terjangkau: $url ($e)');
    } finally {
      client.close(force: true);
    }
  }
}

Future<bool> _runtimePortFree(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Injects the registry's tool specs and persistent history into each turn.
///
/// [toolFilter] implements subagent isolation at the prompt level: when
/// set, only allowlisted specs are advertised to the model, so the child
/// never sees tools its gate would deny. [personaPrompt] carries the
/// immutable workspace persona (SOUL.md) appended to the system prompt.
///
/// [reflectionEngine], [ragPipeline], and [layeredMemory] close the
/// learning/memory loop: relevant lessons, hybrid-RAG hits, and layered
/// (episodic/semantic/procedural) memories are retrieved per query and
/// appended to the system prompt. All three are best-effort — retrieval
/// failures degrade to the base context instead of failing the turn.
/// Maps an `AgentSpec.modelTier` value to a router tier override.
/// Returns null for unknown values so the host's text-based routing keeps
/// applying (fail-open to the existing behaviour, never to a broken route).
int? modelTierToRouterTier(String modelTier) => switch (modelTier.trim().toLowerCase()) {
      'light' || 'fast' || 'eco' => 1,
      'standard' || 'default' => 2,
      'heavy' || 'reasoning' || 'deep' || 'premium' => 3,
      _ => null,
    };

class RuntimeContext extends ContextBuilder {
  RuntimeContext(
    this.registry, {
    required super.memory,
    super.sessions,
    super.skillRegistry,
    super.expander,
    this.toolFilter,
    this.personaPrompt,
    this.reflectionEngine,
    this.ragPipeline,
    this.layeredMemory,
    this.toolSubsetThreshold = 24,
    this.toolSubsetK = 20,
  });
  final ToolRegistry registry;
  final Set<String>? toolFilter;
  final String? personaPrompt;
  final ReflectionEngine? reflectionEngine;
  final RagPipeline? ragPipeline;
  final LayeredMemory? layeredMemory;

  /// P2-2 completion: when the (filtered) registry carries more than
  /// [toolSubsetThreshold] tools, only the [toolSubsetK] most relevant specs
  /// are sent to the model, always including the `tool_search` meta-tool so
  /// the model can pull the remaining schemas on demand.
  final int toolSubsetThreshold;
  final int toolSubsetK;

  @override
  Future<AgentContext> build(
    Session session,
    InboundMessage m,
    RouteDecision route,
  ) async {
    final ctx = await super.build(session, m, route);
    final filter = toolFilter;
    final allSpecs = !route.needTools
        ? const <ToolSpec>[]
        : (filter == null
            ? registry.specs
            : registry.specs.where((s) => filter.contains(s.name)).toList());
    final (specs, subsetActive) = _applySubset(allSpecs, m.text);
    final persona = personaPrompt;
    var system = (persona == null || persona.isEmpty)
        ? ctx.systemPrompt
        : '${ctx.systemPrompt}\n\nPersona (SOUL.md, immutable):\n$persona';
    final extras = await _retrievedContext(m.text);
    if (subsetActive) {
      system = '$system\n\nDaftar tool di atas adalah subset paling relevan '
          'dengan permintaan ini. Untuk menemukan tool lain, panggil '
          '`tool_search` (skema lengkapnya tersedia di daftar).';
    }
    if (extras.isNotEmpty) {
      system = '$system\n\n$extras';
    }
    return AgentContext(
      messages: ctx.messages,
      tools: specs,
      session: ctx.session,
      systemPrompt: system,
    );
  }

  /// Returns the tool list to send to the model plus whether the dynamic
  /// subset is active. Below the threshold the full (filtered) list is sent;
  /// above it, a relevance-ranked subset is used and `tool_search` is always
  /// included. Execution is unaffected: the gate and registry still know the
  /// full surface, so tools outside the subset remain callable.
  (List<ToolSpec>, bool) _applySubset(List<ToolSpec> specs, String text) {
    if (specs.length <= toolSubsetThreshold) return (specs, false);
    final k = toolSubsetK.clamp(1, specs.length).toInt();
    var ranked = rankToolSpecs(specs, text, k: k);
    if (ranked.isEmpty) ranked = specs.take(k).toList();
    final search = specs.where((s) => s.name == 'tool_search').toList();
    final out = <ToolSpec>[];
    final seen = <String>{};
    for (final s in [...search, ...ranked]) {
      if (seen.add(s.name)) out.add(s);
    }
    return (out, true);
  }

  Future<String> _retrievedContext(String query) async {
    if (query.trim().isEmpty) return '';
    final blocks = <String>[];
    final lessons = reflectionEngine?.buildContextPrompt(query) ?? '';
    if (lessons.isNotEmpty) {
      blocks.add(lessons);
    }
    final rag = ragPipeline;
    if (rag != null) {
      try {
        final result = await rag.retrieve(query, k: 4);
        if (result.context.isNotEmpty) {
          blocks.add(
            'Konteks relevan dari indeks dokumen:\n${result.context}\n'
            'Sumber: ${result.citations.join(', ')}',
          );
        }
      } catch (_) {}
    }
    final layered = layeredMemory;
    if (layered != null) {
      try {
        final hits = layered.retrieve(query, k: 4);
        if (hits.isNotEmpty) {
          blocks.add(
            'Memori berlapis relevan:\n'
            '${hits.map((e) => '- ${e.text}').join('\n')}',
          );
        }
      } catch (_) {}
    }
    return blocks.join('\n\n');
  }
}


/// Tirith as an active deny/audit layer on the main chat path (P0-5).
/// A Tirith denial is final; allowances and its own approval requests fall
/// through to the inner gate so approval stays a single broker-backed path
/// (no double prompt).
class _TirithPreGate implements PermissionGate {
  _TirithPreGate(this._inner, this._tirith, this._channel);

  final PermissionGate _inner;
  final TirithSecurityLayer _tirith;
  final String _channel;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    try {
      final decision = await _tirith.checkToolCall(
        call: call,
        session: session,
        channel: _channel,
      );
      if (!decision.allowed && !decision.requiresApproval) {
        return PermissionResult(
          PermissionVerdict.denied,
          reason: 'tirith: ${decision.reason}',
        );
      }
    } catch (_) {
      // Tirith failures must not open a bypass; the inner gate still applies.
    }
    return _inner.check(call, session);
  }
}

/// Capability view handed to Tirith: calls without a capability id are
/// allowed here (the enforcing CapabilityAwareGate owns that policy), while
/// presented ids are validated without consuming the single-use token.
class _TirithCapabilityPeek implements CapabilityGate {
  _TirithCapabilityPeek(this._vault);

  final CapabilityVault _vault;

  @override
  Future<CapabilityCheckResult> check(ToolCall call, Session session) async {
    final raw = call.args['_capability_id'];
    if (raw is! String || raw.isEmpty) {
      return const CapabilityCheckResult(allowed: true);
    }
    if (!_vault.peek(raw, tool: call.name)) {
      return const CapabilityCheckResult(
        allowed: false,
        reason: 'capability invalid or expired',
      );
    }
    return const CapabilityCheckResult(allowed: true);
  }
}

/// Permission gate fail-closed untuk evaluator golden terisolasi: tool
/// hanya diizinkan bila dideklarasikan oleh tugas golden atau skill yang
/// sedang diuji. Selebihnya ditolak tanpa konfirmasi.
class _EvalToolGate implements PermissionGate {
  const _EvalToolGate(this.allowedTools);

  final Set<String> allowedTools;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (allowedTools.contains(call.name)) {
      return const PermissionResult(PermissionVerdict.allowed);
    }
    return const PermissionResult(
      PermissionVerdict.denied,
      reason: 'tool di luar allowlist tugas golden',
    );
  }
}

/// Permission gate wrapper that runs the plugin `beforeToolCall` hook chain
/// ahead of the real gate. First denial wins; arg modifications chain into
/// the inner gate and executor.
class _PluginHookGate implements PermissionGate {
  _PluginHookGate(this._inner, this._plugins);

  final PermissionGate _inner;
  final PluginRegistry _plugins;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    final verdict = await _plugins.dispatchBeforeToolCall(
      ToolHookInput(
        toolName: call.name,
        args: Map<String, dynamic>.of(call.args),
        sessionId: session.id,
      ),
    );
    if (!verdict.allowed) {
      return PermissionResult(
        PermissionVerdict.denied,
        reason: 'plugin veto: ${verdict.reason ?? 'tanpa alasan'}',
      );
    }
    final modified = verdict.modifiedArgs;
    if (modified != null) {
      call.args
        ..clear()
        ..addAll(modified);
    }
    return _inner.check(call, session);
  }
}

/// Bridges the built-in memory store with external [MemoryProvider]s:
/// reads merge local and external hits (external failures degrade
/// retrieval instead of crashing turns); writes stay local.
class _FanoutMemoryStore implements MemoryStore {
  _FanoutMemoryStore(this._inner, this._external);

  final MemoryStore _inner;
  final List<MemoryProvider> _external;

  MemoryStore get inner => _inner;

  @override
  Future<void> addMessage(Message m) => _inner.addMessage(m);

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async {
    final localHits = await _inner.search(query, k: k);
    final externalHits = <MemoryHit>[];
    for (final provider in _external) {
      try {
        for (final record in await provider.search(query, k: k)) {
          externalHits.add(MemoryHit(
            id: record.id,
            text: record.text,
            score: record.score,
            provenance: Provenance.memory,
            ownerKey: record.ownerKey,
            createdAt: record.createdAt,
          ));
        }
      } catch (_) {}
    }
    if (externalHits.isEmpty) return localHits;
    // Rank-based fusion: local and external scores live on incompatible
    // scales, so only ranks are comparable. Local hits enter first and win
    // id ties (dedup keeps the first occurrence).
    return _reciprocalRankFuse([
      localHits,
      externalHits,
    ], k: k);
  }

  List<MemoryHit> _reciprocalRankFuse(
    List<List<MemoryHit>> rankings, {
    required int k,
    int rrfK = 60,
  }) {
    final fused = <String, double>{};
    final firstSeen = <String, MemoryHit>{};
    for (final ranking in rankings) {
      for (var i = 0; i < ranking.length; i++) {
        final hit = ranking[i];
        fused[hit.id] = (fused[hit.id] ?? 0) + 1.0 / (rrfK + i + 1);
        firstSeen.putIfAbsent(hit.id, () => hit);
      }
    }
    final entries = fused.entries.toList()
      ..sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        if (byScore != 0) return byScore;
        return a.key.compareTo(b.key);
      });
    return [
      for (final e in entries.take(k)) firstSeen[e.key]!,
    ];
  }

  @override
  Future<void> upsertFact(Fact f) => _inner.upsertFact(f);

  @override
  Future<void> afterTurn(Session session) => _inner.afterTurn(session);
}

/// Batas byte operasi (maxBytes) dihitung dari payload aktual yang
/// ditulis, bukan dari panjang fingerprint, sehingga konten tulis/patch
/// tidak bisa melebihi ukuran yang disetujui walau fingerprintnya pendek.
bool _withinApprovedBytes(ToolCall call, int maxBytes) {
  for (final key in const ['content', 'new', 'body']) {
    final value = call.args[key];
    if (value is String && utf8.encode(value).length > maxBytes) {
      return false;
    }
  }
  return true;
}

void stdoutWrite(String m) {
  try {
    stdout.writeln(m);
  } catch (_) {}
}
