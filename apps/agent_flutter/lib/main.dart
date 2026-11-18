import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_api_client.dart';
import 'app/app_routes.dart';
import 'daemon/desktop_daemon.dart';
import 'data/admin_event_feed.dart';
import 'data/agent_repository.dart';
import 'data/models.dart';
import 'shell/desktop_shell.dart';
import 'shell/mobile_shell.dart';
import 'ui/chat_controller.dart';
import 'ui/gen_ui_view.dart';
import 'ui/logs_view.dart';
import 'ui/page_header.dart';
import 'ui/bot_manager_view.dart';
import 'ui/provider_manager_view.dart';
import 'ui/plugin_manager_view.dart';
import 'ui/channels_view.dart';
import 'ui/automation_view.dart';
import 'ui/artifact_view.dart';
import 'ui/audit_page.dart';
import 'ui/memory_explorer_page.dart';
import 'ui/runs_page.dart';
import 'ui/security_view.dart';
import 'ui/skills_view.dart';
import 'ui/settings_store.dart';
import 'ui/settings_view.dart';
import 'ui/theme.dart';
import 'ui/tasks_view.dart';
import 'ui/events_view.dart';
import 'ui/graph_view.dart';
import 'ui/note_editor.dart';
import 'ui/status_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var token = const String.fromEnvironment('API_TOKEN', defaultValue: '');
  var base = const String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://127.0.0.1:8787',
  );
  // Self-contained desktop bootstrap (Hermes-parity): spawn/reuse the bundled
  // agentd daemon so the app works without a manually started daemon. Falls
  // back to the dart-define connection settings when bootstrap does not apply
  // (web/Android) or fails.
  try {
    final conn = await DesktopDaemon.ensure(
      binaryOverride:
          const String.fromEnvironment('AGENTD_BIN', defaultValue: ''),
    );
    if (conn != null) {
      base = conn.baseUrl;
      token = conn.token;
    }
  } catch (_) {
    // Bootstrap is best-effort; the manual connection settings still work.
  }
  final settings = await AppSettings.load();
  runApp(AgentApp(
    initialBaseUrl: base,
    initialToken: token,
    initialSettings: settings,
  ));
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
  AuditQueryResult? auditResult;
  Map<String, String> auditFilters = const {};
  int auditOffset = 0;
  ArtifactsListing? artifactsListing;
  String artifactsDir = '';
  ArtifactContent? artifactContent;
  ArtifactDiff? artifactDiff;
  bool loadingArtifacts = false;
  String? artifactsError;
  RunsSnapshot? runsSnapshot;
  bool runsLoading = false;
  String? runsError;
  CuratedMemoryInfo? curatedMemoryInfo;
  LayersSnapshot? layersSnapshot;
  RagSourcesInfo? ragSources;
  bool memoryExplorerLoading = false;
  String? memoryExplorerError;
  bool auditLoading = false;
  String? auditError;
  List<MemoryFact> memories = [];
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
    )
      ..start();
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

  Future<void> _queryAudit(Map<String, String> filters, {int offset = 0}) async {
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

  Future<void> _openArtifact(String path) async {
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
      final info =
          await repo.setCuratedMemory(file: file, text: text);
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

  void updateConnection({required String base, required String tok}) {
    setState(() {
      baseUrl = base;
      token = tok;
      client.baseUrl = base;
      client.token = tok;
      chat.checkOnline();
    });
    // Kredensial berubah — buang feed lama; refresh penuh akan memulai ulang
    // feed WS dengan kredensial baru bila daemon terhubung.
    eventFeed?.dispose();
    _eventFeedStarted = false;
    unawaited(refreshAdmin(force: true));
  }

  Future<void> _applySettings(AppSettings next) async {
    setState(() => settings = next);
    await next.save();
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

  @override
  void dispose() {
    statusTimer?.cancel();
    eventFeed?.dispose();
    chat.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return MaterialApp(
      title: 'Tiko',
      debugShowCheckedModeBanner: false,
      theme: SimpulTheme.theme(Brightness.light, settings.accent),
      darkTheme: SimpulTheme.theme(Brightness.dark, settings.accent),
      themeMode: settings.themeMode,
      home: Scaffold(
        body: wide
            ? DesktopShell(
                selected: route,
                onSelect: _selectRoute,
                pendingApprovals: _pendingApprovals,
                child: AnimatedBuilder(
                  animation: chat,
                  builder: (context, _) => _body(wide: true),
                ),
              )
            : MobileShell(
                selected: route.primaryOnMobile ? route : null,
                onSelect: _selectMobileRoute,
                pendingApprovals: _pendingApprovals,
                child: AnimatedBuilder(
                  animation: chat,
                  builder: (context, _) => _body(wide: false),
                ),
              ),
      ),
    );
  }

  int get _pendingApprovals =>
      approvals.where((approval) => approval.isPending).length;

  void _selectRoute(AppRoute next) {
    setState(() => route = next);
    if (next == AppRoute.artifacts &&
        artifactsListing == null) {
      unawaited(_loadArtifacts());
    }
    if (next == AppRoute.runs && runsSnapshot == null) {
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
        return _ChatPage(chat: chat, sessionKey: sessionKey);
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
                setState(() => adminError =
                    'Approval $id tidak lagi pending atau sudah kedaluwarsa.');
              }
            } catch (error) {
              if (mounted) {
                setState(() => adminError = 'Gagal mengirim keputusan approval: $error');
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
              if (!ok) throw StateError('Sesi tidak ditemukan atau gagal diubah.');
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
              if (!deleted) throw StateError('Sesi tidak ditemukan atau gagal dihapus.');
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
        );
      case AppRoute.tasks:
        return TaskBoardPage(
          tasks: tasks,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
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
        );
      case AppRoute.security:
        return SecurityPage(
          snapshot: securitySnapshot,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
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
              offset:
                  auditOffset + (auditResult?.entries.length ?? 50)),
        );
      case AppRoute.artifacts:
        return ArtifactsPage(
          listing: artifactsListing,
          online: chat.online,
          loading: loadingArtifacts,
          error: artifactsError,
          dir: artifactsDir,
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
              if (!deleted) throw StateError('Memori tidak ditemukan atau gagal dihapus.');
              await refreshAdmin();
            } catch (error) {
              if (mounted) setState(() => adminError = 'Gagal menghapus memori: $error');
            }
          },
          onSaveCurated: _saveCurated,
          onAddLayer: _addLayerEntry,
          onDeleteLayer: _deleteLayerEntry,
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
        );
    }
  }

}

