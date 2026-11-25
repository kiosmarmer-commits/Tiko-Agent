import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'attachment_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;

import 'agent_api_client.dart';
import 'app/app_routes.dart';
import 'daemon/desktop_daemon.dart';
import 'data/admin_event_feed.dart';
import 'data/agent_repository.dart';
import 'data/artifact_saver.dart';
import 'data/models.dart';
import 'shell/desktop_shell.dart';
import 'shell/mobile_shell.dart';
import 'ui/chat_controller.dart';
import 'ui/command_palette.dart';
import 'ui/global_shortcuts.dart';
import 'ui/logs_view.dart';
import 'ui/page_header.dart';
import 'ui/bot_manager_view.dart';
import 'ui/provider_manager_view.dart';
import 'ui/plugin_manager_view.dart';
import 'ui/channels_view.dart';
import 'ui/context_ref_suggest.dart';
import 'ui/hooks_view.dart';
import 'ui/automation_view.dart';
import 'ui/artifact_view.dart';
import 'ui/a2ui_page_surface_section.dart';
import 'ui/chat_artifact_panel.dart';
import 'ui/audit_page.dart';
import 'ui/memory_explorer_page.dart';
import 'ui/multi_pane_view.dart';
import 'ui/session_history_view.dart';
import 'ui/runs_page.dart';
import 'ui/surfaces_view.dart';
import 'ui/security_view.dart';
import 'ui/skills_view.dart';
import 'ui/settings_store.dart';
import 'ui/settings_view.dart';
import 'ui/theme.dart';
import 'ui/tasks_view.dart';
import 'ui/events_view.dart';
import 'ui/voice_service.dart';
import 'ui/graph_view.dart';
import 'ui/note_editor.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var token = const String.fromEnvironment('API_TOKEN', defaultValue: '');
  var base = const String.fromEnvironment('API_BASE');
  if (base.isEmpty) {
    // Jalur A fase 1: saat dilayani agentd (same-origin), pakai origin
    // halaman; di luar web, fallback ke daemon loopback default.
    base = kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8787';
  }
  // Self-contained desktop bootstrap (Hermes-parity): spawn/reuse the bundled
  // agentd daemon so the app works without a manually started daemon. Falls
  // back to the dart-define connection settings when bootstrap does not apply
  // (web/Android) or fails.
  try {
    final conn = await DesktopDaemon.ensure(
      binaryOverride: const String.fromEnvironment(
        'AGENTD_BIN',
        defaultValue: '',
      ),
    );
    if (conn != null) {
      base = conn.baseUrl;
      token = conn.token;
    }
  } catch (_) {
    // Bootstrap is best-effort; the manual connection settings still work.
  }
  final settings = await AppSettings.load();
  runApp(
    AgentApp(
      initialBaseUrl: base,
      initialToken: token,
      initialSettings: settings,
    ),
  );
}

class AgentApp extends StatefulWidget {
  const AgentApp({
    super.key,
    required this.initialBaseUrl,
    required this.initialToken,
    required this.initialSettings,
  });

  final String initialBaseUrl;
  final String initialToken;
  final AppSettings initialSettings;

  @override
  State<AgentApp> createState() => _AgentAppState();
}

class _AgentAppState extends State<AgentApp> {
  late String baseUrl;
  late String token;
  late AppSettings settings = widget.initialSettings;
  late AgentApiClient client;
  late AgentRepository repo;
  late ChatController chat;
  Timer? statusTimer;
  AdminEventFeed? eventFeed;
  bool _eventFeedStarted = false;
  AppRoute route = AppRoute.chat;
  String sessionKey = 'flutter:default';
  bool inspectorVisible = true;

  Map<String, dynamic>? status;
  Map<String, dynamic>? caps;
  List<Map<String, dynamic>> doctor = [];
  List<SessionSummary> sessions = [];
  List<ApprovalSummary> approvals = [];
  List<RuntimeEvent> events = [];
  List<TaskItem> tasks = [];
  List<LogFileInfo> logFiles = [];
  List<SkillItem> skills = [];
  List<BotProfileItem> bots = [];
  Map<String, String> botBindings = {};
  ProvidersSnapshot? providerSnapshot;
  PluginsToolsSnapshot? pluginSnapshot;
  ChannelsSnapshot? channelSnapshot;
  JobsSnapshot? jobsSnapshot;
  SecuritySnapshot? securitySnapshot;
  HooksSnapshot? hooksSnapshot;
  AuditQueryResult? auditResult;
  Map<String, String> auditFilters = const {};
  int auditOffset = 0;
  ArtifactsListing? artifactsListing;
  String artifactsDir = '';
  ArtifactContent? artifactContent;
  ArtifactDiff? artifactDiff;
  bool loadingArtifacts = false;
  String? artifactsError;
  bool artifactPreviewShowDiff = false;
  RunsSnapshot? runsSnapshot;
  List<Map<String, dynamic>>? teamRunsSnapshot;
  bool runsLoading = false;
  String? runsError;
  List<Map<String, dynamic>>? surfacesSnapshot;
  bool surfacesLoading = false;
  String? surfacesError;
  CuratedMemoryInfo? curatedMemoryInfo;
  LayersSnapshot? layersSnapshot;
  RagSourcesInfo? ragSources;
  bool memoryExplorerLoading = false;
  String? memoryExplorerError;
  bool auditLoading = false;
  String? auditError;
  List<MemoryFact> memories = [];
  final VoiceService voice = VoiceService();
  bool loadingAdmin = false;
  bool adminRefreshInFlight = false;
  int adminRefreshGeneration = 0;
  String? adminError;

