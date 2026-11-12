#!/usr/bin/env python3
"""Apply reviewed Flutter UI fixes to the Tiko-Agent repository checkout.

Run from the repository root:
    python3 scripts/apply_flutter_ui_repairs.py
The script is intentionally fail-closed: it aborts if the expected source
snippets do not match exactly, and writes backups before replacing files.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path.cwd()
MAIN = ROOT / "apps/agent_flutter/lib/main.dart"
CLIENT = ROOT / "apps/agent_flutter/lib/agent_api_client.dart"
CI = ROOT / ".github/workflows/ci.yml"
WIDGET_TEST = ROOT / "apps/agent_flutter/test/widget_test.dart"
FLUTTER_WEB_INDEX = ROOT / "apps/agent_flutter/web/index.html"
FLUTTER_WEB_MANIFEST = ROOT / "apps/agent_flutter/web/manifest.json"


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}; no files were changed")
    return source.replace(old, new, 1)


def replace_region(source: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, lambda _: replacement, source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one region, found {count}; no files were changed")
    return updated


def build_main(source: str) -> str:
    source = replace_once(
        source,
        "      if (tab == 1 || tab == 2) unawaited(refreshAdmin());\n",
        "      if (tab >= 1 && tab <= 4) unawaited(refreshAdmin());\n",
        "admin refresh for visible management tabs",
    )
    source = replace_once(
        source,
        "  bool loadingAdmin = false;\n  String? adminError;\n",
        "  bool loadingAdmin = false;\n  bool adminRefreshInFlight = false;\n  int adminRefreshGeneration = 0;\n  String? adminError;\n",
        "admin refresh lock",
    )

    source = replace_region(
        source,
        r"  Future<void> refreshAdmin\(\) async \{.*?\n  \}\n\n  void updateConnection",
        '''  Future<void> refreshAdmin({bool force = false}) async {
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

  void updateConnection''',
        "parallel admin refresh",
    )
    source = replace_once(
        source,
        "    unawaited(refreshAdmin());\n  }\n\n  @override\n  void dispose()",
        "    unawaited(refreshAdmin(force: true));\n  }\n\n  @override\n  void dispose()",
        "force refresh after connection change",
    )
    source = replace_once(
        source,
        "          onSelect: (id) => setState(() {\n            sessionKey = id;\n            tab = 0;\n          }),",
        "          onSelect: (id) => setState(() {\n            sessionKey = id;\n            chat.clearChat();\n            tab = 0;\n          }),",
        "clear stale chat when switching sessions",
    )

    source = replace_once(
        source,
        "                  Expanded(child: _body(wide: true)),\n",
        "                  Expanded(\n                    child: AnimatedBuilder(\n                      animation: chat,\n                      builder: (context, _) => _body(wide: true),\n                    ),\n                  ),\n",
        "wide body connection-state rebuild",
    )
    source = replace_once(
        source,
        "                  Expanded(child: _body(wide: false)),\n",
        "                  Expanded(\n                    child: AnimatedBuilder(\n                      animation: chat,\n                      builder: (context, _) => _body(wide: false),\n                    ),\n                  ),\n",
        "compact body connection-state rebuild",
    )

    source = replace_once(
        source,
        '''      return _MorePage(
        client: client,
        baseUrl: baseUrl,
        token: token,
        memories: memories,
        onRefresh: refreshAdmin,
        onConnect: updateConnection,
        onOpenMemory: () => setState(() => tab = 4),
      );''',
        '''      return _MorePage(
        client: client,
        baseUrl: baseUrl,
        token: token,
        memories: memories,
        online: chat.online,
        onRefresh: refreshAdmin,
        onConnect: updateConnection,
      );''',
        "compact More page connection state",
    )
    source = replace_once(
        source,
        '''        return _ApprovalsPage(
          approvals: approvals,
          loading: loadingAdmin,''',
        '''        return _ApprovalsPage(
          approvals: approvals,
          online: chat.online,
          loading: loadingAdmin,''',
        "approvals connection state",
    )
    source = replace_once(
        source,
        '''        return _SessionsPage(
          sessions: sessions,
          current: sessionKey,''',
        '''        return _SessionsPage(
          sessions: sessions,
          current: sessionKey,
          online: chat.online,''',
        "sessions connection state",
    )
    source = replace_once(
        source,
        '''        return _MemoryPage(
          memories: memories,
          onRefresh: refreshAdmin,
          onDelete: (id) async {
            await client.deleteMemory(id);
            await refreshAdmin();
          },
        );''',
        '''        return _MemoryPage(
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
        );''',
        "memory deletion feedback",
    )
    source = replace_once(
        source,
        '''        return _SettingsPage(
          baseUrl: baseUrl,
          token: token,
          onConnect: updateConnection,
        );''',
        '''        return _SettingsPage(
          baseUrl: baseUrl,
          token: token,
          online: chat.online,
          onConnect: updateConnection,
        );''',
        "settings connection state",
    )

    source = replace_region(
        source,
        r"// ——— Chat ———\nclass _ChatPage extends StatelessWidget \{.*?\n// ——— Dashboard ———",
        '''// ——— Chat ———
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

// ——— Dashboard ———''',
        "chat and composer lifecycle/scroll region",
    )

    source = replace_region(
        source,
        r"// ——— Approvals ———\nclass _ApprovalsPage extends StatelessWidget \{.*?\n// ——— Sessions ———",
        '''// ——— Approvals ———
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
                        '${a['id']}\\n${a['args']}\\n${a['created_at'] ?? ''}',
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

// ——— Sessions ———''',
        "approval page responsive layout and connection state",
    )

    source = replace_region(
        source,
        r"// ——— Sessions ———\nclass _SessionsPage extends StatelessWidget \{.*?\n// ——— Memory ———",
        '''// ——— Sessions ———
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

// ——— Memory ———''',
        "sessions page responsive layout and connection state",
    )

    source = replace_region(
        source,
        r"// ——— Memory ———\nclass _MemoryPage extends StatelessWidget \{.*?\n// ——— Settings ———",
        '''// ——— Memory ———
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

// ——— Settings ———''',
        "memory page feedback and delete confirmation",
    )

    source = replace_region(
        source,
        r"// ——— Settings ———\nclass _SettingsPage extends StatefulWidget \{.*?\nclass _MorePage extends StatelessWidget",
        '''// ——— Settings ———
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
        const Text(
          'Pastikan daemon berjalan dengan perintah tiko daemon start. Token berada di data/api.token (permission POSIX 0600); pindahkan nilainya secara aman ke kolom Bearer token.',
          style: TextStyle(color: _muted, height: 1.5),
        ),
      ],
    );
  }
}

class _MorePage extends StatelessWidget''',
        "settings validation and controller lifecycle",
    )

    source = replace_region(
        source,
        r"class _MorePage extends StatelessWidget \{.*?\nclass _TopBar extends StatelessWidget",
        '''class _MorePage extends StatelessWidget {
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

class _TopBar extends StatelessWidget''',
        "More page mobile routes",
    )

    source = replace_once(
        source,
        '''      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,''',
        '''      child: Row(
        children: [
          if (Navigator.of(context).canPop())
            IconButton(
              tooltip: 'Kembali',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,''',
        "topbar back navigation",
    )
    source = replace_once(
        source,
        '''                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: const TextStyle(color: _muted, fontSize: 12)),''',
        '''                Text(
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
                ),''',
        "topbar long-title overflow",
    )
    source = replace_region(
        source,
        r"class _Card extends StatelessWidget \{.*?\n\}\n$",
        '''class _Card extends StatelessWidget {
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
''',
        "dashboard card adaptive width",
    )
    return source


def build_client(source: str) -> str:
    source = replace_once(
        source,
        "    final res = await _http.delete(_u('/v1/memories/$id'), headers: _headers);",
        "    final safeId = Uri.encodeComponent(id);\n    final res = await _http.delete(_u('/v1/memories/$safeId'), headers: _headers)\n        .timeout(const Duration(seconds: 10));",
        "memory ID URL encoding and timeout",
    )
    source = replace_region(
        source,
        r"  Stream<Map<String, dynamic>> streamChat\(.*?\n  \}\n\n  void _throwIf",
        '''  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
  }) async* {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final wsBase = base.startsWith('https')
        ? base.replaceFirst('https', 'wss')
        : base.replaceFirst('http', 'ws');
    // QueryParameters performs correct escaping for tokens containing +, &, etc.
    final uri = Uri.parse('$wsBase/v1/stream').replace(
      queryParameters: {'token': token},
    );
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(jsonEncode({
        'text': text,
        'session_key': sessionKey,
        'user_key': 'flutter',
      }));
      await for (final raw in channel.stream.timeout(const Duration(seconds: 180))) {
        if (raw is String) {
          yield Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } else {
          yield <String, dynamic>{'type': 'error', 'message': 'bad frame'};
        }
      }
    } finally {
      await channel.sink.close();
    }
  }

  void _throwIf''',
        "WebSocket lifecycle and token escaping",
    )
    return source


def build_ci(source: str) -> str:
    return replace_once(
        source,
        "      - name: Validate shell and Python scripts\n",
        "      - name: Web UI syntax and interaction tests\n        run: bash scripts/web_ui_validate.sh\n      - name: Validate shell and Python scripts\n",
        "web UI CI gate",
    )


def build_widget_test(source: str) -> str:
    source = replace_once(
        source,
        "import 'package:flutter_test/flutter_test.dart';\n",
        "import 'package:flutter/material.dart';\nimport 'package:flutter_test/flutter_test.dart';\n",
        "widget test Material import",
    )
    return replace_once(
        source,
        "  });\n}\n",
        """  });

  testWidgets('Agent app uses NavigationRail on wide screens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
""",
        "wide layout widget regression test",
    )



def build_flutter_web_index(source: str) -> str:
    source = replace_once(
        source,
        '<meta name="description" content="A new Flutter project.">',
        '<meta name="description" content="Tiko — asisten AI pribadi dengan chat, memori, dan kontrol runtime.">',
        "Flutter web description",
    )
    source = replace_once(
        source,
        '<meta name="apple-mobile-web-app-title" content="agent_flutter">',
        '<meta name="apple-mobile-web-app-title" content="Tiko">',
        "Flutter web app title",
    )
    return replace_once(source, '<title>agent_flutter</title>', '<title>Tiko</title>', "Flutter web document title")


def build_flutter_web_manifest(source: str) -> str:
    source = replace_once(source, '"name": "agent_flutter"', '"name": "Tiko Agent"', "Flutter web manifest name")
    source = replace_once(source, '"short_name": "agent_flutter"', '"short_name": "Tiko"', "Flutter web manifest short name")
    source = replace_once(source, '"background_color": "#0175C2"', '"background_color": "#10151D"', "Flutter web manifest background")
    source = replace_once(source, '"theme_color": "#0175C2"', '"theme_color": "#21A996"', "Flutter web manifest theme")
    return replace_once(source, '"description": "A new Flutter project."', '"description": "Tiko — asisten AI pribadi dengan chat, memori, dan kontrol runtime."', "Flutter web manifest description")


def main() -> None:
    required = [
        MAIN, CLIENT, CI, WIDGET_TEST, FLUTTER_WEB_INDEX, FLUTTER_WEB_MANIFEST,
        ROOT / "scripts/web_ui_validate.sh",
    ]
    missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
    if missing:
        raise SystemExit("Missing expected files: " + ", ".join(missing) + ". Run from the Tiko-Agent repository root after copying the patch bundle.")

    originals = {
        MAIN: MAIN.read_text(encoding="utf-8"),
        CLIENT: CLIENT.read_text(encoding="utf-8"),
        CI: CI.read_text(encoding="utf-8"),
        WIDGET_TEST: WIDGET_TEST.read_text(encoding="utf-8"),
        FLUTTER_WEB_INDEX: FLUTTER_WEB_INDEX.read_text(encoding="utf-8"),
        FLUTTER_WEB_MANIFEST: FLUTTER_WEB_MANIFEST.read_text(encoding="utf-8"),
    }
    # Build all changes in memory first; never leave a partially patched checkout.
    updated = {
        MAIN: build_main(originals[MAIN]),
        CLIENT: build_client(originals[CLIENT]),
        CI: build_ci(originals[CI]),
        WIDGET_TEST: build_widget_test(originals[WIDGET_TEST]),
        FLUTTER_WEB_INDEX: build_flutter_web_index(originals[FLUTTER_WEB_INDEX]),
        FLUTTER_WEB_MANIFEST: build_flutter_web_manifest(originals[FLUTTER_WEB_MANIFEST]),
    }
    for path, content in updated.items():
        backup = path.with_suffix(path.suffix + ".pre-ui-repair.bak")
        if not backup.exists():
            backup.write_text(originals[path], encoding="utf-8")
        path.write_text(content, encoding="utf-8")
    print("PASS: Flutter UI, API client, Web metadata, responsive regression test, and CI gate patched.")
    print("Backups: *.pre-ui-repair.bak")
    print("Next: dart format apps/agent_flutter/lib apps/agent_flutter/test && bash scripts/web_ui_validate.sh && cd apps/agent_flutter && flutter analyze && flutter test")


if __name__ == "__main__":
    main()
