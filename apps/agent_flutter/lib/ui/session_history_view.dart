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
    this.onTogglePin,
    this.onToggleArchive,
    this.onDuplicate,
    this.onExport,
    this.onBulkDelete,
    this.onNewChat,
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
  final Future<void> Function(String id, bool pinned)? onTogglePin;
  final Future<void> Function(String id, bool archived)? onToggleArchive;
  final Future<void> Function(String id)? onDuplicate;
  final Future<void> Function(String id, String format)? onExport;
  final Future<void> Function(List<String> ids)? onBulkDelete;
  final VoidCallback? onNewChat;
  final bool embedded;

  @override
  State<SessionHistoryView> createState() => _SessionHistoryViewState();
}

class _SessionHistoryViewState extends State<SessionHistoryView> {
  final search = TextEditingController();
  String viewFilter = 'all';
  String? channelFilter;
  String? metaFilter;
  bool selecting = false;
  final selectedIds = <String>{};

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Iterable<SessionSummary> get _visibleSessions {
    return widget.sessions.where((session) {
      if (viewFilter == 'pinned' && (!session.pinned || session.archived)) {
        return false;
      }
      if (viewFilter == 'archived' && !session.archived) return false;
      if (viewFilter == 'all' && session.archived) return false;
      if (channelFilter != null && session.channel != channelFilter) {
        return false;
      }
      if (metaFilter != null && _metaKey(session) != metaFilter) return false;
      return true;
    });
  }

  List<SessionSummary> get _filtered {
    final query = search.text.trim().toLowerCase();
    final result = _visibleSessions.where((session) {
      if (query.isEmpty) return true;
      return session.displayTitle.toLowerCase().contains(query) ||
          session.channel.toLowerCase().contains(query) ||
          session.id.toLowerCase().contains(query);
    }).toList()..sort(_compareSessions);
    return result;
  }

  List<String> get _channelOptions {
    final seen = <String>{};
    for (final session in widget.sessions) {
      if (session.channel.trim().isNotEmpty) seen.add(session.channel);
    }
    return seen.toList()..sort();
  }

  List<String> get _metaOptions {
    final seen = <String>{};
    for (final session in widget.sessions) {
      final key = _metaKey(session);
      if (key != null) seen.add(key);
    }
    return seen.toList()..sort();
  }