  @override
  void initState() {
    super.initState();
    baseUrl = widget.initialBaseUrl;
    token = widget.initialToken;
    client = AgentApiClient(baseUrl: baseUrl, token: token);
    repo = HttpAgentRepository(client);
    chat = ChatController(repo);
    chat.checkOnline();
    statusTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      chat.checkOnline();
      if (route != AppRoute.chat && route != AppRoute.settings) {
        unawaited(refreshAdmin());
      }
    });
    unawaited(refreshAdmin());
  }

  /// Live push WS (GUI-P2-06): event runtime memicu refresh admin segera
  /// (debounce 1s); polling 15s tetap sebagai fallback bila WS mati. Feed
  /// dimulai setelah refresh admin pertama sukses (daemon terhubung).
  void _startEventFeed() {
    eventFeed?.dispose();
    eventFeed = AdminEventFeed(
      events: repo.runtimeEvents(),
      onRefresh: () async {
        if (route != AppRoute.chat && route != AppRoute.settings) {
          await refreshAdmin();
        }
      },
    )..start();
  }

  Future<void> refreshAdmin({bool force = false}) async {
    if (!mounted || (adminRefreshInFlight && !force)) return;
    final generation = ++adminRefreshGeneration;
    adminRefreshInFlight = true;
    setState(() {
      loadingAdmin = true;
      adminError = null;
    });
    try {
      // These independent GET requests run concurrently to reduce dashboard
      // latency. The in-flight guard prevents timer/manual refresh overlap.
      final results = await Future.wait<Object?>([
        repo.status(),
        repo.capabilities(),
        repo.doctor(),
        repo.sessions(),
        repo.approvals(),
        repo.events(),
        repo.tasks(),
        repo.logs(),
        repo.skills(),
        repo.bots(),
        repo.botBindings(),
        repo.providers(),
        repo.memories(),
        repo.pluginsTools(),
        repo.channels(),
        repo.jobs(),
        repo.security(),
        repo.hooks(),
      ]);
      if (!mounted || generation != adminRefreshGeneration) return;
      setState(() {
        status = results[0] as Map<String, dynamic>;
        caps = results[1] as Map<String, dynamic>;
        doctor = results[2] as List<Map<String, dynamic>>;
        sessions = results[3] as List<SessionSummary>;
        approvals = results[4] as List<ApprovalSummary>;
        events = results[5] as List<RuntimeEvent>;
        tasks = results[6] as List<TaskItem>;
        logFiles = results[7] as List<LogFileInfo>;
        skills = results[8] as List<SkillItem>;
        bots = results[9] as List<BotProfileItem>;
        botBindings = results[10] as Map<String, String>;
        providerSnapshot = results[11] as ProvidersSnapshot;
        memories = results[12] as List<MemoryFact>;
        pluginSnapshot = results[13] as PluginsToolsSnapshot;
        channelSnapshot = results[14] as ChannelsSnapshot;
        jobsSnapshot = results[15] as JobsSnapshot;
        securitySnapshot = results[16] as SecuritySnapshot;
        hooksSnapshot = results[17] as HooksSnapshot;
      });
      if (!_eventFeedStarted) {
        _eventFeedStarted = true;
        _startEventFeed();
      }
    } catch (e) {
      if (mounted && generation == adminRefreshGeneration) {
        setState(() => adminError = e.toString());
      }
    } finally {
      if (generation == adminRefreshGeneration) {
        adminRefreshInFlight = false;
        if (mounted) setState(() => loadingAdmin = false);
      }
    }
  }

  Future<void> _queryAudit(
    Map<String, String> filters, {
    int offset = 0,
  }) async {
    setState(() {
      auditFilters = filters;
      auditOffset = offset;
      auditLoading = true;
      auditError = null;
    });
    try {
      final result = await repo.audit(
        tool: filters['tool'],
        session: filters['session'],
        risk: filters['risk'],
        verdict: filters['verdict'],
        taint: filters['taint'] == 'true' ? true : null,
        offset: offset,
      );
      if (!mounted) return;
      setState(() => auditResult = result);
    } catch (e) {
      if (mounted) setState(() => auditError = e.toString());
    } finally {
      if (mounted) setState(() => auditLoading = false);
    }
  }

  Future<void> _loadArtifacts({String dir = ''}) async {
    setState(() {
      artifactsError = null;
      loadingArtifacts = true;
    });
    try {
      final listing = await repo.artifacts(dir: dir);
      if (!mounted) return;
      setState(() {
        artifactsListing = listing;
        artifactsDir = dir;
      });
    } catch (e) {
      if (mounted) setState(() => artifactsError = e.toString());
    } finally {
      if (mounted) setState(() => loadingArtifacts = false);
    }
  }

  /// Hermes S7: sesi chat aktif (untuk binding panel artifacts).
  SessionSummary? get _currentSession {
    for (final session in sessions) {
      if (session.id == sessionKey) return session;
    }
    return null;
  }

  /// Hermes S7: muat byte gambar (base64 inline) untuk thumbnail/preview.
  Future<List<int>?> _loadArtifactImage(String path) async {
    try {
      final content = await repo.artifactRead(path);
      if (!content.isImage || content.contentBase64.isEmpty) return null;
      return base64Decode(content.contentBase64);
    } catch (_) {
      return null;
    }
  }

  /// Hermes S7: unduh artifact — web via anchor, desktop ke Downloads/temp.
  Future<void> _downloadArtifact(String path) async {
    try {
      final file = await repo.artifactDownload(path);
      saveArtifactDownloaded(file.filename, Uint8List.fromList(file.bytes));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File terunduh: ${file.filename}'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mengunduh file: $error')),
      );
    }
  }

  /// Hermes S7: publish/share artifact — salinan read-only di
  /// `.tiko/published/` milik runtime, pesan share bisa disalin.
  Future<void> _publishArtifact(String path) async {
    try {
      final published = await repo.artifactPublish(
        path,
        sessionId: sessionKey,
      );
      final shareText =
          '${published['share_text'] ?? published['published_path'] ?? path}';
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Artifact dipublikasikan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Salinan read-only tersimpan di workspace daemon:'),
              const SizedBox(height: 8),
              SelectableText(
                '${published['published_path'] ?? path}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              key: const Key('btn-artifact-share-copy'),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: shareText)),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Salin pesan share'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mempublikasikan: $error')),
      );
    }
  }

  Future<void> _openArtifact(String path, {bool showDiff = false}) async {
    if (path.isEmpty) {
      setState(() {
        artifactContent = null;
        artifactDiff = null;
      });
      return;
    }
    setState(() {
      artifactsError = null;
      loadingArtifacts = true;
      artifactPreviewShowDiff = showDiff;
    });
    try {
      final content = await repo.artifactRead(path);
      if (!mounted) return;
      setState(() => artifactContent = content);
      if (content.bakExists) {
        final diff = await repo.artifactDiff(path);
        if (!mounted) return;
        setState(() => artifactDiff = diff);
      } else {
        setState(() => artifactDiff = null);
      }
    } catch (e) {
      if (mounted) setState(() => artifactsError = e.toString());
    } finally {
      if (mounted) setState(() => loadingArtifacts = false);
    }
  }

  /// C3 Chat-UX: tombol "Diff" pada kartu file chat — buka file di panel
  /// dengan tampilan diff langsung (bila `.bak` ada), kalau tidak preview.
  Future<void> _openArtifactDiff(String path) async {
    if (path.isEmpty) return;
    await _openArtifact(path, showDiff: true);
  }

  /// Memory Explorer (GUI-P1-12): kurasi + lapisan + RAG dimuat paralel.
  Future<void> _loadMemoryExplorer() async {
    setState(() {
      memoryExplorerLoading = true;
      memoryExplorerError = null;
    });
    try {
      final results = await Future.wait<Object?>([
        repo.curatedMemory(),
        repo.layered(),
        repo.ragSources(),
      ]);
      if (!mounted) return;
      setState(() {
        curatedMemoryInfo = results[0] as CuratedMemoryInfo;
        layersSnapshot = results[1] as LayersSnapshot;
        ragSources = results[2] as RagSourcesInfo;
      });
    } catch (e) {
      if (mounted) setState(() => memoryExplorerError = e.toString());
    } finally {
      if (mounted) setState(() => memoryExplorerLoading = false);
    }
  }

  Future<String?> _saveCurated(String file, String text) async {
    try {
      final info = await repo.setCuratedMemory(file: file, text: text);
      if (!mounted) return null;
      setState(() => curatedMemoryInfo = info);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> _addLayerEntry(Map<String, dynamic> body) async {
    try {
      await repo.addLayerEntry(body);
      await _loadMemoryExplorer();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> _deleteLayerEntry(String id) async {
    try {
      final ok = await repo.deleteLayerEntry(id);
      if (!ok) return 'Entri lapisan tidak ditemukan atau gagal dihapus.';
      await _loadMemoryExplorer();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _loadRuns() async {
    setState(() {
      runsLoading = true;
      runsError = null;
    });
    try {
      final snapshot = await repo.runInspector();
      if (!mounted) return;
      setState(() => runsSnapshot = snapshot);
    } catch (e) {
      if (mounted) setState(() => runsError = e.toString());
    } finally {
      if (mounted) setState(() => runsLoading = false);
    }
  }

  /// E5 — DAG run team: gagal muat tidak ikut menandai halaman Runs gagal;
  /// bagian run tim hanya sembunyi (best-effort).
  Future<void> _loadTeamRuns() async {
    try {
      final reports = await repo.teamRuns();
      if (!mounted) return;
      setState(() => teamRunsSnapshot = reports);
    } catch (_) {}
  }

  Future<void> _loadSurfaces() async {
    setState(() {
      surfacesLoading = true;
      surfacesError = null;
    });
    try {
      final list = await repo.surfaces();
      if (!mounted) return;
      setState(() => surfacesSnapshot = list);
    } catch (e) {
      if (mounted) setState(() => surfacesError = e.toString());
    } finally {
      if (mounted) setState(() => surfacesLoading = false);
    }
  }

  /// Hermes S8: rute halaman yang memuat seksi surface A2UI dinamis.
  static const Set<AppRoute> _a2uiSurfaceRoutes = {
    AppRoute.surfaces,
    AppRoute.tasks,
    AppRoute.bots,
    AppRoute.automations,
    AppRoute.runs,
    AppRoute.skills,
    AppRoute.security,
  };

  /// Hermes S8: seksi surface dinamis untuk halaman statik `target`.
  /// Konvensi surfaceId `page.<target>.` (agent_core, system prompt addon).
  Widget _a2uiSection(String target) => A2uiPageSurfaceSection(
        target: target,
        surfaces: surfacesSnapshot,
        online: chat.online,
        onRefresh: _loadSurfaces,
        onOpenManager: () => _selectRoute(AppRoute.surfaces),
        onLoadSurface: repo.surface,
        onAction: (surfaceId, actionName, payload, sessionKey) => unawaited(
          _submitPageSurfaceAction(surfaceId, actionName, payload, sessionKey),
        ),
        onDelete: (surfaceId) async {
          final deleted = await repo.deleteSurface(surfaceId);
          await _loadSurfaces();
          return deleted;
        },
      );

  /// Hermes S8: aksi surface dari halaman GUI tetap melalui pipeline
  /// anti-replay host (`POST /v1/ui/actions`), sama seperti di chat.
  Future<void> _submitPageSurfaceAction(
    String surfaceId,
    String actionName,
    Map<String, dynamic> payload,
    String sessionKey,
  ) async {
    try {
      final reply = await repo.submitUiAction(
        sessionKey,
        actionName,
        payload,
        surfaceId: surfaceId,
      );
      if (!mounted) return;
      final preview = reply.isEmpty
          ? ''
          : ' — ${reply.length > 120 ? '${reply.substring(0, 120)}…' : reply}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Aksi "$actionName" terkirim$preview')),
      );
      await _loadSurfaces();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mengirim aksi surface: $e')),
      );
    }
  }

  Future<void> updateConnection({required String base, required String tok}) async {
    setState(() {
      baseUrl = base;
      token = tok;
      client.baseUrl = base;
      client.token = tok;
    });
    // Kredensial berubah — buang feed lama; refresh penuh akan memulai ulang
    // feed WS dengan kredensial baru bila daemon terhubung.
    eventFeed?.dispose();
    _eventFeedStarted = false;
    await chat.checkOnline();
    await refreshAdmin(force: true);
  }

  Future<void> _applySettings(AppSettings next) async {
    final multiPaneTurnedOn = next.multiPane && !settings.multiPane;
    setState(() => settings = next);
    await next.save();
    // GUI-P2-03: saat multi-pane baru diaktifkan di route chat, muat data
    // inspector agar pane tidak kosong.
    if (multiPaneTurnedOn && route == AppRoute.chat && runsSnapshot == null) {
      unawaited(_loadRuns());
    }
  }

  void _toggleInspector() {
    setState(() => inspectorVisible = !inspectorVisible);
    if (inspectorVisible && runsSnapshot == null) {
      unawaited(_loadRuns());
    }
  }

  /// Buka halaman session history via shortcut Ctrl/Cmd+H.
  void _openSessionHistory() {
    setState(() {
      route = AppRoute.sessions;
      adminError = null;
    });
  }

  /// Pindah ke session sebelumnya/berikutnya pada daftar session
  /// (Ctrl/Cmd+Alt+ArrowUp/Down), wrap-around seperti tab switcher.
  void _cycleSession(int delta) {
    if (sessions.length < 2) return;
    final idx = sessions.indexWhere((session) => session.id == sessionKey);
    final base = idx < 0
        ? (delta < 0 ? sessions.length - 1 : 0)
        : (idx + delta + sessions.length) % sessions.length;
    _openSessionFromPane(sessions[base].id);
  }

  /// Esc global: tutup pratinjau artifact, lalu inspector. Fokus di dalam
  /// dialog berada di luar subtree GlobalShortcuts sehingga Esc dialog
  /// tetap bekerja normal.
  void _globalEscape() {
    if (artifactContent != null) {
      _openArtifact('');
      return;
    }
    if (inspectorVisible) _toggleInspector();
  }

  void _openSessionFromPane(String id) {
    setState(() {
      sessionKey = id;
      adminError = null;
      route = AppRoute.chat;
    });
    unawaited(chat.openSession(id));
  }

  /// Sesi chat baru (GUI-P3): sesi dibuat implisit saat pesan pertama
  /// dikirim dengan id baru, meniru pola "New chat" pada agen AI umum.
  void _newChatSession() {
    final id = 'flutter:chat-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    setState(() {
      sessionKey = id;
      adminError = null;
      route = AppRoute.chat;
    });
    chat.clearChat();
    unawaited(refreshAdmin(force: true));
  }

  /// Pemilih model/provider per-sesi (GUI-P3) di header chat, parity
  /// Hermes `/model`: provider harus terkonfigurasi; bila endpoint
  /// `/v1/providers/<id>/models` mengembalikan daftar model (discovery
  /// live, cache 15 menit), user memilih model spesifik; bila discovery
  /// tidak tersedia (fail-open) lanjut dengan model default provider.
  Future<void> _selectChatProvider(String providerId) async {
    try {
      List<String> models = const [];
      try {
        models = await repo.providerModels(providerId);
      } catch (_) {
        models = const [];
      }
      String? model;
      if (models.isNotEmpty && mounted) {
        model = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Model tersedia — $providerId',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final m in models)
                  ListTile(
                    key: Key('opt-chat-model-$m'),
                    dense: true,
                    title: Text(m, style: const TextStyle(fontSize: 13)),
                    onTap: () => Navigator.pop(sheetContext, m),
                  ),
              ],
            ),
          ),
        );
        if (model == null) return;
      }
      if (!mounted) return;
      final ok = await repo.setSessionProvider(
        sessionKey,
        providerId,
        model: model,
      );
      if (!ok && mounted) {
        setState(
          () => adminError = 'Provider "$providerId" tidak ditemukan.',
        );
        return;
      }
      if (mounted) setState(() => adminError = null);
      await refreshAdmin(force: true);
    } catch (error) {
      if (mounted) {
        setState(
          () => adminError = 'Gagal mengganti provider: $error',
        );
      }
    }
  }

  Future<bool> _sendSkillFeedback(String slug, bool positive) async {
    final ok = await repo.skillFeedback(slug, positive);
    if (ok) {
      if (mounted) setState(() => adminError = null);
      unawaited(refreshAdmin());
    }
    return ok;
  }

  Future<void> _mutateBots(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() => adminError = null);
    unawaited(refreshAdmin(force: true));
  }

  /// Hooks CRUD (SETTINGS-HOOKS): mutasi diikuti refresh admin agar aturan
  /// live + statistik di UI sinkron dengan daemon.
  Future<void> _mutateHooks(Future<void> Function() action) async {
    await action();
    unawaited(refreshAdmin(force: true));
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    eventFeed?.dispose();
    chat.dispose();
    unawaited(voice.stopSpeaking());
    voice.dispose();
    client.close();
    super.dispose();
  }

  /// Command palette global (GUI-P2-02): navigasi ke semua route + aksi
  /// refresh — di-trigger Ctrl+K / Ctrl+P via [PaletteShortcut].
  void _openCommandPalette() {
    final actions = [
      for (final entry in visibleRoutes(advanced: settings.advancedMode))
        PaletteAction(
          entry.label,
          () => _selectRoute(entry.route),
          hint: 'Buka halaman ${entry.label}',
        ),
      PaletteAction(
        'Muat ulang data admin',
        () => refreshAdmin(force: true),
        hint: 'Semua GET dashboard dipanggil ulang',
      ),
    ];
    if (!mounted) return;
    showCommandPalette(context, actions);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final routes = visibleRoutes(advanced: settings.advancedMode);
    return MaterialApp(
      title: 'Tiko',
      debugShowCheckedModeBanner: false,
      theme: SimpulTheme.theme(Brightness.light, settings.accent),
      darkTheme: SimpulTheme.theme(Brightness.dark, settings.accent),
      themeMode: settings.themeMode,
      home: GlobalShortcuts(
        onPalette: _openCommandPalette,
        onNewChat: _newChatSession,
        onOpenHistory: _openSessionHistory,
        onPreviousSession: () => _cycleSession(-1),
        onNextSession: () => _cycleSession(1),
        onEscape: _globalEscape,
        child: Scaffold(
          body: wide
              ? DesktopShell(
                  selected: route,
                  onSelect: _selectRoute,
                  pendingApprovals: _pendingApprovals,
                  entries: routes,
                  child: AnimatedBuilder(
                    animation: chat,
                    builder: (context, _) => _body(wide: true),
                  ),
                )
              : MobileShell(
                  selected:
                      routes.any((entry) => entry.route == route) &&
                          route.primaryOnMobile
                      ? route
                      : null,
                  onSelect: _selectMobileRoute,
                  pendingApprovals: _pendingApprovals,
                  entries: routes,
                  child: AnimatedBuilder(
                    animation: chat,
                    builder: (context, _) => _body(wide: false),
                  ),
                ),
        ),
      ),
    );
  }

  int get _pendingApprovals =>
      approvals.where((approval) => approval.isPending).length;

  void _selectRoute(AppRoute next) {
    setState(() => route = next);
    if (next == AppRoute.artifacts && artifactsListing == null) {
      unawaited(_loadArtifacts());
    }
    if (next == AppRoute.runs && runsSnapshot == null) {
      unawaited(_loadRuns());
    }
    if (next == AppRoute.runs && teamRunsSnapshot == null) {
      unawaited(_loadTeamRuns());
    }
    if (_a2uiSurfaceRoutes.contains(next) && surfacesSnapshot == null) {
      unawaited(_loadSurfaces());
    }
    // GUI-P2-03: inspector pane di chat butuh snapshot runs saat pertama
    // kali ditampilkan pada mode multi-pane.
    if (next == AppRoute.chat &&
        settings.multiPane &&
        inspectorVisible &&
        runsSnapshot == null) {
      unawaited(_loadRuns());
    }
    if (next == AppRoute.memory &&
        curatedMemoryInfo == null &&
        layersSnapshot == null) {
      unawaited(_loadMemoryExplorer());
    }
    if (next != AppRoute.chat) unawaited(refreshAdmin());
  }

  void _selectMobileRoute(AppRoute? next) {
    if (next == null) {
      setState(() => route = AppRoute.memory);
      unawaited(refreshAdmin());
      return;
    }
    _selectRoute(next);
  }

  Widget _body({required bool wide}) {
    if (!wide && !route.primaryOnMobile) {
      return _MorePage(
        repo: repo,
        baseUrl: baseUrl,
        token: token,
        surfaceSectionFor: _a2uiSection,
        memories: memories,
        tasks: tasks,
        logFiles: logFiles,
        events: events,
        skills: skills,
        bots: bots,
        bindings: botBindings,
        providers: providerSnapshot,
        pluginSnapshot: pluginSnapshot,
        channelSnapshot: channelSnapshot,
        jobsSnapshot: jobsSnapshot,
        securitySnapshot: securitySnapshot,
        auditResult: auditResult,
        onQueryAudit: _queryAudit,
        artifactsListing: artifactsListing,
        artifactsDir: artifactsDir,
        artifactContent: artifactContent,
        artifactDiff: artifactDiff,
        loadingArtifacts: loadingArtifacts,
        artifactsError: artifactsError,
        sessionOptions: sessions,
        onOpenArtifactsDir: (dir) => unawaited(_loadArtifacts(dir: dir)),
        onOpenArtifactFile: (path) => unawaited(_openArtifact(path)),
        onCloseArtifactPreview: () => _openArtifact(''),
        runsSnapshot: runsSnapshot,
        runsLoading: runsLoading,
        runsError: runsError,
        onLoadRuns: _loadRuns,
        daemonStatus: status,
        availableSessions: [for (final s in sessions) s.id],
        online: chat.online,
        onRefresh: refreshAdmin,
        onConnect: updateConnection,
        settings: settings,
        onSettingsChanged: _applySettings,
      );
    }
    switch (route) {
      case AppRoute.chat:
        final chatPage = _ChatPage(
          chat: chat,
          sessionKey: sessionKey,
          voice: voice,
          voiceReply: settings.voiceReply,
          multiPane: settings.multiPane,
          inspectorVisible: inspectorVisible,
          onToggleInspector: _toggleInspector,
          providerSnapshot: providerSnapshot,
          onNewChat: _newChatSession,
          onSelectProvider: _selectChatProvider,
          artifactsListing: artifactsListing,
          artifactsDir: artifactsDir,
          artifactsLoading: loadingArtifacts,
          artifactsError: artifactsError,
          previewContent: artifactContent,
          previewDiff: artifactDiff,
          previewLoading: loadingArtifacts,
          previewShowDiff: artifactPreviewShowDiff,
          onLoadArtifacts: () => unawaited(_loadArtifacts()),
          onOpenArtifactDir: (dir) => unawaited(_loadArtifacts(dir: dir)),
          onOpenArtifactFile: (path) => unawaited(_openArtifact(path)),
          onOpenArtifactDiff: (path) => unawaited(_openArtifactDiff(path)),
          onCloseArtifactFile: () => _openArtifact(''),
          onListWorkspace: (dir) async => [
                for (final f in (await repo.artifacts(dir: dir)).files) f.path,
              ],
          sessionStartedAt: _currentSession?.createdAt ?? _currentSession?.updatedAt ?? '',
          sessionLabel: _currentSession?.displayTitle,
          onLoadArtifactImage: _loadArtifactImage,
          onDownloadArtifact: (path) => unawaited(_downloadArtifact(path)),
          onPublishArtifact: (path) => unawaited(_publishArtifact(path)),
        );
        // GUI-P2-03: multi-pane di layar lebar — sesi kiri, inspector kanan.
        if (!settings.multiPane) return chatPage;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SessionsPane(
              sessions: sessions,
              current: sessionKey,
              online: chat.online,
              loading: loadingAdmin,
              error: adminError,
              onRefresh: () => refreshAdmin(force: true),
              onSelect: _openSessionFromPane,
            ),
            Expanded(child: chatPage),
            if (inspectorVisible)
              InspectorPane(
                runsSnapshot: runsSnapshot,
                runsLoading: runsLoading,
                runsError: runsError,
                artifactsListing: artifactsListing,
                artifactsError: artifactsError,
                online: chat.online,
                onLoadRuns: _loadRuns,
                onLoadArtifacts: () => unawaited(_loadArtifacts()),
                onOpenArtifactFile: (path) => unawaited(_openArtifact(path)),
                onClose: _toggleInspector,
              ),
          ],
        );
      case AppRoute.dashboard:
        return _DashboardPage(
          status: status,
          caps: caps,
          doctor: doctor,
          events: events,
          approvals: approvals,
          loading: loadingAdmin,
          error: adminError,
          online: chat.online,
          onRefresh: refreshAdmin,
        );
      case AppRoute.approvals:
        return _ApprovalsPage(
          approvals: approvals,
          online: chat.online,
          loading: loadingAdmin,
          onRefresh: refreshAdmin,
          onDecide: (id, ok) async {
            try {
              final decided = await repo.decideApproval(id, ok);
              await refreshAdmin();
              if (!decided && mounted) {
                setState(
                  () => adminError =
                      'Approval $id tidak lagi pending atau sudah kedaluwarsa.',
                );
              }
            } catch (error) {
              if (mounted) {
                setState(
                  () =>
                      adminError = 'Gagal mengirim keputusan approval: $error',
                );
              }
            }
          },
        );
      case AppRoute.sessions:
        return _SessionsPage(
          sessions: sessions,
          current: sessionKey,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onNewChat: _newChatSession,
          onSelect: (id) {
            setState(() {
              sessionKey = id;
              adminError = null;
              route = AppRoute.chat;
            });
            unawaited(chat.openSession(id));
          },
          onRename: (id, title) async {
            try {
              final ok = await repo.renameSession(id, title);
              if (!ok) {
                throw StateError('Sesi tidak ditemukan atau gagal diubah.');
              }
              await refreshAdmin(force: true);
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal mengubah nama sesi: $error');
              }
            }
          },
          onDelete: (id) async {
            try {
              final deleted = await repo.deleteSession(id);
              if (!deleted) {
                throw StateError('Sesi tidak ditemukan atau gagal dihapus.');
              }
              if (id == sessionKey) {
                setState(() => sessionKey = 'flutter:default');
                chat.clearChat();
              }
              await refreshAdmin(force: true);
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal menghapus sesi: $error');
              }
            }
          },
          onTogglePin: (id, pinned) async {
            try {
              await repo.updateSession(id, pinned: pinned);
              await refreshAdmin(force: true);
            } catch (error) {
              if (mounted) {
                setState(
                  () => adminError =
                      'Gagal mengubah sematan sesi: $error',
                );
              }
            }
          },
          onToggleArchive: (id, archived) async {
            try {
              await repo.updateSession(id, archived: archived);
              await refreshAdmin(force: true);
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal mengubah arsip sesi: $error');
              }
            }
          },
          onDuplicate: (id) async {
            try {
              final copy = await repo.duplicateSession(id);
              await refreshAdmin(force: true);
              if (copy != null && copy.id.isNotEmpty) {
                setState(() {
                  sessionKey = copy.id;
                  adminError = null;
                  route = AppRoute.chat;
                });
                unawaited(chat.openSession(copy.id));
              }
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal menduplikat sesi: $error');
              }
            }
          },
          onExport: (id, format) async {
            try {
              final content = await repo.exportSession(id, format: format);
              if (!mounted) return;
              await showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text('Ekspor percakapan ($format)'),
                  content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        content.isEmpty ? '(kosong)' : content,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton.icon(
                      key: const Key('btn-session-export-copy'),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: content),
                      ),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Salin ke clipboard'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Tutup'),
                    ),
                  ],
                ),
              );
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal mengekspor sesi: $error');
              }
            }
          },
          onBulkDelete: (ids) async {
            try {
              final deleted = await repo.deleteSessions(ids);
              if (ids.any((id) => id == sessionKey)) {
                setState(() => sessionKey = 'flutter:default');
                chat.clearChat();
              }
              if (mounted) {
                setState(
                  () => adminError =
                      deleted == ids.length
                          ? null
                          : 'Sebagian sesi gagal dihapus '
                              '($deleted/${ids.length}).',
                );
              }
              await refreshAdmin(force: true);
            } catch (error) {
              if (mounted) {
                setState(
                  () => adminError = 'Gagal menghapus sesi terpilih: $error',
                );
              }
            }
          },
        );
      case AppRoute.tasks:
        return TaskBoardPage(
          tasks: tasks,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          surfaceSection: _a2uiSection('tasks'),
        );
      case AppRoute.events:
        return EventsPage(
          events: events,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
        );
      case AppRoute.logs:
        return LogsPage(
          logs: logFiles,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onLoadContent: repo.logContent,
        );
      case AppRoute.skills:
        return SkillsPage(
          skills: skills,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onFeedback: _sendSkillFeedback,
          onEvaluate: repo.evaluateSkill,
          onApprove: repo.approveSkill,
          onRollback: repo.rollbackSkill,
          onLoadHistory: repo.skillHistory,
          surfaceSection: _a2uiSection('skills'),
        );
      case AppRoute.bots:
        return BotsPage(
          bots: bots,
          bindings: botBindings,
          availableSessions: [for (final s in sessions) s.id],
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onCreate: (body) => _mutateBots(() => repo.createBot(body)),
          onUpdate: (id, body) => _mutateBots(() => repo.updateBot(id, body)),
          onDelete: (id) async {
            final ok = await repo.deleteBot(id);
            if (ok) unawaited(refreshAdmin(force: true));
            return ok;
          },
          onBind: (botId, sessionId) async {
            final ok = await repo.bindBot(botId, sessionId);
            if (ok) unawaited(refreshAdmin(force: true));
            return ok;
          },
          onUnbind: (botId, sessionId) async {
            final ok = await repo.unbindBot(botId, sessionId);
            if (ok) unawaited(refreshAdmin(force: true));
            return ok;
          },
          surfaceSection: _a2uiSection('bots'),
        );
      case AppRoute.providers:
        return ProviderManagerPage(
          snapshot: providerSnapshot,
          availableSessions: [for (final s in sessions) s.id],
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onSetSessionProvider: (sessionId, providerArg) async {
            final ok = await repo.setSessionProvider(sessionId, providerArg);
            if (ok) unawaited(refreshAdmin(force: true));
            return ok;
          },
        );
      case AppRoute.plugins:
        return PluginManagerPage(
          snapshot: pluginSnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onConsent: (plugin, action) async {
            final message = await repo.setPluginConsent(plugin, action);
            unawaited(refreshAdmin(force: true));
            return message;
          },
        );
      case AppRoute.channels:
        return ChannelsPage(
          snapshot: channelSnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
        );
      case AppRoute.automations:
        return AutomationPage(
          snapshot: jobsSnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onCreate: (body) async {
            await repo.createJob(body);
            unawaited(refreshAdmin(force: true));
          },
          onUpdate: (id, body) async {
            await repo.updateJob(id, body);
            unawaited(refreshAdmin(force: true));
          },
          onDelete: (id) async {
            final ok = await repo.deleteJob(id);
            if (ok) unawaited(refreshAdmin(force: true));
            return ok;
          },
          onRunNow: (id) async {
            final job = await repo.runJobNow(id);
            if (job != null) unawaited(refreshAdmin(force: true));
            return job;
          },
          surfaceSection: _a2uiSection('automation'),
        );
      case AppRoute.security:
        return SecurityPage(
          snapshot: securitySnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          surfaceSection: _a2uiSection('security'),
        );
      case AppRoute.audit:
        return AuditPage(
          result: auditResult,
          online: chat.online,
          loading: auditLoading,
          error: auditError,
          onQuery: _queryAudit,
          onRefresh: () => _queryAudit(auditFilters, offset: auditOffset),
          onNext: () => _queryAudit(
            auditFilters,
            offset: auditOffset + (auditResult?.entries.length ?? 50),
          ),
        );
      case AppRoute.artifacts:
        return ArtifactsPage(
          listing: artifactsListing,
          online: chat.online,
          loading: loadingArtifacts,
          error: artifactsError,
          dir: artifactsDir,
          sessionOptions: sessions,
          onOpenDir: (dir) => unawaited(_loadArtifacts(dir: dir)),
          onOpenFile: (path) => unawaited(_openArtifact(path)),
          onClosePreview: () => _openArtifact(''),
          onRefresh: () => _loadArtifacts(dir: artifactsDir),
        );
      case AppRoute.runs:
        return RunsPage(
          snapshot: runsSnapshot,
          online: chat.online,
          loading: runsLoading,
          error: runsError,
          onRefresh: _loadRuns,
          teamRuns: teamRunsSnapshot,
          surfaceSection: _a2uiSection('runs'),
        );
      case AppRoute.surfaces:
        return SurfacesPage(
          surfaces: surfacesSnapshot,
          online: chat.online,
          loading: surfacesLoading,
          error: surfacesError,
          onRefresh: _loadSurfaces,
          onShowDetail: repo.surface,
          onDelete: (surfaceId) async {
            final deleted = await repo.deleteSurface(surfaceId);
            await _loadSurfaces();
            return deleted;
          },
        );
      case AppRoute.memory:
        return MemoryExplorerPage(
          memories: memories,
          curated: curatedMemoryInfo,
          layers: layersSnapshot,
          rag: ragSources,
          online: chat.online,
          loading: loadingAdmin || memoryExplorerLoading,
          error: memoryExplorerError ?? adminError,
          onRefresh: () async {
            await refreshAdmin();
            await _loadMemoryExplorer();
          },
          onDelete: (id) async {
            try {
              final deleted = await repo.deleteMemory(id);
              if (!deleted) {
                throw StateError('Memori tidak ditemukan atau gagal dihapus.');
              }
              await refreshAdmin();
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal menghapus memori: $error');
              }
            }
          },
          onSaveCurated: _saveCurated,
          onAddLayer: _addLayerEntry,
          onDeleteLayer: _deleteLayerEntry,
        );
      case AppRoute.hooks:
        return HooksPage(
          snapshot: hooksSnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onAdd: (body) => _mutateHooks(() => repo.addHook(body)),
          onUpdate: (index, body) =>
              _mutateHooks(() => repo.updateHook(index, body)),
          onDelete: (index) => _mutateHooks(() async {
            await repo.deleteHook(index);
          }),
          onTest: (index) => repo.testHook(index),
        );
      case AppRoute.settings:
        return SettingsView(
          settings: settings,
          baseUrl: baseUrl,
          token: token,
          online: chat.online,
          onConnect: updateConnection,
          onSettingsChanged: _applySettings,
          daemonCard: _DaemonStatusCard(),
          daemonStatus: status,
          onOpenHooks: () => _selectRoute(AppRoute.hooks),
        );
    }
  }
}