// ——— Chat ———
class _ChatPage extends StatefulWidget {
  const _ChatPage({required this.chat, required this.sessionKey});
  final ChatController chat;
  final String sessionKey;

  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.chat.addListener(_followLatestMessage);
  }

  void _followLatestMessage() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final shouldFollow = !position.hasContentDimensions ||
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
      builder: (context, _) {
        final chat = widget.chat;
        return Column(
          children: [
            PageHeader(
              title: 'Chat',
              subtitle: widget.sessionKey,
              online: chat.online,
            ),
            Expanded(
              child: chat.messages.isEmpty
                  ? Center(
                      child: Text(
                        'Mulai percakapan dengan Tiko',
                        style: TextStyle(color: context.simpulMuted),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: chat.messages.length,
                      itemBuilder: (context, i) {
                        final message = chat.messages[i];
                        final user = message['role'] == 'user';
                        return Align(
                          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            constraints: const BoxConstraints(maxWidth: 640),
                            decoration: BoxDecoration(
                              color: user ? context.simpulUserBubble : context.simpulBotBubble,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: context.simpulBorder),
                            ),
                            child: message['role'] == 'assistant'
                                ? GenUiMessageView(
                                    text: (message['text'] ?? '').toString(),
                                    onAction: (actionId, values) {
                                      unawaited(chat.sendUiAction(
                                        actionId,
                                        values,
                                        sessionKey: widget.sessionKey,
                                      ));
                                    },
                                  )
                                : SelectableText(
                                    (message['text'] ?? '').toString(),
                                    style: const TextStyle(height: 1.4),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            if (chat.pendingConfirm != null)
              Container(
                width: double.infinity,
                color: context.simpulPanel,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Konfirmasi: ${chat.pendingConfirm!.prompt}',
                      style: TextStyle(color: context.simpulWarn),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
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
                  ],
                ),
              ),
            _Composer(onSend: (text) => chat.send(text, sessionKey: widget.sessionKey)),
          ],
        );
      },
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.onSend});
  final Future<void> Function(String) onSend;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final c = TextEditingController();
  bool busy = false;

  Future<void> _submit(String value) async {
    final text = value.trim();
    if (text.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      await widget.onSend(text);
      if (!mounted) return;
      c.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengirim pesan: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(top: BorderSide(color: context.simpulBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: c,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Pesan ke Tiko…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (value) => _submit(value),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Kirim pesan',
            onPressed: busy ? null : () => _submit(c.text),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
          ),
        ],
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
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
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
                          Text(
                              'tier $tier → ${routing.providerForTier(tier)}'),
                        if (routing.health.isEmpty)
                          Text('belum ada data kesehatan',
                              style: TextStyle(color: context.simpulMuted)),
                        for (final e in routing.health.entries)
                          Text(
                            '${e.key}: ${e.value['open'] == true ? 'circuit open' : 'sehat'}'
                            ' (${e.value['failures'] ?? 0} gagal)',
                            style: TextStyle(
                              color: e.value['open'] == true ? context.simpulDanger : context.simpulMuted,
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
                                    color: s['enabled'] == true ? null : context.simpulMuted,
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
                        color: pending > 0 ? context.simpulWarn : context.simpulMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _Card(
                    title: 'Doctor',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: doctor.isEmpty
                          ? [Text('—', style: TextStyle(color: context.simpulMuted))]
                          : doctor
                              .map((c) => Text(
                                    '[${c['status']}] ${c['name']}: ${c['detail']}',
                                    style: TextStyle(
                                      color: c['status'] == 'fail'
                                          ? context.simpulDanger
                                          : c['status'] == 'warn'
                                              ? context.simpulWarn
                                              : null,
                                      height: 1.4,
                                    ),
                                  ))
                              .toList(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Events terbaru',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ...events.take(20).map((e) => ListTile(
                    dense: true,
                    title: Text(e.type),
                    subtitle: Text(e.at),
                  )),
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
          trailing: IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (pending.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Tidak ada permintaan izin.', style: TextStyle(color: context.simpulMuted)),
                ),
              ...pending.map((a) => Card(
                    color: context.simpulPanel,
                    child: ListTile(
                      title: Text('${a.tool} · ${a.risk}', maxLines: 2, overflow: TextOverflow.ellipsis),
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
                            icon: Icon(Icons.check_circle, color: context.simpulAccent),
                          ),
                          IconButton(
                            tooltip: 'Deny',
                            onPressed: () => onDecide(a.id, false),
                            icon: Icon(Icons.cancel, color: context.simpulDanger),
                          ),
                        ],
                      ),
                    ),
                  )),
              if (rest.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
                  child: Text('Riwayat', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                ...rest.take(30).map((a) => ListTile(
                      dense: true,
                      title: Text('${a.state} · ${a.tool}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${a.id} · ${a.actor}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    )),
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
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  final List<SessionSummary> sessions;
  final String current;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final void Function(String id) onSelect;
  final Future<void> Function(String id, String title) onRename;
  final Future<void> Function(String id) onDelete;

  Future<void> _confirmRename(BuildContext context, SessionSummary session) async {
    final id = session.id;
    final controller = TextEditingController(text: session.displayTitle);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ganti nama sesi'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Judul sesi'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isNotEmpty) await onRename(id, trimmed);
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus sesi?'),
        content: Text('Transcript "$id" akan dihapus permanen dari daemon.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (confirmed == true) await onDelete(id);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'Sessions',
          subtitle: '${sessions.length} sesi',
          online: online,
          trailing: IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: sessions.isEmpty
              ? Center(child: Text('Belum ada sesi.', style: TextStyle(color: context.simpulMuted)))
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final session = sessions[i];
                    final id = session.id;
                    final title = session.displayTitle;
                    return ListTile(
                      selected: id == current,
                      leading: const Icon(Icons.forum_outlined),
                      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '$id · ${session.channel} · ${session.updatedAt} · turns=${session.turns}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Aksi sesi',
                        onSelected: (action) {
                          if (action == 'rename') {
                            unawaited(_confirmRename(context, session));
                          } else if (action == 'delete') {
                            unawaited(_confirmDelete(context, id));
                          }
                        },
                        itemBuilder: (menuContext) => const [
                          PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Ganti nama'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: Icon(Icons.delete_outline),
                              title: Text('Hapus'),
                            ),
                          ),
                        ],
                      ),
                      onTap: () => onSelect(id),
                    );
                  },
                ),
        ),
      ],
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
          trailing: IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: memories.isEmpty
              ? Center(child: Text('Kosong', style: TextStyle(color: context.simpulMuted)))
              : ListView.builder(
                  itemCount: memories.length,
                  itemBuilder: (context, i) {
                    final memory = memories[i];
                    return ListTile(
                      title: Text(memory.text, maxLines: 4, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${memory.id} · ${memory.kind}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        tooltip: 'Hapus memori',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              title: const Text('Hapus memori?'),
                              content: const Text('Fakta ini akan dihapus dari penyimpanan Tiko.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
                                FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Hapus')),
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
      detail = 'Daemon tidak di-bootstrap otomatis; gunakan koneksi manual di atas.';
    } else if (c.mode == 'reuse') {
      modeText = 'daemon berjalan (reuse)';
      detail = 'Terhubung ke daemon yang sudah sehat di ${c.baseUrl}. Home: ${c.home}';
    } else if (c.mode == 'started') {
      modeText = 'daemon di-spawn otomatis';
      detail = 'Agentd diluncurkan dari binary bundled (pid ${c.pid}). Home: ${c.home}. Log: ${c.logPath}';
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
          Text('Daemon: $modeText', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(detail, style: TextStyle(color: context.simpulMuted, height: 1.4)),
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
  });
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
    return ListView(
      children: [
        PageHeader(title: 'More', subtitle: 'Tasks, Memory, Tools', online: online),
        ListTile(
          leading: const Icon(Icons.view_kanban_outlined),
          title: Text('Tasks (${tasks.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: TaskBoardPage(
                  tasks: tasks,
                  online: online,
                  loading: false,
                  error: null,
                  onRefresh: onRefresh,
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.bolt_outlined),
          title: Text('Events (${events.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: EventsPage(
                  events: events,
                  online: online,
                  loading: false,
                  error: null,
                  onRefresh: onRefresh,
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text('Logs (${logFiles.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text('Skills (${skills.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: Text('Bots (${bots.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.route_outlined),
          title: Text('Providers (${providers?.providers.length ?? 0})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
                        sessionId, providerArg);
                    if (ok) await onRefresh();
                    return ok;
                  },
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.extension_outlined),
          title: Text('Plugins (${pluginSnapshot?.plugins.length ?? 0})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: PluginManagerPage(
                  snapshot: pluginSnapshot,
                  online: online,
                  loading: false,
                  error: null,
                  onRefresh: onRefresh,
                  onConsent: (plugin, action) async {
                    final message = await repo.setPluginConsent(plugin, action);
                    await onRefresh();
                    return message;
                  },
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text('Channels ('
              '${channelSnapshot?.channels.where((c) => c.active).length ?? 0})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: ChannelsPage(
                  snapshot: channelSnapshot,
                  online: online,
                  loading: false,
                  error: null,
                  onRefresh: onRefresh,
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.schedule_outlined),
          title: Text('Automation ('
              '${jobsSnapshot?.jobs.where((j) => j.enabled).length ?? 0} job aktif)'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.security_outlined),
          title: Text(
              'Security (${securitySnapshot?.safeMode == true ? 'safe mode' : 'normal'}'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: SecurityPage(
                  snapshot: securitySnapshot,
                  online: online,
                  loading: false,
                  error: null,
                  onRefresh: onRefresh,
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: Text('Audit'
              '${auditResult == null ? '' : ' (${auditResult!.total} cocok)'}'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: AuditPage(
                  result: auditResult,
                  online: online,
                  loading: false,
                  error: null,
                  onQuery: onQueryAudit,
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.folder_copy_outlined),
          title: Text('Artifacts'
              '${artifactsListing == null ? '' : ' (${artifactsListing!.files.length})'}'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: ArtifactsPage(
                  listing: artifactsListing,
                  online: online,
                  loading: loadingArtifacts,
                  error: artifactsError,
                  dir: artifactsDir,
                  onOpenDir: onOpenArtifactsDir,
                  onOpenFile: onOpenArtifactFile,
                  onClosePreview: onCloseArtifactPreview,
                  onRefresh: () async { onOpenArtifactsDir(artifactsDir); },
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: Text('Runs'
              '${runsSnapshot == null ? '' : ' (${runsSnapshot!.active.length} aktif)'}'),
          onTap: () {
            onLoadRuns();
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: SafeArea(
                  child: RunsPage(
                    snapshot: runsSnapshot,
                    online: online,
                    loading: runsLoading,
                    error: runsError,
                    onRefresh: onLoadRuns,
                  ),
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: Text('Memory (${memories.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
                      if (!deleted) throw StateError('Memori tidak ditemukan atau gagal dihapus.');
                      await onRefresh();
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Gagal menghapus memori: $error')),
                        );
                      }
                    }
                  },
                ),
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: const Text('Graf Vault (Simpul)'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SimpulGraphPage(),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_note_outlined),
          title: const Text('Editor Catatan (Simpul)'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SimpulNoteEditorPage(
                vault: settings.vaultPath,
                powerSaverEnabled: settings.powerSaver,
                resourceStats: true,
              ),
            ));
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
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
            ));
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.simpulPanel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.simpulBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              child,
            ],
          ),
        );
      },
    );
  }
}