  String? _metaKey(SessionSummary session) {
    final provider = session.provider.trim();
    final model = session.model.trim();
    if (provider.isEmpty && model.isEmpty) return null;
    if (provider.isEmpty) return 'model · $model';
    if (model.isEmpty || model == provider) return provider;
    return '$provider · $model';
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final filtered = _filtered;
    final grouped = <String, List<SessionSummary>>{};
    for (final session in filtered) {
      grouped
          .putIfAbsent(
            _groupLabelFor(session),
            () => [],
          )
          .add(session);
    }
    final selectingNow = selecting && widget.onBulkDelete != null;
    if (selectingNow && viewFilter != 'all') {
      viewFilter = 'all';
    }
    if (selectingNow && (channelFilter != null || metaFilter != null)) {
      channelFilter = null;
      metaFilter = null;
    }
    final content = Column(
      children: [
        if (!widget.embedded)
          PageHeader(
            title: selectingNow ? '${selectedIds.length} dipilih' : 'History',
            subtitle: selectingNow
                ? '${filtered.length} percakapan terlihat'
                : '${widget.sessions.length} percakapan tersimpan',
            online: widget.online,
            trailing: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.onBulkDelete != null)
                  IconButton(
                    key: const Key('btn-history-select'),
                    tooltip: selectingNow
                        ? 'Batal pilih'
                        : 'Pilih percakapan',
                    onPressed: () => setState(() {
                      selecting = !selecting;
                      selectedIds.clear();
                    }),
                    icon: Icon(
                      selectingNow ? Icons.close : Icons.checklist,
                    ),
                  ),
                if (selectingNow && selectedIds.isNotEmpty)
                  IconButton(
                    key: const Key('btn-history-bulk-delete'),
                    tooltip: 'Hapus yang dipilih',
                    onPressed: () => _confirmBulkDelete(context),
                    icon: Icon(
                      Icons.delete_sweep,
                      color: context.simpulDanger,
                    ),
                  ),
                if (widget.onNewChat != null && !selectingNow)
                  FilledButton.icon(
                    key: const Key('btn-history-new-chat'),
                    onPressed: widget.onNewChat,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Chat baru'),
                  ),
                IconButton(
                  tooltip: 'Muat ulang history',
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
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
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Cari percakapan…',
              isDense: true,
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Hapus pencarian',
                      onPressed: () {
                        search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        _FilterBar(
          embedded: widget.embedded,
          viewFilter: viewFilter,
          channelFilter: channelFilter,
          metaFilter: metaFilter,
          channels: _channelOptions,
          metas: _metaOptions,
          enabled: !selectingNow,
          onViewChanged: (value) => setState(() => viewFilter = value),
          onChannelChanged: (value) => setState(() => channelFilter = value),
          onMetaChanged: (value) => setState(() => metaFilter = value),
        ),
        if (query.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(
                '${filtered.length} hasil untuk “${search.text.trim()}”',
                style: TextStyle(color: context.simpulMuted, fontSize: 12),
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
                    for (final entry in grouped.entries)
                      _group(context, entry.key, entry.value),
                  ],
                ),
        ),
      ],
    );
    return content;
  }

  String _groupLabelFor(SessionSummary session) {
    if (!session.archived && session.pinned && viewFilter == 'all') {
      return 'Disematkan';
    }
    return _sessionGroupLabel(session.updatedAt);
  }

  int _compareSessions(SessionSummary a, SessionSummary b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final aDate = DateTime.tryParse(a.updatedAt);
    final bDate = DateTime.tryParse(b.updatedAt);
    if (aDate == null && bDate == null) return 0;
    if (aDate == null) return 1;
    if (bDate == null) return -1;
    return bDate.compareTo(aDate);
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
            selected: !selecting && session.id == widget.current,
            checking: selecting && selectedIds.contains(session.id),
            selectionMode: selecting,
            onTap: () => selecting
                ? _toggleSelect(session.id)
                : widget.onSelect(session.id),
            onRename: () => _rename(context, session),
            onDelete: () => _delete(context, session),
            onTogglePin: widget.onTogglePin == null
                ? null
                : () => widget.onTogglePin!(session.id, !session.pinned),
            onToggleArchive: widget.onToggleArchive == null
                ? null
                : () => widget.onToggleArchive!(session.id, !session.archived),
            onDuplicate: widget.onDuplicate == null
                ? null
                : () => widget.onDuplicate!(session.id),
            onExport: widget.onExport == null
                ? null
                : (format) => widget.onExport!(session.id, format),
            onLongPress: widget.onBulkDelete == null
                ? null
                : () => _toggleSelect(session.id),
          ),
      ],
    );
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!selectedIds.remove(id)) selectedIds.add(id);
    });
  }

  Future<void> _confirmBulkDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus ${selectedIds.length} percakapan?'),
        content: const Text(
          'Percakapan yang dipilih akan dihapus permanen dari history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            key: const Key('btn-history-bulk-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onBulkDelete?.call(selectedIds.toList());
      if (mounted) {
        setState(() {
          selecting = false;
          selectedIds.clear();
        });
      }
    }
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

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.embedded,
    required this.viewFilter,
    required this.channelFilter,
    required this.metaFilter,
    required this.channels,
    required this.metas,
    required this.enabled,
    required this.onViewChanged,
    required this.onChannelChanged,
    required this.onMetaChanged,
  });

  final bool embedded;
  final String viewFilter;
  final String? channelFilter;
  final String? metaFilter;
  final List<String> channels;
  final List<String> metas;
  final bool enabled;
  final void Function(String value) onViewChanged;
  final void Function(String? value) onChannelChanged;
  final void Function(String? value) onMetaChanged;

  @override
  Widget build(BuildContext context) {
    final hasFilters = channelFilter != null || metaFilter != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(embedded ? 12.0 : 20.0, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            key: const Key('chip-history-view-all'),
            label: const Text('Semua'),
            selected: viewFilter == 'all',
            onSelected: enabled ? (_) => onViewChanged('all') : null,
          ),
          ChoiceChip(
            key: const Key('chip-history-view-pinned'),
            label: const Text('Disematkan'),
            selected: viewFilter == 'pinned',
            onSelected: enabled ? (_) => onViewChanged('pinned') : null,
          ),
          ChoiceChip(
            key: const Key('chip-history-view-archived'),
            label: const Text('Arsip'),
            selected: viewFilter == 'archived',
            onSelected: enabled ? (_) => onViewChanged('archived') : null,
          ),
          if (channels.isNotEmpty)
            _DropdownFilter(
              width: 190,
              filterKey: 'filter-history-channel',
              value: channelFilter,
              allLabel: 'Semua channel',
              options: [
                for (final channel in channels) (value: channel, label: channel),
              ],
              enabled: enabled,
              onChanged: onChannelChanged,
            ),
          if (metas.isNotEmpty)
            _DropdownFilter(
              width: 210,
              filterKey: 'filter-history-meta',
              value: metaFilter,
              allLabel: 'Semua provider/model',
              options: [for (final meta in metas) (value: meta, label: meta)],
              enabled: enabled,
              onChanged: onMetaChanged,
            ),
          if (hasFilters)
            TextButton.icon(
              onPressed: enabled
                  ? () {
                      onChannelChanged(null);
                      onMetaChanged(null);
                    }
                  : null,
              icon: const Icon(Icons.filter_alt_off, size: 16),
              label: const Text('Reset filter'),
            ),
        ],
      ),
    );
  }
}

