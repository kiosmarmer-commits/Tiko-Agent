import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_api_client.dart';
import 'daemon/desktop_daemon.dart';
import 'ui/chat_controller.dart';
import 'ui/graph_view.dart';
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
  runApp(AgentApp(initialBaseUrl: base, initialToken: token));
}

const _bg = Color(0xFF0F1115);
const _panel = Color(0xFF171A21);
const _accent = Color(0xFF2A9D8F);
const _userBubble = Color(0xFF1B3A4B);
const _botBubble = Color(0xFF1E2430);
const _border = Color(0xFF2A2F3A);
const _muted = Color(0xFF9AA0A6);
const _warn = Color(0xFFE9C46A);
const _danger = Color(0xFFE76F51);

class AgentApp extends StatefulWidget {
  const AgentApp({
    super.key,
    required this.initialBaseUrl,
    required this.initialToken,
  });

  final String initialBaseUrl;
  final String initialToken;

  @override
  State<AgentApp> createState() => _AgentAppState();
}

class _AgentAppState extends State<AgentApp> {
  late String baseUrl;
  late String token;
  late AgentApiClient client;
  late ChatController chat;
  Timer? statusTimer;
  int tab = 0;
  String sessionKey = 'flutter:default';

  Map<String, dynamic>? status;
  Map<String, dynamic>? caps;
  List<Map<String, dynamic>> doctor = [];
  List<Map<String, dynamic>> sessions = [];
  List<Map<String, dynamic>> approvals = [];
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> memories = [];
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
    chat = ChatController(client);
    chat.checkOnline();
    statusTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      chat.checkOnline();
      if (tab >= 1 && tab <= 4) unawaited(refreshAdmin());
    });
    unawaited(refreshAdmin());
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
        client.status(),
        client.capabilities(),
        client.doctor(),
        client.listSessions(),
        client.listApprovals(),
        client.listEvents(),
        client.listMemories(),
      ]);
      if (!mounted || generation != adminRefreshGeneration) return;
      setState(() {
        status = results[0] as Map<String, dynamic>;
        caps = results[1] as Map<String, dynamic>;
        doctor = results[2] as List<Map<String, dynamic>>;
        sessions = results[3] as List<Map<String, dynamic>>;
        approvals = results[4] as List<Map<String, dynamic>>;
        events = results[5] as List<Map<String, dynamic>>;
        memories = results[6] as List<Map<String, dynamic>>;
      });
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

  void updateConnection({required String base, required String tok}) {
    setState(() {
      baseUrl = base;
      token = tok;
      client.baseUrl = base;
      client.token = tok;
      chat.client = client;
      chat.checkOnline();
    });
    unawaited(refreshAdmin(force: true));
  }

  @override
  void dispose() {
    statusTimer?.cancel();
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
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          surface: _panel,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    backgroundColor: _panel,
                    selectedIndex: tab.clamp(0, 5),
                    onDestinationSelected: (i) {
                      setState(() => tab = i);
                      if (i != 0) unawaited(refreshAdmin());
                    },
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.chat_bubble_outline),
                        label: Text('Chat'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.dashboard_outlined),
                        label: Text('Dashboard'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.verified_user_outlined),
                        label: Text('Approvals'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.forum_outlined),
                        label: Text('Sessions'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.memory_outlined),
                        label: Text('Memory'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        label: Text('Settings'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1, color: _border),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: chat,
                      builder: (context, _) => _body(wide: true),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(
                    child: AnimatedBuilder(
                      animation: chat,
                      builder: (context, _) => _body(wide: false),
                    ),
                  ),
                  NavigationBar(
                    backgroundColor: _panel,
                    selectedIndex: tab.clamp(0, 4),
                    onDestinationSelected: (i) {
                      setState(() => tab = i);
                      if (i != 0) unawaited(refreshAdmin());
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.chat_bubble_outline),
                        label: 'Chat',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.dashboard_outlined),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.verified_user_outlined),
                        label: 'Approve',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.forum_outlined),
                        label: 'Sessions',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.more_horiz),
                        label: 'More',
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _body({required bool wide}) {
    if (!wide && tab == 4) {
      return _MorePage(
        client: client,
        baseUrl: baseUrl,
        token: token,
        memories: memories,
        online: chat.online,
        onRefresh: refreshAdmin,
        onConnect: updateConnection,
      );
    }
    switch (tab) {
      case 0:
        return _ChatPage(chat: chat, sessionKey: sessionKey);
      case 1:
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
      case 2:
        return _ApprovalsPage(
          approvals: approvals,
          online: chat.online,
          loading: loadingAdmin,
          onRefresh: refreshAdmin,
          onDecide: (id, ok) async {
            try {
              final decided = await client.decideApproval(id, ok);
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
      case 3:
        return _SessionsPage(
          sessions: sessions,
          current: sessionKey,
          online: chat.online,
          loading: loadingAdmin,
          onRefresh: refreshAdmin,
          onSelect: (id) => setState(() {
            sessionKey = id;
            chat.clearChat();
            tab = 0;
          }),
        );
      case 4:
        return _MemoryPage(
          memories: memories,
          online: chat.online,
          loading: loadingAdmin,
          error: adminError,
          onRefresh: refreshAdmin,
          onDelete: (id) async {
            try {
              final deleted = await client.deleteMemory(id);
              if (!deleted) throw StateError('Memori tidak ditemukan atau gagal dihapus.');
              await refreshAdmin();
            } catch (error) {
              if (mounted) setState(() => adminError = 'Gagal menghapus memori: $error');
            }
          },
        );
      case 5:
        return _SettingsPage(
          baseUrl: baseUrl,
          token: token,
          online: chat.online,
          onConnect: updateConnection,
        );
      default:
        return const SizedBox.shrink();
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
            _TopBar(
              title: 'Chat',
              subtitle: widget.sessionKey,
              online: chat.online,
            ),
            Expanded(
              child: chat.messages.isEmpty
                  ? const Center(
                      child: Text(
                        'Mulai percakapan dengan Tiko',
                        style: TextStyle(color: _muted),
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
                              color: user ? _userBubble : _botBubble,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _border),
                            ),
                            child: SelectableText(
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
                color: _panel,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Konfirmasi: ${chat.pendingConfirm!.prompt}',
                      style: const TextStyle(color: _warn),
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
      decoration: const BoxDecoration(
        color: _panel,
        border: Border(top: BorderSide(color: _border)),
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
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> approvals;
  final bool loading;
  final String? error;
  final bool online;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final pending =
        approvals.where((a) => a['state'] == 'pending').length;
    final routing = RoutingSummary.fromStatus(status);
    return Column(
      children: [
        _TopBar(
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
            child: Text(error!, style: const TextStyle(color: _danger)),
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
                          const Text('belum ada data kesehatan',
                              style: TextStyle(color: _muted)),
                        for (final e in routing.health.entries)
                          Text(
                            '${e.key}: ${e.value['open'] == true ? 'circuit open' : 'sehat'}'
                            ' (${e.value['failures'] ?? 0} gagal)',
                            style: TextStyle(
                              color: e.value['open'] == true ? _danger : _muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _Card(
                    title: 'MCP',
                    child: routing.mcpServers.isEmpty
                        ? const Text(
                            'Tidak ada server MCP.',
                            style: TextStyle(color: _muted),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final s in routing.mcpServers)
                                Text(
                                  '${s['id']} · ${s['type']} · '
                                  '${s['enabled'] == true ? 'aktif' : 'nonaktif'}',
                                  style: TextStyle(
                                    color: s['enabled'] == true ? null : _muted,
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
                        color: pending > 0 ? _warn : _muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _Card(
                    title: 'Doctor',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: doctor.isEmpty
                          ? [const Text('—', style: TextStyle(color: _muted))]
                          : doctor
                              .map((c) => Text(
                                    '[${c['status']}] ${c['name']}: ${c['detail']}',
                                    style: TextStyle(
                                      color: c['status'] == 'fail'
                                          ? _danger
                                          : c['status'] == 'warn'
                                              ? _warn
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
                    title: Text('${e['type'] ?? ''}'),
                    subtitle: Text('${e['at'] ?? e}'),
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

  final List<Map<String, dynamic>> approvals;
  final bool online;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id, bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final pending = approvals.where((a) => a['state'] == 'pending').toList();
    final rest = approvals.where((a) => a['state'] != 'pending').toList();
    return Column(
      children: [
        _TopBar(
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
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Tidak ada permintaan izin.', style: TextStyle(color: _muted)),
                ),
              ...pending.map((a) => Card(
                    color: _panel,
                    child: ListTile(
                      title: Text('${a['tool']} · ${a['risk']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${a['id']}\n${a['args']}\n${a['created_at'] ?? ''}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      trailing: Wrap(
                        spacing: 2,
                        children: [
                          IconButton(
                            tooltip: 'Approve',
                            onPressed: () => onDecide('${a['id']}', true),
                            icon: const Icon(Icons.check_circle, color: _accent),
                          ),
                          IconButton(
                            tooltip: 'Deny',
                            onPressed: () => onDecide('${a['id']}', false),
                            icon: const Icon(Icons.cancel, color: _danger),
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
                      title: Text('${a['state']} · ${a['tool']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${a['id']} · ${a['actor'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
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
    required this.onRefresh,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> sessions;
  final String current;
  final bool online;
  final bool loading;
  final Future<void> Function() onRefresh;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          title: 'Sessions',
          subtitle: '${sessions.length} sesi',
          online: online,
          trailing: IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: sessions.isEmpty
              ? const Center(child: Text('Belum ada sesi.', style: TextStyle(color: _muted)))
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final session = sessions[i];
                    final id = '${session['id']}';
                    return ListTile(
                      selected: id == current,
                      leading: const Icon(Icons.forum_outlined),
                      title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${session['channel'] ?? ''} · ${session['updated_at'] ?? ''} · turns=${session['turns'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
  final List<Map<String, dynamic>> memories;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          title: 'Memory',
          subtitle: '${memories.length} fakta',
          online: online,
          trailing: IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: const TextStyle(color: _danger)),
          ),
        Expanded(
          child: memories.isEmpty
              ? const Center(child: Text('Kosong', style: TextStyle(color: _muted)))
              : ListView.builder(
                  itemCount: memories.length,
                  itemBuilder: (context, i) {
                    final memory = memories[i];
                    return ListTile(
                      title: Text('${memory['text'] ?? memory}', maxLines: 4, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${memory['id']} · ${memory['kind'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
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
                          if (confirmed == true) await onDelete('${memory['id']}');
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
class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.baseUrl,
    required this.token,
    required this.online,
    required this.onConnect,
  });
  final String baseUrl;
  final String token;
  final bool online;
  final void Function({required String base, required String tok}) onConnect;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final baseC = TextEditingController(text: widget.baseUrl);
  late final tokC = TextEditingController(text: widget.token);

  @override
  void dispose() {
    baseC.dispose();
    tokC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TopBar(title: 'Settings', subtitle: 'API', online: widget.online),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: baseC,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API base URL',
                  hintText: 'http://127.0.0.1:8787',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final uri = Uri.tryParse((value ?? '').trim());
                  if (uri == null || !uri.hasAuthority || uri.host.isEmpty ||
                      !const ['http', 'https'].contains(uri.scheme) ||
                      uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
                    return 'Masukkan URL HTTP(S) yang valid.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: tokC,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Bearer token',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Bearer token wajib diisi.'
                    : null,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (!_formKey.currentState!.validate()) return;
                    widget.onConnect(
                      base: baseC.text.trim().replaceFirst(RegExp(r'/+$'), ''),
                      tok: tokC.text.trim(),
                    );
                  },
                  child: const Text('Simpan & hubungkan'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _DaemonStatusCard(),
        const SizedBox(height: 16),
        const Text(
          'Pastikan daemon berjalan dengan perintah tiko daemon start. Token berada di data/api.token (permission POSIX 0600); pindahkan nilainya secara aman ke kolom Bearer token.',
          style: TextStyle(color: _muted, height: 1.5),
        ),
      ],
    );
  }
}

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
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Daemon: $modeText', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(detail, style: const TextStyle(color: _muted, height: 1.4)),
        ],
      ),
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage({
    required this.client,
    required this.baseUrl,
    required this.token,
    required this.memories,
    required this.online,
    required this.onRefresh,
    required this.onConnect,
  });
  final AgentApiClient client;
  final String baseUrl;
  final String token;
  final List<Map<String, dynamic>> memories;
  final bool online;
  final Future<void> Function() onRefresh;
  final void Function({required String base, required String tok}) onConnect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _TopBar(title: 'More', subtitle: 'Memory & Settings', online: online),
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
                      final deleted = await client.deleteMemory(id);
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
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: _SettingsPage(
                  baseUrl: baseUrl,
                  token: token,
                  online: online,
                  onConnect: onConnect,
                ),
              ),
            ));
          },
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.online,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final bool online;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        color: _panel,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          if (Navigator.of(context).canPop())
            IconButton(
              tooltip: 'Kembali',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? _accent : _danger,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
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
            color: _panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
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