// ——— Chat ———
class _ChatPage extends StatefulWidget {
  const _ChatPage({
    required this.chat,
    required this.sessionKey,
    required this.voice,
    this.voiceReply = false,
    this.multiPane = false,
    this.inspectorVisible = false,
    this.onToggleInspector,
    this.providerSnapshot,
    this.onNewChat,
    this.onSelectProvider,
    this.artifactsListing,
    this.artifactsDir = '',
    this.artifactsLoading = false,
    this.artifactsError,
    this.previewContent,
    this.previewDiff,
    this.previewLoading = false,
    this.previewShowDiff = false,
    this.onLoadArtifacts,
    this.onOpenArtifactDir,
    this.onOpenArtifactFile,
    this.onOpenArtifactDiff,
    this.onCloseArtifactFile,
    this.onListWorkspace,
    this.sessionStartedAt = '',
    this.sessionLabel,
    this.onLoadArtifactImage,
    this.onDownloadArtifact,
    this.onPublishArtifact,
  });
  final ChatController chat;
  final String sessionKey;
  final VoiceService voice;
  final bool voiceReply;
  final bool multiPane;
  final bool inspectorVisible;
  final VoidCallback? onToggleInspector;
  final ProvidersSnapshot? providerSnapshot;
  final VoidCallback? onNewChat;
  final Future<void> Function(String providerId)? onSelectProvider;