class _DropdownFilter extends StatelessWidget {
  const _DropdownFilter({
    required this.width,
    required this.filterKey,
    required this.value,
    required this.allLabel,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final double width;
  final String filterKey;
  final String? value;
  final String allLabel;
  final List<({String value, String label})> options;
  final bool enabled;
  final void Function(String? value) onChanged;

  String get _label {
    for (final option in options) {
      if (option.value == value) return option.label;
    }
    return allLabel;
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border.all(color: context.simpulBorder),
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DropdownButton<String>(
        key: Key(filterKey),
        value: label == allLabel ? null : label,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        icon: Icon(Icons.keyboard_arrow_down, size: 18,
            color: context.simpulMuted),
        hint: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.simpulMuted, fontSize: 12),
        ),
        items: [
          DropdownMenuItem(value: null, child: Text(allLabel, style: TextStyle(color: context.simpulMuted, fontSize: 12))),
          for (final option in options)
            DropdownMenuItem(value: option.value, child: Text(option.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.session,
    required this.selected,
    required this.checking,
    required this.selectionMode,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    this.onTogglePin,
    this.onToggleArchive,
    this.onDuplicate,
    this.onExport,
    this.onLongPress,
  });

  final SessionSummary session;
  final bool selected;
  final bool checking;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onTogglePin;
  final VoidCallback? onToggleArchive;
  final VoidCallback? onDuplicate;
  final void Function(String format)? onExport;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final title = session.title.trim().isEmpty || session.title == session.id
        ? 'Percakapan tanpa judul'
        : session.title.trim();
    final channel = session.channel.trim().isEmpty ? 'lokal' : session.channel;
    final statusParts = <String>[];
    if (selected && !selectionMode) statusParts.add('Aktif');
    if (session.lastFailed) statusParts.add('gagal');
    final meta = session.model.trim().isEmpty
        ? session.provider.trim()
        : '${session.provider.trim()} · ${session.model.trim()}';
    final subtitleParts = <String>[
      if (statusParts.isNotEmpty) statusParts.join(' · '),
      sessionAgeLabel(session.updatedAt),
      channel,
      '${session.turns} turn',
      if (meta.isNotEmpty) meta,
    ];
    return Semantics(
      selected: selected || checking,
      button: true,
      label: selected ? '$title, sesi aktif' : title,
      child: ListTile(
        selected: selected,
        selectedTileColor: context.simpulSurfaceSelected,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: selectionMode
            ? Checkbox(
                key: Key('history-check-${session.id}'),
                value: checking,
                onChanged: (_) => onTap(),
              )
            : CircleAvatar(
                radius: 17,
                backgroundColor: session.lastFailed
                    ? context.simpulDanger.withValues(alpha: 0.15)
                    : context.simpulSurfaceRaised,
                child: Icon(
                  session.lastFailed
                      ? Icons.error_outline
                      : Icons.chat_bubble_outline,
                  size: 17,
                  color: session.lastFailed
                      ? context.simpulDanger
                      : context.simpulMuted,
                ),
              ),
        title: Row(
          children: [
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (session.pinned && !selectionMode)
              Icon(
                Icons.push_pin,
                size: 14,
                color: context.simpulWarn,
              ),
          ],
        ),
        subtitle: Text(
          subtitleParts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: session.lastFailed
                ? context.simpulDanger
                : context.simpulMuted,
            fontSize: 11,
          ),
        ),
        trailing: selectionMode
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Opsi percakapan',
                onSelected: (action) {
                  switch (action) {
                    case 'rename':
                      onRename();
                    case 'delete':
                      onDelete();
                    case 'toggle_pin':
                      onTogglePin?.call();
                    case 'toggle_archive':
                      onToggleArchive?.call();
                    case 'duplicate':
                      onDuplicate?.call();
                    case 'export_md':
                      onExport?.call('md');
                    case 'export_json':
                      onExport?.call('json');
                    case 'export_txt':
                      onExport?.call('txt');
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'rename', child: Text('Beri nama')),
                  if (onTogglePin != null)
                    PopupMenuItem(
                      value: 'toggle_pin',
                      child: Text(session.pinned
                          ? 'Lepas sematan'
                          : 'Sematkan (pin)'),
                    ),
                  if (onToggleArchive != null)
                    PopupMenuItem(
                      value: 'toggle_archive',
                      child: Text(session.archived
                          ? 'Keluarkan dari arsip'
                          : 'Arsipkan'),
                    ),
                  if (onDuplicate != null)
                    const PopupMenuItem(
                      value: 'duplicate',
                      child: Text('Duplikat fork'),
                    ),
                  if (onExport != null) ...[
                    const PopupMenuItem(
                      value: 'export_md',
                      child: Text('Ekspor Markdown'),
                    ),
                    const PopupMenuItem(
                      value: 'export_json',
                      child: Text('Ekspor JSON'),
                    ),
                    const PopupMenuItem(
                      value: 'export_txt',
                      child: Text('Ekspor teks'),
                    ),
                  ],
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'delete', child: Text('Hapus')),
                ],
              ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
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

String _sessionGroupLabel(String raw) {
  final parsed = DateTime.tryParse(raw)?.toLocal();
  if (parsed == null) return 'Tanpa tanggal';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(parsed.year, parsed.month, parsed.day);
  final days = today.difference(date).inDays;
  if (days <= 0) return 'Hari ini';
  if (days == 1) return 'Kemarin';
  if (days < 7) return 'Minggu ini';
  return 'Lebih lama';
}
