import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_api_client.dart';
import 'ui/chat_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const token = String.fromEnvironment('API_TOKEN', defaultValue: '');
  const base = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://127.0.0.1:8787',
  );
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
      if (tab == 1 || tab == 2) unawaited(refreshAdmin());
    });
    unawaited(refreshAdmin());
  }

  Future<void> refreshAdmin() async {
    setState(() {
      loadingAdmin = true;
      adminError = null;
    });
    try {
      final s = await client.status();
      final c = await client.capabilities();
      final d = await client.doctor();
      final sess = await client.listSessions();
      final apr = await client.listApprovals();
      final ev = await client.listEvents();
      final mem = await client.listMemories();
      if (!mounted) return;
      setState(() {
        status = s;
        caps = c;
        doctor = d;
        sessions = sess;
        approvals = apr;
        events = ev;
        memories = mem;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => adminError = e.toString());
    } finally {
      if (mounted) setState(() => loadingAdmin = false);
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
    unawaited(refreshAdmin());
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
                  Expanded(child: _body(wide: true)),
                ],
              )
            : Column(
                children: [
                  Expanded(child: _body(wide: false)),
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
        onRefresh: refreshAdmin,
        onConnect: updateConnection,
        onOpenMemory: () => setState(() => tab = 4),
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
          loading: loadingAdmin,
          onRefresh: refreshAdmin,
          onSelect: (id) => setState(() {
            sessionKey = id;
            tab = 0;
          }),
        );
      case 4:
        return _MemoryPage(
          memories: memories,
          onRefresh: refreshAdmin,
          onDelete: (id) async {
            await client.deleteMemory(id);
            await refreshAdmin();
          },
        );
      case 5:
        return _SettingsPage(
          baseUrl: baseUrl,
          token: token,
          onConnect: updateConnection,
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

// ——— Chat ———
class _ChatPage extends StatelessWidget {
  const _ChatPage({required this.chat, required this.sessionKey});
  final ChatController chat;
  final String sessionKey;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: chat,
      builder: (context, _) {
        return Column(
          children: [
            _TopBar(
              title: 'Chat',
              subtitle: sessionKey,
              online: chat.online,
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: chat.messages.length,
                itemBuilder: (context, i) {
                  final m = chat.messages[i];
                  final user = m['role'] == 'user';
                  return Align(
                    alignment:
                        user ? Alignment.centerRight : Alignment.centerLeft,
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
                        (m['text'] ?? '').toString(),
                        style: const TextStyle(height: 1.4),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (chat.pendingConfirm != null)
              Container(
                color: _panel,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Konfirmasi: ${chat.pendingConfirm!.prompt}',
                        style: const TextStyle(color: _warn),
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
            _Composer(onSend: (t) => chat.send(t, sessionKey: sessionKey)),
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
              onSubmitted: busy
                  ? null
                  : (v) async {
                      if (v.trim().isEmpty) return;
                      setState(() => busy = true);
                      await widget.onSend(v.trim());
                      c.clear();
                      setState(() => busy = false);
                    },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: busy
                ? null
                : () async {
                    final v = c.text.trim();
                    if (v.isEmpty) return;
                    setState(() => busy = true);
                    await widget.onSend(v);
                    c.clear();
                    setState(() => busy = false);
                  },
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
    required this.loading,
    required this.onRefresh,
    required this.onDecide,
  });

  final List<Map<String, dynamic>> approvals;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id, bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final pending =
        approvals.where((a) => a['state'] == 'pending').toList();
    final rest =
        approvals.where((a) => a['state'] != 'pending').toList();
    return Column(
      children: [
        _TopBar(
          title: 'Approvals',
          subtitle: '${pending.length} pending',
          online: true,
          trailing: IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (pending.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Tidak ada permintaan izin.',
                      style: TextStyle(color: _muted)),
                ),
              ...pending.map((a) => Card(
                    color: _panel,
                    child: ListTile(
                      title: Text('${a['tool']} · ${a['risk']}'),
                      subtitle: Text(
                        '${a['id']}\n${a['args']}\n${a['created_at'] ?? ''}',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Approve',
                            onPressed: () => onDecide('${a['id']}', true),
                            icon: const Icon(Icons.check_circle,
                                color: _accent),
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
                  child: Text('Riwayat',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                ...rest.take(30).map((a) => ListTile(
                      dense: true,
                      title: Text('${a['state']} · ${a['tool']}'),
                      subtitle: Text('${a['id']} · ${a['actor'] ?? ''}'),
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
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> sessions;
  final String current;
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
          online: true,
          trailing: IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Text('Belum ada sesi.',
                      style: TextStyle(color: _muted)))
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    final id = '${s['id']}';
                    return ListTile(
                      selected: id == current,
                      leading: const Icon(Icons.forum_outlined),
                      title: Text(id),
                      subtitle: Text(
                        '${s['channel'] ?? ''} · ${s['updated_at'] ?? ''} · turns=${s['turns'] ?? ''}',
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
    required this.onRefresh,
    required this.onDelete,
  });
  final List<Map<String, dynamic>> memories;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          title: 'Memory',
          subtitle: '${memories.length} fakta',
          online: true,
          trailing: IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
        Expanded(
          child: memories.isEmpty
              ? const Center(
                  child: Text('Kosong', style: TextStyle(color: _muted)))
              : ListView.builder(
                  itemCount: memories.length,
                  itemBuilder: (context, i) {
                    final m = memories[i];
                    return ListTile(
                      title: Text('${m['text'] ?? m}'),
                      subtitle: Text('${m['id']} · ${m['kind'] ?? ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => onDelete('${m['id']}'),
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
    required this.onConnect,
  });
  final String baseUrl;
  final String token;
  final void Function({required String base, required String tok}) onConnect;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final baseC = TextEditingController(text: widget.baseUrl);
  late final tokC = TextEditingController(text: widget.token);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _TopBar(title: 'Settings', subtitle: 'API', online: true),
        TextField(
          controller: baseC,
          decoration: const InputDecoration(
            labelText: 'API base URL',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: tokC,
          decoration: const InputDecoration(
            labelText: 'Bearer token',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onConnect(
            base: baseC.text.trim(),
            tok: tokC.text.trim(),
          ),
          child: const Text('Simpan & hubungkan'),
        ),
        const SizedBox(height: 24),
        const Text(
          'Pastikan daemon berjalan:\n'
          '  tiko daemon start\n'
          'Token tersimpan di data/api.token (permission POSIX 0600), bukan dicetak.\n'
          'Pindahkan nilainya secara aman ke kolom Bearer token.',
          style: TextStyle(color: _muted, height: 1.5),
        ),
      ],
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage({
    required this.client,
    required this.baseUrl,
    required this.token,
    required this.memories,
    required this.onRefresh,
    required this.onConnect,
    required this.onOpenMemory,
  });
  final AgentApiClient client;
  final String baseUrl;
  final String token;
  final List<Map<String, dynamic>> memories;
  final Future<void> Function() onRefresh;
  final void Function({required String base, required String tok}) onConnect;
  final VoidCallback onOpenMemory;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const _TopBar(title: 'More', subtitle: 'Memory & Settings', online: true),
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: Text('Memory (${memories.length})'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: _MemoryPage(
                  memories: memories,
                  onRefresh: onRefresh,
                  onDelete: (id) async {
                    await client.deleteMemory(id);
                    await onRefresh();
                  },
                ),
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
                body: _SettingsPage(
                  baseUrl: baseUrl,
                  token: token,
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: const TextStyle(color: _muted, fontSize: 12)),
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
    return Container(
      width: 280,
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
  }
}