  /// C3 Chat-UX: panel file artifacts terintegrasi di chat (read-only).
  final ArtifactsListing? artifactsListing;
  final String artifactsDir;
  final bool artifactsLoading;
  final String? artifactsError;
  final ArtifactContent? previewContent;
  final ArtifactDiff? previewDiff;
  final bool previewLoading;
  final bool previewShowDiff;
  final VoidCallback? onLoadArtifacts;
  final ValueChanged<String>? onOpenArtifactDir;
  final ValueChanged<String>? onOpenArtifactFile;
  final ValueChanged<String>? onOpenArtifactDiff;
  final VoidCallback? onCloseArtifactFile;

  /// SETTINGS-CONTEXT-REFS: daftar path file workspace untuk autocomplete
  /// chip `@file:`/`@dir:` di composer (null = autocomplete nonaktif).
  final Future<List<String>> Function(String dir)? onListWorkspace;

  /// Hermes S7: binding panel artifacts ke sesi — waktu mulai sesi aktif
  /// untuk filter "Sesi ini", loader gambar inline, unduh, dan publish.
  final String sessionStartedAt;
  final String? sessionLabel;
  final Future<List<int>?> Function(String path)? onLoadArtifactImage;
  final void Function(String path)? onDownloadArtifact;
  final void Function(String path)? onPublishArtifact;

  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> {
  late final ScrollController _scrollController;
  bool _filesOpen = false;

  /// C3: buka/tutup panel file; panel pertama kali dibuka memicu muat
  /// daftar artifacts bila belum ada.
  void _toggleFilesPane() {
    final opening = !_filesOpen;
    setState(() => _filesOpen = opening);
    if (opening) widget.onLoadArtifacts?.call();
  }
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.chat.addListener(_followLatestMessage);
  }

