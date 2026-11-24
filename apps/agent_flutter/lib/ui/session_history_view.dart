import 'package:flutter/material.dart';

import '../data/models.dart';
import 'page_header.dart';
import 'theme.dart';

/// Human-first session history. Technical session IDs stay secondary so a
/// new user can recognize a conversation by title and recency first.
class SessionHistoryView extends StatefulWidget {
  const SessionHistoryView({
    super.key,
    required this.sessions,
    required this.current,
    required this.online,
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    this.error,
    this.embedded = false,
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
  final bool embedded;

  @override
  State<SessionHistoryView> createState() => _SessionHistoryViewState();
}

class _SessionHistoryViewState extends State<SessionHistoryView> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final filtered = widget.sessions.where((session) {
      if (query.isEmpty) return true;
      return session.displayTitle.toLowerCase().contains(query) ||
          session.channel.toLowerCase().contains(query) ||
          session.id.toLowerCase().contains(query);
    }).toList();
    final content = Column(
      children: [
        if (!widget.embedded)
          PageHeader(
            title: 'History',
            subtitle: '${widget.sessions.length} percakapan tersimpan',
            online: widget.online,
            trailing: IconButton(
              tooltip: 'Muat ulang history',
              onPressed: widget.onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            widget.embedded ? 12 : 20,
            widget.embedded ? 10 : 16,
            widget.embedded ? 12 : 20,
            8,
          ),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Cari percakapan…',
              isDense: true,
            ),
          ),
        ),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.error!,
              style: TextStyle(color: context.simpulDanger),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? _EmptyHistory(query: query)
              : ListView(
                  padding: EdgeInsets.fromLTRB(
                    widget.embedded ? 8 : 12,
                    4,
                    widget.embedded ? 8 : 12,
                    20,
                  ),
                  children: [
                    _group(context, 'Terbaru', filtered.take(8).toList()),
                    if (filtered.length > 8)
                      _group(context, 'Sebelumnya', filtered.skip(8).toList()),
                  ],
                ),
        ),
      ],
    );
    return content;
  }

  Widget _group(
    BuildContext context,
    String label,
    List<SessionSummary> sessions,
  ) {
    if (sessions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 5),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: context.simpulMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        for (final session in sessions)
          _HistoryTile(
            session: session,
            selected: session.id == widget.current,
            onTap: () => widget.onSelect(session.id),
            onRename: () => _rename(context, session),
            onDelete: () => _delete(context, session),
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, SessionSummary session) async {
    final controller = TextEditingController(text: session.displayTitle);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Beri nama percakapan'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Contoh: Riset produk'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != session.displayTitle) {
      await widget.onRename(session.id, trimmed);
    }
    controller.dispose();
  }

  Future<void> _delete(BuildContext context, SessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus percakapan?'),
        content: Text('"${session.displayTitle}" akan dihapus dari history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onDelete(session.id);
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SessionSummary session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = session.title.trim().isEmpty || session.title == session.id
        ? 'Percakapan tanpa judul'
        : session.title.trim();
    final channel = session.channel.trim().isEmpty ? 'lokal' : session.channel;
    return ListTile(
      selected: selected,
      selectedTileColor: context.simpulSurfaceSelected,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: context.simpulSurfaceRaised,
        child: Icon(
          Icons.chat_bubble_outline,
          size: 17,
          color: context.simpulMuted,
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${sessionAgeLabel(session.updatedAt)} · $channel · ${session.turns} turn',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.simpulMuted, fontSize: 11),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Opsi percakapan',
        onSelected: (action) {
          if (action == 'rename') onRename();
          if (action == 'delete') onDelete();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('Beri nama')),
          PopupMenuItem(value: 'delete', child: Text('Hapus')),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: context.simpulMuted),
          const SizedBox(height: 12),
          Text(
            query.isEmpty ? 'Belum ada percakapan' : 'Tidak ditemukan',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            query.isEmpty
                ? 'Mulai chat baru untuk melihatnya di sini.'
                : 'Coba kata kunci lain.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.simpulMuted),
          ),
        ],
      ),
    ),
  );
}

String sessionAgeLabel(String raw) {
  final parsed = DateTime.tryParse(raw)?.toLocal();
  if (parsed == null) return 'Waktu tidak diketahui';
  final delta = DateTime.now().difference(parsed);
  if (delta.isNegative || delta.inMinutes < 1) return 'Baru saja';
  if (delta.inHours < 1) return '${delta.inMinutes} m lalu';
  if (delta.inDays < 1) return '${delta.inHours} j lalu';
  if (delta.inDays < 7) return '${delta.inDays} hari lalu';
  return '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
}