  void _followLatestMessage() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final shouldFollow =
        !position.hasContentDimensions ||
        position.maxScrollExtent - position.pixels <= 120;
    if (!shouldFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// Voice UI: setelah turn selesai, bacakan balasan assistant terakhir
  /// bila preferensi "balasan suara" aktif.
  Future<void> _onSend(String text, List<ChatAttachmentPayload> attachments) async {
    await widget.chat.send(
      text,
      sessionKey: widget.sessionKey,
      attachments: attachments,
    );
    if (!mounted || !widget.voiceReply) return;
    final reply = VoiceService.speakableReply(widget.chat.messages);
    if (reply == null) return;
    await widget.voice.speak(reply);
  }

  /// C1 UX: tombol "Salin" per pesan assistant — salin teks mentah
  /// (termasuk markdown) ke clipboard, feedback lewat SnackBar.
  Future<void> _copyMessage(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pesan tersalin'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _editAndResend(String text) async {
    final controller = TextEditingController(text: text);
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit prompt'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Tulis ulang prompt…',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Kirim ulang'),
          ),
        ],
      ),
    );
    controller.dispose();
    final value = edited?.trim() ?? '';
    if (value.isNotEmpty && value != text.trim()) {
      await _onSend(value, const []);
    }
  }

  /// Voice UI: tombol "dengarkan" per pesan assistant; bila sedang berbicara,
  /// tap menghentikan TTS.
  void _speakOrStop(String text) {
    final voice = widget.voice;
    if (voice.speaking) {
      unawaited(voice.stopSpeaking());
      return;
    }
    unawaited(
      voice.speak(text).catchError((Object error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('TTS tidak tersedia: $error')));
      }),
    );
  }

  /// C3: chip `@file:` — logika parsingnya di `collectFileRefs`
  /// (chat_artifact_panel.dart); karakter berisiko dilewati fail-closed.
  List<String> _collectFileRefs(String text) => collectFileRefs(text);

  /// C3: kartu file yang disentuh tool turn aktif (`message['files']` berupa
  /// daftar {path, changed}); wiring sumbernya menyusul di C4 (WS frames).
  List<Widget> _fileCards(Map<String, String> message, int i) {
    List<ChatFileCardData> parsed;
    try {
      parsed = parseMessageFileCards(message['files']);
    } catch (_) {
      return const [];
    }
    if (parsed.isEmpty) return const [];
    return [
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(maxWidth: 760),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var j = 0; j < parsed.length; j++)
              _FileCard(
                key: Key('card-file-$i-$j'),
                path: parsed[j].path,
                changed: parsed[j].changed,
                onOpen: widget.onOpenArtifactFile == null
                    ? null
                    : () => widget.onOpenArtifactFile!(parsed[j].path),
                onOpenDiff: widget.onOpenArtifactFile == null
                    ? null
                    : () => _openArtifactDiffView(parsed[j].path),
              ),
          ],
        ),
      ),
    ];
  }

  void _openArtifactDiffView(String path) {
    // Diff langsung dari kartu chat: panel dibuka dengan tampilan diff
    // (turunan _openArtifact via callback root bila tersedia).
    widget.onOpenArtifactDiff?.call(path);
  }

  String _chatProviderLabel() {
    final snapshot = widget.providerSnapshot;
    if (snapshot == null) return 'default';
    final id = snapshot.sessionOverrides[widget.sessionKey] ??
        snapshot.defaultId ??
        'default';
    final model = snapshot.sessionModelChoices[widget.sessionKey];
    return model == null ? id : '$id · $model';
  }

  /// Chip pemilih model/provider gaya chat AI modern (GUI-P3): pill kecil
  /// di header chat membuka menu provider yang tersedia untuk sesi ini.
  Widget _chatModelChip(BuildContext context) {
    final snapshot = widget.providerSnapshot;
    final current = _chatProviderLabel();
    return PopupMenuButton<String>(
      key: const Key('btn-chat-provider-picker'),
      tooltip: 'Pilih model AI untuk sesi ini',
      onSelected: (id) {
        if (id != current) unawaited(widget.onSelectProvider!(id));
      },
      itemBuilder: (context) {
        final defaultId = snapshot?.defaultId;
        return [
          if (defaultId != null && defaultId.isNotEmpty)
            PopupMenuItem<String>(
              value: defaultId,
              child: _providerMenuRow(
                defaultId,
                selected: current == defaultId,
              ),
            ),
        for (final p in snapshot?.providers ?? const [])
          if (p.id != snapshot?.defaultId)
            PopupMenuItem<String>(
              value: p.id,
              child: _providerMenuRow(p.id, selected: current == p.id),
            ),
        ];
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.simpulSurfaceHover,
          borderRadius: BorderRadius.circular(SimpulTheme.radiusPill),
          border: Border.all(color: context.simpulBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune, size: 14, color: context.simpulMuted),
            const SizedBox(width: 6),
            Text(
              current,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: context.simpulMuted),
          ],
        ),
      ),
    );
  }

  Widget _providerMenuRow(String id, {required bool selected}) {
    return Row(
      children: [
        Icon(selected ? Icons.check : Icons.circle_outlined, size: 14),
        const SizedBox(width: 8),
        Text(id, style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  @override
  void dispose() {
    widget.chat.removeListener(_followLatestMessage);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.chat,
      builder: (context, _) => _layoutWithPanel(context, widget.chat),
    );
  }

  /// C3 Chat-UX: chat dapat memakai panel file di kanan (lebar ≥1100px) atau
  /// overlay penuh (layar sempit). Panel read-only dari data nama yang sama.
  Widget _layoutWithPanel(BuildContext context, ChatController chat) {
    final chatColumn = Column(
          children: [
            PageHeader(
              title: 'Chat',
              subtitle: widget.sessionKey,
              online: chat.online,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onNewChat != null)
                    IconButton(
                      key: const Key('btn-chat-new-session'),
                      tooltip: 'Chat baru',
                      icon: const Icon(Icons.add_comment_outlined),
                      onPressed: widget.onNewChat,
                    ),
                  if (widget.onOpenArtifactFile != null)
                    IconButton(
                      key: const Key('btn-chat-files'),
                      tooltip: _filesOpen
                          ? 'Tutup panel file workspace'
                          : 'Buka panel file workspace',
                      icon: Icon(
                        _filesOpen
                            ? Icons.close
                            : Icons.folder_open_outlined,
                      ),
                      onPressed: _toggleFilesPane,
                    ),
                  if (widget.onSelectProvider != null &&
                      (widget.providerSnapshot?.providers.isNotEmpty ?? false))
                    _chatModelChip(context),
                  if (widget.multiPane)
                    IconButton(
                      tooltip: widget.inspectorVisible
                          ? 'Tutup inspector'
                          : 'Buka inspector (GUI-P2-03)',
                      icon: Icon(
                        widget.inspectorVisible
                            ? Icons.chevron_right
                            : Icons.view_column_outlined,
                      ),
                      onPressed: widget.onToggleInspector,
                    ),
                ],
              ),
            ),
            Expanded(
              child: chat.messages.isEmpty
                  ? LayoutBuilder(
                      builder: (context, emptyConstraints) =>
                          SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: emptyConstraints.maxHeight,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: context.simpulAccent,
                            borderRadius:
                                BorderRadius.circular(SimpulTheme.radiusLarge),
                          ),
                          child: const Icon(
                            Icons.smart_toy_outlined,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Mulai percakapan dengan Tiko',
                          style: TextStyle(color: context.simpulMuted),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tool berisiko akan meminta approval Anda',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.simpulMuted,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Coba mulai dari sini',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: context.simpulMuted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _starterPrompt(
                              context,
                              'Ringkas workspace saya',
                            ),
                            _starterPrompt(
                              context,
                              'Bantu saya memahami project ini',
                            ),
                            _starterPrompt(
                              context,
                              'Tampilkan status agent',
                            ),
                          ],
                        ),
                      ],
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: chat.messages.length,
                      itemBuilder: (context, i) {
                        final message = chat.messages[i];
                        final user = message['role'] == 'user';
                        final speakable = user
                            ? null
                            : VoiceService.speakableReply([message]);
                        final messageText =
                            (message['text'] ?? '').toString();
                        final fileRefs =
                            widget.onOpenArtifactFile == null
                                ? const <String>[]
                                : _collectFileRefs(messageText);
                        return Align(
                          alignment: user
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: user
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(14),
                                constraints: const BoxConstraints(
                                  maxWidth: 760,
                                ),
                                decoration: BoxDecoration(
                                  color: user
                                      ? context.simpulUserBubble
                                      : context.simpulBotBubble,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(
                                      SimpulTheme.radiusLarge,
                                    ),
                                    topRight: const Radius.circular(
                                      SimpulTheme.radiusLarge,
                                    ),
                                    bottomLeft:
                                        Radius.circular(user ? SimpulTheme.radiusLarge : 4),
                                    bottomRight:
                                        Radius.circular(user ? 4 : SimpulTheme.radiusLarge),
                                  ),
                                ),
                                child: message['role'] == 'assistant'
                                    ? TikoSurfaceOrMessageView(
                                        text: (message['text'] ?? '')
                                            .toString(),
                                        onAction: (actionId, values) {
                                          unawaited(
                                            chat.sendUiAction(
                                              actionId,
                                              values,
                                              sessionKey: widget.sessionKey,
                                            ),
                                          );
                                        },
                                        onSurfaceAction:
                                            (surfaceId, actionName, payload) {
                                          unawaited(
                                            chat.sendUiAction(
                                              actionName,
                                              payload,
                                              sessionKey: widget.sessionKey,
                                              surfaceId: surfaceId,
                                            ),
                                          );
                                        },
                                      )
                                    : SelectableText(
                                        (message['text'] ?? '').toString(),
                                        style: SimpulTheme.body,
                                      ),
                              ),
                              ..._fileCards(message, i),
                              for (var j = 0; j < fileRefs.length; j++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: ActionChip(
                                    key: Key('chip-file-ref-$i-$j'),
                                    visualDensity: VisualDensity.compact,
                                    label: Text(
                                      '@file:${fileRefs[j]}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    onPressed: () =>
                                        widget.onOpenArtifactFile!(fileRefs[j]),
                                  ),
                                ),
                              if (speakable != null && speakable.isNotEmpty)
                                TextButton.icon(
                                  key: Key('btn-speak-msg-$i'),
                                  onPressed: () => _speakOrStop(speakable),
                                  icon: Icon(
                                    widget.voice.speaking
                                        ? Icons.stop
                                        : Icons.volume_up_outlined,
                                    size: 16,
                                  ),
                                  label: Text(
                                    'Dengarkan',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.simpulMuted,
                                    ),
                                  ),
                                ),
                              if (user && messageText.trim().isNotEmpty)
                                TextButton.icon(
                                  key: Key('btn-edit-msg-$i'),
                                  onPressed: () => _editAndResend(messageText),
                                  icon: const Icon(Icons.edit_outlined, size: 16),
                                  label: Text(
                                    'Edit',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.simpulMuted,
                                    ),
                                  ),
                                ),
                              if (!user && messageText.startsWith('Gagal:'))
                                TextButton.icon(
                                  key: Key('btn-retry-msg-$i'),
                                  onPressed: chat.retryText == null
                                      ? null
                                      : () => unawaited(
                                            chat.retryLast(
                                              sessionKey: widget.sessionKey,
                                            ),
                                          ),
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: Text(
                                    'Coba lagi',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.simpulMuted,
                                    ),
                                  ),
                                ),
                              if (!user && messageText.isNotEmpty)
                                TextButton.icon(
                                  key: Key('btn-copy-msg-$i'),
                                  onPressed: () => _copyMessage(messageText),
                                  icon: const Icon(
                                    Icons.copy_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    'Salin',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.simpulMuted,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (chat.pendingConfirm != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.simpulPanel,
                  border: Border(top: BorderSide(color: context.simpulBorder)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 20,
                      color: context.simpulWarn,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Konfirmasi: ${chat.pendingConfirm!.prompt}',
                        style: TextStyle(color: context.simpulWarn),
                      ),
                    ),
                    TextButton(
                      onPressed: () => chat.respondConfirm(true),
                      child: const Text('Izinkan'),
                    ),
                    TextButton(
                      onPressed: () => chat.respondConfirm(false),
                      child: const Text('Tolak'),
                    ),
                  ],
                ),
              ),
            AnimatedBuilder(
              animation: chat,
              builder: (context, _) => _TurnProgressStrip(chat: chat),
            ),
            _Composer(
              onSend: _onSend,
              voice: widget.voice,
              onListWorkspace: widget.onListWorkspace,
            ),
          ],
        );
    if (!_filesOpen || widget.onOpenArtifactFile == null) return chatColumn;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;
        final panel = ChatArtifactPanel(
          online: chat.online,
          listing: widget.artifactsListing,
          dir: widget.artifactsDir,
          listingLoading: widget.artifactsLoading,
          listingError: widget.artifactsError,
          preview: widget.previewContent,
          diff: widget.previewDiff,
          previewLoading: widget.previewLoading,
          previewShowDiff: widget.previewShowDiff,
          onOpenDir: widget.onOpenArtifactDir,
          onOpenFile: widget.onOpenArtifactFile,
          onClosePreview: widget.onCloseArtifactFile,
          onRefresh: widget.onLoadArtifacts,
          sessionStartedAt: widget.sessionStartedAt,
          sessionLabel: widget.sessionLabel,
          sessionRefs: [
            for (final message in chat.messages)
              ...collectFileRefs(message['content'] ?? ''),
          ],
          onLoadImage: widget.onLoadArtifactImage,
          onDownload: widget.onDownloadArtifact,
          onPublish: widget.onPublishArtifact,
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chatColumn),
              SizedBox(width: 380, child: Material(child: panel)),
            ],
          );
        }
        return Stack(
          children: [
            Positioned.fill(child: chatColumn),
            Positioned.fill(child: Material(child: panel)),
          ],
        );
      },
    );
  }

  Widget _starterPrompt(BuildContext context, String prompt) {
    return ActionChip(
      avatar: Icon(
        Icons.auto_awesome_outlined,
        size: 15,
        color: context.simpulAccent,
      ),
      label: Text(prompt),
      onPressed: () => unawaited(_onSend(prompt, const [])),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.onSend, this.voice, this.onListWorkspace});
  final Future<void> Function(String, List<ChatAttachmentPayload>) onSend;
  final VoiceService? voice;
  final Future<List<String>> Function(String dir)? onListWorkspace;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final c = TextEditingController();
  bool busy = false;
  VoiceService? _ownedVoice;
  final attachments = <ChatAttachmentPayload>[];

  /// SETTINGS-CONTEXT-REFS: chip visual + autocomplete `@file:`/`@dir:`/
  /// `@url:`/`@git:` saat mengetik. Entri workspace di-fetch debounced via
  /// [widget.onListWorkspace] dan dicache per direktori.
  List<ContextRefToken> _contextRefs = const [];
  ContextRefSuggestion _suggestion = const ContextRefSuggestion();
  Timer? _entriesDebounce;
  List<String> _workspaceEntries = const [];
  String _entriesDir = '';

  VoiceService get voice => widget.voice ?? _ownedVoice!;

  @override
  void initState() {
    super.initState();
    if (widget.voice == null) _ownedVoice = VoiceService();
    c.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final caret = c.selection.baseOffset;
    final text = c.text;
    setState(() {
      _contextRefs = parseContextRefs(text);
      _suggestion = caret >= 0 && caret <= text.length
          ? suggestAt(text, caret)
          : const ContextRefSuggestion();
    });
    _maybeLoadEntries(_suggestion);
  }

  void _maybeLoadEntries(ContextRefSuggestion suggestion) {
    final callback = widget.onListWorkspace;
    if (callback == null) return;
    final kind = suggestion.activeKind;
    if (kind != 'file' && kind != 'dir') return;
    final prefix = suggestion.targetPrefix;
    final slash = prefix.lastIndexOf('/');
    final dir = slash < 0 ? '' : prefix.substring(0, slash);
    if (dir == _entriesDir || _entriesDebounce?.isActive == true) return;
    _entriesDebounce?.cancel();
    _entriesDebounce = Timer(const Duration(milliseconds: 180), () {
      unawaited(_loadEntries(dir, callback));
    });
  }

  Future<void> _loadEntries(
    String dir,
    Future<List<String>> Function(String) fetch,
  ) async {
    try {
      final entries = await fetch(dir);
      if (!mounted) return;
      setState(() {
        _entriesDir = dir;
        _workspaceEntries = entries;
      });
    } catch (_) {
      // Listing workspace gagal: autocomplete tetap jalan tanpa entri.
    }
  }

  int get _caret {
    final offset = c.selection.baseOffset;
    return offset < 0 ? c.text.length : offset;
  }

  /// Pasangan (path penuh, label) saran workspace sesuai kind aktif.
  /// Path relatif terhadap [_entriesDir].
  List<(String, String)> get _entrySuggestions {
    final suggestion = _suggestion;
    final kind = suggestion.activeKind;
    if (kind != 'file' && kind != 'dir') return const [];
    final dir = _entriesDir;
    final prefix = suggestion.targetPrefix;
    var rel = prefix;
    if (dir.isNotEmpty) {
      if (prefix.startsWith('$dir/')) {
        rel = prefix.substring(dir.length + 1);
      } else {
        return const [];
      }
    }
    final lower = rel.toLowerCase();
    final files = [
      for (final e in _workspaceEntries)
        if (e.toLowerCase().startsWith(lower)) e,
    ];
    if (kind == 'file') return [for (final f in files) (f, f)];
    return [for (final d in parentDirsOf(files)) (d, d)];
  }

  void _removeContextRef(ContextRefToken token) {
    final text = removeRange(c.text, token.start, token.end);
    final collapsed = text.replaceAll(RegExp(r'\s{2,}'), ' ');
    final caret = token.start.clamp(0, collapsed.length);
    c.value = c.value.copyWith(
      text: collapsed,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  /// Sisipkan token builtin (`@file:`, `@git:diff`, ...) — mengganti partial
  /// `@fi` bila caret masih menempel, atau menyisipkan posisi caret.
  void _insertBuiltin(String token) {
    final caret = _caret;
    if (caret > 0) {
      final at = c.text.lastIndexOf('@', caret - 1);
      if (at >= 0) {
        final partial = c.text.substring(at, caret);
        if (partial.length >= 2 &&
            !partial.contains(' ') &&
            !partial.contains(':')) {
          c.value = c.value.copyWith(
            text: c.text.replaceRange(at, caret, token),
            selection: TextSelection.collapsed(offset: at + token.length),
          );
          return;
        }
      }
    }
    c.value = c.value.copyWith(
      text: c.text.replaceRange(caret, caret, token),
      selection: TextSelection.collapsed(offset: caret + token.length),
    );
  }

  /// Terima saran path workspace: ganti target token aktif dengan path
  /// penuh, kind (`@file:`/`@dir:`) dipertahankan.
  void _acceptEntry(String path) {
    final active = activeTokenAt(c.text, _caret);
    if (active == null) return;
    final targetStart = active.start + active.kind.length + 2;
    c.value = c.value.copyWith(
      text: c.text.replaceRange(targetStart, active.end, path),
      selection: TextSelection.collapsed(offset: targetStart + path.length),
    );
  }

  IconData _refIcon(String kind) => switch (kind) {
        'file' => Icons.insert_drive_file_outlined,
        'dir' => Icons.folder_outlined,
        'url' => Icons.link,
        _ => Icons.merge,
      };

  Widget? _buildSuggestionRow(BuildContext context) {
    if (busy) return null;
    final builtins = _suggestion.builtins;
    final entries = _entrySuggestions;
    if (builtins.isEmpty && entries.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final b in builtins)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  key: Key('chip-suggest-builtin-$b'),
                  label: Text(b, style: const TextStyle(fontSize: 12)),
                  tooltip: 'Sisipkan $b',
                  onPressed: () => _insertBuiltin(b),
                ),
              ),
            for (final (path, label) in entries.take(12))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  key: Key('chip-suggest-entry-$label'),
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  tooltip: path,
                  onPressed: () => _acceptEntry(path),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// C2 Chat-UX: pilih lampiran (Web: input file native browser; platform
  /// lain gagal jujur dan mengarahkan ke referensi `@file:`).
  Future<void> _pickAttachments() async {
    try {
      final picked = await pickChatAttachments();
      if (!mounted || picked.isEmpty) return;
      setState(
        () => attachments.addAll([
          for (final p in picked)
            ChatAttachmentPayload(
              name: p.name,
              mime: p.mime,
              dataBase64: p.dataBase64,
            ),
        ]),
      );
    } on AttachmentPickerException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } on UnsupportedError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${e.message}')),
        );
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() => attachments.removeAt(index));
  }

  /// Voice UI: toggle dikte; hasil final STT mengganti isi text field agar
  /// pengguna masih bisa menyunting sebelum mengirim.
  Future<void> _toggleMic() async {
    try {
      await voice.toggleListening(
        onFinal: (text) {
          if (!mounted || text.trim().isEmpty) return;
          c.text = text.trim();
        },
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Suara tidak tersedia: $error')));
      }
    }
  }

  @override
  void dispose() {
    _entriesDebounce?.cancel();
    _ownedVoice
      ?..stopListening()
      ..stopSpeaking()
      ..dispose();
    c.dispose();
    super.dispose();
  }

  Future<void> _submit(String value) async {
    final text = value.trim();
    if (text.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      await widget.onSend(text, List.of(attachments));
      if (!mounted) return;
      c.clear();
      setState(attachments.clear);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal mengirim pesan: $error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(top: BorderSide(color: context.simpulBorder)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: AnimatedBuilder(
            animation: voice,
            builder: (context, _) {
              return Container(
                decoration: BoxDecoration(
                  color: context.simpulSurfaceHover,
                  borderRadius: BorderRadius.circular(SimpulTheme.radiusPill),
                  border: Border.all(color: context.simpulBorder),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (var i = 0; i < attachments.length; i++)
                              InputChip(
                                key: Key('chip-attachment-$i'),
                                label: Text(
                                  attachments[i].name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                tooltip:
                                    '${attachments[i].name} • ${attachments[i].mime}',
                                onDeleted: () => _removeAttachment(i),
                              ),
                          ],
                        ),
                      ),
                    if (_contextRefs.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (var i = 0; i < _contextRefs.length; i++)
                              InputChip(
                                key: Key('chip-context-ref-$i'),
                                avatar: Icon(
                                  _refIcon(_contextRefs[i].kind),
                                  size: 16,
                                ),
                                label: Text(
                                  _contextRefs[i].fullLabel,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                tooltip:
                                    'Context reference ${_contextRefs[i].kind}'
                                    ': ${_contextRefs[i].target}',
                                onDeleted: () => _removeContextRef(_contextRefs[i]),
                              ),
                          ],
                        ),
                      ),
                    if ((_suggestion.builtins.isNotEmpty ||
                            _entrySuggestions.isNotEmpty) &&
                        !busy)
                      _buildSuggestionRow(context)!,
                    Row(
                      children: [
                        IconButton(
                          key: const Key('btn-attach'),
                          tooltip:
                              'Lampirkan file (maks 4, 2 MiB; teks dan gambar)',
                          onPressed: busy ? null : _pickAttachments,
                          icon: const Icon(Icons.attach_file),
                        ),
                        IconButton(
                          key: const Key('btn-voice-mic'),
                          tooltip: voice.listening
                              ? 'Hentikan dikte'
                              : 'Dikte suara (GUI Voice UI)',
                          onPressed: _toggleMic,
                          icon: Icon(
                            voice.listening ? Icons.mic : Icons.mic_none,
                            color:
                                voice.listening ? context.simpulDanger : null,
                          ),
                        ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              SingleActivator(LogicalKeyboardKey.enter,
                                      control: true):
                                  () => _submit(c.text),
                              SingleActivator(LogicalKeyboardKey.enter,
                                      meta: true):
                                  () => _submit(c.text),
                            },
                            child: TextField(
                            controller: c,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: voice.listening
                              ? 'Mendengarkan… (bicara sekarang)'
                              : 'Pesan ke Tiko…',
                          helperText:
                              voice.listening && voice.partial.isNotEmpty
                                  ? voice.partial
                                  : null,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (value) => _submit(value),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton.filled(
                          tooltip: 'Kirim pesan',
                          onPressed: busy ? null : () => _submit(c.text),
                          icon: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ——— Dashboard ———
class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.status,
    required this.caps,
    required this.doctor,
    required this.events,
    required this.approvals,
    required this.loading,
    required this.error,
    required this.online,
    required this.onRefresh,
  });

  final Map<String, dynamic>? status;
  final Map<String, dynamic>? caps;
  final List<Map<String, dynamic>> doctor;
  final List<RuntimeEvent> events;
  final List<ApprovalSummary> approvals;
  final bool loading;
  final String? error;
  final bool online;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final pending = approvals.where((a) => a.isPending).length;
    final routing = RoutingSummary.fromStatus(status);
    return Column(
      children: [
        PageHeader(
          title: 'Dashboard',
          subtitle: online ? 'online' : 'offline',
          online: online,
          trailing: IconButton(
            tooltip: 'Muat ulang',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) StatusViews.loadingBanner(context),
        if (error != null)
            StatusViews.errorBanner(context, error!),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Card(
                    title: 'Runtime',
                    child: Text(
                      'provider: ${status?['provider'] ?? caps?['provider'] ?? '—'}\n'
                      'memory: ${status?['memory'] ?? caps?['memory'] ?? '—'}\n'
                      'profile: ${status?['resource_profile'] ?? caps?['resource_profile'] ?? '—'}\n'
                      'safe: ${status?['safe_mode'] ?? '—'}\n'
                      'sandbox: ${status?['sandbox'] ?? caps?['sandbox'] ?? '—'}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
                  _Card(
                    title: 'Routing',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('default: ${routing.defaultProvider}'),
                        for (final tier in const ['1', '2', '3'])
                          Text('tier $tier → ${routing.providerForTier(tier)}'),
                        if (routing.health.isEmpty)
                          Text(
                            'belum ada data kesehatan',
                            style: TextStyle(color: context.simpulMuted),
                          ),
                        for (final e in routing.health.entries)
                          Text(
                            '${e.key}: ${e.value['open'] == true ? 'circuit open' : 'sehat'}'
                            ' (${e.value['failures'] ?? 0} gagal)',
                            style: TextStyle(
                              color: e.value['open'] == true
                                  ? context.simpulDanger
                                  : context.simpulMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _Card(
                    title: 'MCP',
                    child: routing.mcpServers.isEmpty
                        ? Text(
                            'Tidak ada server MCP.',
                            style: TextStyle(color: context.simpulMuted),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final s in routing.mcpServers)
                                Text(
                                  '${s['id']} · ${s['type']} · '
                                  '${s['enabled'] == true ? 'aktif' : 'nonaktif'}',
                                  style: TextStyle(
                                    color: s['enabled'] == true
                                        ? null
                                        : context.simpulMuted,
                                  ),
                                ),
                            ],
                          ),
                  ),
                  _Card(
                    title: 'Approvals',
                    child: Text(
                      pending == 0
                          ? 'Tidak ada pending'
                          : '$pending menunggu keputusan',
                      style: TextStyle(
                        color: pending > 0
                            ? context.simpulWarn
                            : context.simpulMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _Card(
                    title: 'Doctor',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: doctor.isEmpty
                          ? [
                              Text(
                                '—',
                                style: TextStyle(color: context.simpulMuted),
                              ),
                            ]
                          : doctor
                                .map(
                                  (c) => Text(
                                    '[${c['status']}] ${c['name']}: ${c['detail']}',
                                    style: TextStyle(
                                      color: c['status'] == 'fail'
                                          ? context.simpulDanger
                                          : c['status'] == 'warn'
                                          ? context.simpulWarn
                                          : null,
                                      height: 1.4,
                                    ),
                                  ),
                                )
                                .toList(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Events terbaru',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              ...events
                  .take(20)
                  .map(
                    (e) => ListTile(
                      dense: true,
                      title: Text(e.type),
                      subtitle: Text(e.at),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

// ——— Approvals ———
class _ApprovalsPage extends StatelessWidget {
  const _ApprovalsPage({
    required this.approvals,
    required this.online,
    required this.loading,
    required this.onRefresh,
    required this.onDecide,
  });

  final List<ApprovalSummary> approvals;
  final bool online;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id, bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final pending = approvals.where((a) => a.isPending).toList();
    final rest = approvals.where((a) => !a.isPending).toList();
    return Column(
      children: [
        PageHeader(
          title: 'Approvals',
          subtitle: '${pending.length} pending',
          online: online,
          trailing: IconButton(
            tooltip: 'Muat ulang',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) StatusViews.loadingBanner(context),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (pending.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Tidak ada permintaan izin.',
                    style: TextStyle(color: context.simpulMuted),
                  ),
                ),
              ...pending.map(
                (a) => Card(
                  color: context.simpulPanel,
                  child: ListTile(
                    title: Text(
                      '${a.tool} · ${a.risk}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${a.id}\n${a.args}\n${a.createdAt}',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: Wrap(
                      spacing: 2,
                      children: [
                        IconButton(
                          tooltip: 'Approve',
                          onPressed: () => onDecide(a.id, true),
                          icon: Icon(
                            Icons.check_circle,
                            color: context.simpulAccent,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Deny',
                          onPressed: () => onDecide(a.id, false),
                          icon: Icon(Icons.cancel, color: context.simpulDanger),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (rest.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
                  child: Text(
                    'Riwayat',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                ...rest
                    .take(30)
                    .map(
                      (a) => ListTile(
                        dense: true,
                        title: Text(
                          '${a.state} · ${a.tool}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${a.id} · ${a.actor}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ——— Sessions ———
class _SessionsPage extends StatelessWidget {
  const _SessionsPage({
    required this.sessions,
    required this.current,
    required this.online,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onNewChat,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onTogglePin,
    required this.onToggleArchive,
    required this.onDuplicate,
    required this.onExport,
    required this.onBulkDelete,
  });

  final List<SessionSummary> sessions;
  final String current;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final VoidCallback onNewChat;
  final void Function(String id) onSelect;
  final Future<void> Function(String id, String title) onRename;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(String id, bool pinned) onTogglePin;
  final Future<void> Function(String id, bool archived) onToggleArchive;
  final Future<void> Function(String id) onDuplicate;
  final Future<void> Function(String id, String format) onExport;
  final Future<void> Function(List<String> ids) onBulkDelete;

  @override
  Widget build(BuildContext context) {
    return SessionHistoryView(
      sessions: sessions,
      current: current,
      online: online,
      loading: loading,
      error: error,
      onRefresh: onRefresh,
      onNewChat: onNewChat,
      onSelect: onSelect,
      onRename: onRename,
      onDelete: onDelete,
      onTogglePin: onTogglePin,
      onToggleArchive: onToggleArchive,
      onDuplicate: onDuplicate,
      onExport: onExport,
      onBulkDelete: onBulkDelete,
    );
  }
}

// ——— Memory ———
class _MemoryPage extends StatelessWidget {
  const _MemoryPage({
    required this.memories,
    required this.online,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onDelete,
  });
  final List<MemoryFact> memories;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'Memory',
          subtitle: '${memories.length} fakta',
          online: online,
          trailing: IconButton(
            tooltip: 'Muat ulang',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) StatusViews.loadingBanner(context),
        if (error != null)
            StatusViews.errorBanner(context, error!),
        Expanded(
          child: memories.isEmpty
              ? StatusViews.empty(context, message: 'Kosong')
              : ListView.builder(
                  itemCount: memories.length,
                  itemBuilder: (context, i) {
                    final memory = memories[i];
                    return ListTile(
                      title: Text(
                        memory.text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${memory.id} · ${memory.kind}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Hapus memori',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              title: const Text('Hapus memori?'),
                              content: const Text(
                                'Fakta ini akan dihapus dari penyimpanan Tiko.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, false),
                                  child: const Text('Batal'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, true),
                                  child: const Text('Hapus'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) await onDelete(memory.id);
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ——— Settings ———
/// Shows the self-contained desktop daemon bootstrap state (Hermes-parity):
/// which daemon the app is using, its home directory and log location.
class _DaemonStatusCard extends StatelessWidget {
  final DaemonConnection? conn = DesktopDaemon.lastConnection;

  @override
  Widget build(BuildContext context) {
    final c = conn;
    final String modeText;
    final String detail;
    if (c == null) {
      modeText = 'manual';
      detail =
          'Daemon tidak di-bootstrap otomatis; gunakan koneksi manual di atas.';
    } else if (c.mode == 'reuse') {
      modeText = 'daemon berjalan (reuse)';
      detail =
          'Terhubung ke daemon yang sudah sehat di ${c.baseUrl}. Home: ${c.home}';
    } else if (c.mode == 'started') {
      modeText = 'daemon di-spawn otomatis';
      detail =
          'Agentd diluncurkan dari binary bundled (pid ${c.pid}). Home: ${c.home}. Log: ${c.logPath}';
    } else {
      modeText = c.mode;
      detail = c.home ?? '';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.simpulBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daemon: $modeText',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(color: context.simpulMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage({
    required this.repo,
    required this.baseUrl,
    required this.token,
    required this.memories,
    required this.tasks,
    required this.logFiles,
    required this.events,
    required this.skills,
    required this.bots,
    required this.bindings,
    required this.providers,
    required this.pluginSnapshot,
    required this.channelSnapshot,
    required this.jobsSnapshot,
    required this.securitySnapshot,
    required this.auditResult,
    required this.onQueryAudit,
    required this.artifactsListing,
    required this.artifactsDir,
    required this.artifactContent,
    required this.artifactDiff,
    required this.loadingArtifacts,
    required this.artifactsError,
    required this.sessionOptions,
    required this.onOpenArtifactsDir,
    required this.onOpenArtifactFile,
    required this.onCloseArtifactPreview,
    required this.runsSnapshot,
    required this.runsLoading,
    required this.runsError,
    required this.onLoadRuns,
    required this.daemonStatus,
    required this.availableSessions,
    required this.online,
    required this.onRefresh,
    required this.onConnect,
    required this.settings,
    required this.onSettingsChanged,
    required this.surfaceSectionFor,
  });

  /// Hermes S8: builder seksi surface A2UI dinamis untuk halaman yang
  /// dibuka sebagai push route dari menu More.
  final Widget? Function(String target)? surfaceSectionFor;
  final AgentRepository repo;
  final String baseUrl;
  final String token;
  final List<MemoryFact> memories;
  final List<TaskItem> tasks;
  final List<LogFileInfo> logFiles;
  final List<RuntimeEvent> events;
  final List<SkillItem> skills;
  final List<BotProfileItem> bots;
  final Map<String, String> bindings;
  final ProvidersSnapshot? providers;
  final PluginsToolsSnapshot? pluginSnapshot;
  final ChannelsSnapshot? channelSnapshot;
  final JobsSnapshot? jobsSnapshot;
  final SecuritySnapshot? securitySnapshot;
  final AuditQueryResult? auditResult;
  final Future<void> Function(Map<String, String> filters) onQueryAudit;
  final ArtifactsListing? artifactsListing;
  final String artifactsDir;
  final ArtifactContent? artifactContent;
  final ArtifactDiff? artifactDiff;
  final bool loadingArtifacts;
  final String? artifactsError;
  final List<SessionSummary> sessionOptions;
  final void Function(String dir) onOpenArtifactsDir;
  final void Function(String path) onOpenArtifactFile;
  final VoidCallback onCloseArtifactPreview;
  final RunsSnapshot? runsSnapshot;
  final bool runsLoading;
  final String? runsError;
  final Future<void> Function() onLoadRuns;
  final Map<String, dynamic>? daemonStatus;
  final List<String> availableSessions;
  final bool online;
  final Future<void> Function() onRefresh;
  final void Function({required String base, required String tok}) onConnect;
  final AppSettings settings;
  final void Function(AppSettings) onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    final showAdvanced = settings.advancedMode;
    return ListView(
      children: [
        PageHeader(
          title: 'More',
          subtitle: 'Tasks, Memory, Tools',
          online: online,
        ),
        ListTile(
          leading: const Icon(Icons.view_kanban_outlined),
          title: Text('Tasks (${tasks.length})'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: TaskBoardPage(
                    tasks: tasks,
                    online: online,
                    loading: false,
                    error: null,
                    onRefresh: onRefresh,
                    surfaceSection: surfaceSectionFor?.call('tasks'),
                  ),
                ),
              ),
            );
          },
        ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: Text('Events (${events.length})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: EventsPage(
                      events: events,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text('Logs (${logFiles.length})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: LogsPage(
                      logs: logFiles,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onLoadContent: repo.logContent,
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text('Skills (${skills.length})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: SkillsPage(
                      skills: skills,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onFeedback: (slug, positive) async {
                        final ok = await repo.skillFeedback(slug, positive);
                        if (ok) await onRefresh();
                        return ok;
                      },
                      onEvaluate: repo.evaluateSkill,
                      onApprove: repo.approveSkill,
                      onRollback: repo.rollbackSkill,
                      onLoadHistory: repo.skillHistory,
                      surfaceSection: surfaceSectionFor?.call('skills'),
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text('Bots (${bots.length})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: BotsPage(
                      bots: bots,
                      bindings: bindings,
                      availableSessions: const [],
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onCreate: (body) async {
                        await repo.createBot(body);
                        await onRefresh();
                      },
                      onUpdate: (id, body) async {
                        await repo.updateBot(id, body);
                        await onRefresh();
                      },
                      onDelete: repo.deleteBot,
                      onBind: repo.bindBot,
                      onUnbind: repo.unbindBot,
                      surfaceSection: surfaceSectionFor?.call('bots'),
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.route_outlined),
            title: Text('Providers (${providers?.providers.length ?? 0})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ProviderManagerPage(
                      snapshot: providers,
                      availableSessions: availableSessions,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onSetSessionProvider: (sessionId, providerArg) async {
                        final ok = await repo.setSessionProvider(
                          sessionId,
                          providerArg,
                        );
                        if (ok) await onRefresh();
                        return ok;
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: Text('Plugins (${pluginSnapshot?.plugins.length ?? 0})'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: PluginManagerPage(
                      snapshot: pluginSnapshot,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onConsent: (plugin, action) async {
                        final message = await repo.setPluginConsent(
                          plugin,
                          action,
                        );
                        await onRefresh();
                        return message;
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: Text(
              'Channels ('
              '${channelSnapshot?.channels.where((c) => c.active).length ?? 0})',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ChannelsPage(
                      snapshot: channelSnapshot,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: Text(
              'Automation ('
              '${jobsSnapshot?.jobs.where((j) => j.enabled).length ?? 0} job aktif)',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: AutomationPage(
                      snapshot: jobsSnapshot,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      onCreate: (body) async {
                        await repo.createJob(body);
                        await onRefresh();
                      },
                      onUpdate: (id, body) async {
                        await repo.updateJob(id, body);
                        await onRefresh();
                      },
                      onDelete: (id) async {
                        final ok = await repo.deleteJob(id);
                        await onRefresh();
                        return ok;
                      },
                      onRunNow: (id) async {
                        final job = await repo.runJobNow(id);
                        await onRefresh();
                        return job;
                      },
                      surfaceSection: surfaceSectionFor?.call('automation'),
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.security_outlined),
            title: Text(
              'Security (${securitySnapshot?.safeMode == true ? 'safe mode' : 'normal'}',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: SecurityPage(
                      snapshot: securitySnapshot,
                      online: online,
                      loading: false,
                      error: null,
                      onRefresh: onRefresh,
                      surfaceSection: surfaceSectionFor?.call('security'),
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(
              'Audit'
              '${auditResult == null ? '' : ' (${auditResult!.total} cocok)'}',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: AuditPage(
                      result: auditResult,
                      online: online,
                      loading: false,
                      error: null,
                      onQuery: onQueryAudit,
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text(
              'Artifacts'
              '${artifactsListing == null ? '' : ' (${artifactsListing!.files.length})'}',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ArtifactsPage(
                      listing: artifactsListing,
                      online: online,
                      loading: loadingArtifacts,
                      error: artifactsError,
                      dir: artifactsDir,
                      sessionOptions: sessionOptions,
                      onOpenDir: onOpenArtifactsDir,
                      onOpenFile: onOpenArtifactFile,
                      onClosePreview: onCloseArtifactPreview,
                      onRefresh: () async {
                        onOpenArtifactsDir(artifactsDir);
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(
              'Runs'
              '${runsSnapshot == null ? '' : ' (${runsSnapshot!.active.length} aktif)'}',
            ),
            onTap: () {
              onLoadRuns();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: SafeArea(
                      child: RunsPage(
                        snapshot: runsSnapshot,
                        online: online,
                        loading: runsLoading,
                        error: runsError,
                        onRefresh: onLoadRuns,
                        surfaceSection: surfaceSectionFor?.call('runs'),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: Text('Memory (${memories.length})'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: _MemoryPage(
                    memories: memories,
                    online: online,
                    loading: false,
                    error: null,
                    onRefresh: onRefresh,
                    onDelete: (id) async {
                      try {
                        final deleted = await repo.deleteMemory(id);
                        if (!deleted) {
                          throw StateError(
                            'Memori tidak ditemukan atau gagal dihapus.',
                          );
                        }
                        await onRefresh();
                        if (context.mounted) Navigator.of(context).pop();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Gagal menghapus memori: $error'),
                            ),
                          );
                        }
                      }
                    },
                  ),
                ),
              ),
            );
          },
        ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Graf Vault (Simpul)'),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => SimpulGraphPage()));
            },
          ),
        if (showAdvanced)
          ListTile(
            leading: const Icon(Icons.edit_note_outlined),
            title: const Text('Editor Catatan (Simpul)'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SimpulNoteEditorPage(
                    vault: settings.vaultPath,
                    powerSaverEnabled: settings.powerSaver,
                    resourceStats: true,
                  ),
                ),
              );
            },
          ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: SettingsView(
                    settings: settings,
                    baseUrl: baseUrl,
                    token: token,
                    online: online,
                    onConnect: onConnect,
                    onSettingsChanged: onSettingsChanged,
                    daemonCard: _DaemonStatusCard(),
                    daemonStatus: daemonStatus,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(220.0, 280.0).toDouble()
            : 280.0;
        return Container(
          width: width,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.simpulSurfaceRaised,
            borderRadius: BorderRadius.circular(SimpulTheme.radiusLarge),
            border: Border.all(color: context.simpulBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: SimpulTheme.sectionTitle),
              const SizedBox(height: 8),
              child,
            ],
          ),
        );
      },
    );
  }
}

/// C3 Chat-UX: kartu ringkas file yang disentuh tool turn aktif — pola
/// review-before-apply (serupa kartu file/diff Cursor). Tombol "Lihat"
/// membuka isi file di panel chat; "Diff" membuka perbandingan vs `.bak`
/// bila ada. Kartu hanya tampil bila data file tersedia dari turn; sumber
/// otomatisnya menyusul di C4 (WS frames dari tool trace).
/// C4 Chat-UX: strip proses turn — spinner + tool aktif ("Menjalankan X…")
/// atau "Menyusun…" saat busy, dengan tombol Stop (pembatalan kooperatif
/// via cancel token runtime — tidak ada jaminan langsung). Setelah turn,
/// jadi ringkasan collapsible: jumlah tool + durasi total + status error.
class _TurnProgressStrip extends StatelessWidget {
  const _TurnProgressStrip({required this.chat});

  final ChatController chat;

  @override
  Widget build(BuildContext context) {
    if (chat.busy) {
      final tool = chat.activeTool;
      final label = chat.stopRequested
          ? 'Menghentikan…'
          : (tool == null || tool.isEmpty)
              ? 'Menyusun…'
              : 'Menjalankan ${_friendlyToolName(tool)}…';
      return Semantics(
        liveRegion: true,
        label: 'Status agent: $label',
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          decoration: BoxDecoration(
            color: context.simpulSurfaceHover,
            border: Border(top: BorderSide(color: context.simpulBorder)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: chat.stopRequested
                    ? Icon(
                        Icons.hourglass_top,
                        size: 14,
                        color: context.simpulWarn,
                      )
                    : const CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.simpulMuted),
                ),
              ),
              IconButton(
                key: const Key('btn-chat-stop'),
                tooltip: chat.stopRequested
                    ? 'Menunggu agent berhenti'
                    : 'Hentikan proses agent',
                icon: Icon(
                  Icons.stop_circle_outlined,
                  size: 20,
                  color: context.simpulDanger,
                ),
                onPressed: chat.stopRequested ? null : chat.stop,
              ),
            ],
          ),
        ),
      );
    }
    if (chat.lastTurnTrace.isEmpty) return const SizedBox.shrink();
    final errCount = chat.lastTurnTrace
        .where((t) => t['is_error'] == true)
        .length;
    final totalMs = chat.lastTurnTrace.fold<int>(
      0,
      (s, t) => s + ((t['duration_ms'] as num?)?.toInt() ?? 0),
    );
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('strip-turn-summary'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        dense: true,
        title: Text(
          '${chat.lastTurnTrace.length} langkah agent selesai '
          '(total ${(totalMs / 1000).toStringAsFixed(1)}s)'
          '${errCount > 0 ? ' · $errCount error' : ''}',
          style: TextStyle(fontSize: 12, color: context.simpulMuted),
        ),
        children: [
          for (final t in chat.lastTurnTrace)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    t['is_error'] == true
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 14,
                    color: t['is_error'] == true
                        ? context.simpulDanger
                        : context.simpulMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${t['name']}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Text(
                    '${t['duration_ms']} ms',
                    style: TextStyle(fontSize: 11, color: context.simpulMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _friendlyToolName(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return 'tool';
  return value
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    super.key,
    required this.path,
    required this.changed,
    this.onOpen,
    this.onOpenDiff,
  });

  final String path;
  final bool changed;
  final VoidCallback? onOpen;
  final VoidCallback? onOpenDiff;

  @override
  Widget build(BuildContext context) {
    final safePath = path.trim();
    if (safePath.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
        border: Border.all(color: context.simpulBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            changed ? Icons.difference_outlined : Icons.insert_drive_file_outlined,
            size: 16,
            color: changed ? context.simpulWarn : context.simpulMuted,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              safePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                'berubah',
                style: TextStyle(fontSize: 10, color: context.simpulWarn),
              ),
            ),
          if (onOpen != null)
            IconButton(
              tooltip: 'Lihat isi file di panel',
              icon: const Icon(Icons.visibility_outlined, size: 16),
              onPressed: onOpen,
            ),
          if (onOpenDiff != null)
            IconButton(
              tooltip: 'Lihat diff vs .bak',
              icon: const Icon(Icons.difference_outlined, size: 16),
              onPressed: onOpenDiff,
            ),
        ],
      ),
    );
  }
}
