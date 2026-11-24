import 'package:flutter/material.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

import 'theme.dart';

/// Hermes S8: seksi surface A2UI dinamis untuk halaman GUI statik
/// (Tasks/Bots/Automation/Runs/Skills/Security).
///
/// Agen menandai surface milik halaman lewat konvensi prefix
/// `page.<target>.` pada surfaceId (contoh: `page.tasks.dashboard`), lalu
/// section ini merendernya inline via [A2uiSurfaceRecordView]. Aksi tombol
/// tetap melalui pipeline anti-replay host (`POST /v1/ui/actions`).
class A2uiPageSurfaceSection extends StatelessWidget {
  const A2uiPageSurfaceSection({
    super.key,
    required this.target,
    required this.surfaces,
    this.online = true,
    this.onRefresh,
    this.onOpenManager,
    this.onAction,
    this.onDelete,
    this.onLoadSurface,
  });

  /// Slug halaman target (`tasks`, `bots`, `automation`, `runs`, `skills`,
  /// `security`) — surface dengan surfaceId `page.<target>` atau prefix
  /// `page.<target>.` ikut ditampilkan.
  final String target;

  /// Snapshot daftar surface (`GET /v1/surfaces`); null = belum dimuat.
  final List<Map<String, dynamic>>? surfaces;

  final bool online;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenManager;
  final void Function(
    String surfaceId,
    String actionName,
    Map<String, dynamic> payload,
    String sessionKey,
  )? onAction;
  final Future<bool> Function(String surfaceId)? onDelete;
  final Future<Map<String, dynamic>?> Function(String surfaceId)?
      onLoadSurface;

  /// Konvensi binding surface → halaman: `page.<target>` persis atau prefix
  /// `page.<target>.` (case-insensitive agar banding dengan id statis).
  static bool surfaceTargetsPage(String surfaceId, String target) {
    final id = surfaceId.trim().toLowerCase();
    final prefix = 'page.${target.trim().toLowerCase()}';
    return id.isNotEmpty && (id == prefix || id.startsWith('$prefix.'));
  }

  List<Map<String, dynamic>> _matches() {
    final list = surfaces;
    if (list == null) return const [];
    return [
      for (final s in list)
        if (surfaceTargetsPage('${s['surfaceId'] ?? ''}', target)) s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (surfaces == null) return const SizedBox.shrink();
    final matches = _matches();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.simpulSurfaceHover,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.simpulMuted.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.web_asset_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'UI dinamis agent (A2UI) · ${matches.length} surface',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onRefresh != null)
                IconButton(
                  key: const Key('btn-page-surface-refresh'),
                  tooltip: 'Muat ulang surface A2UI',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              if (onOpenManager != null)
                TextButton(
                  key: const Key('btn-page-surface-manager'),
                  onPressed: onOpenManager,
                  child: const Text('Kelola', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          for (final s in matches)
            _PageSurfaceTile(
              record: s,
              online: online,
              onAction: onAction,
              onDelete: onDelete,
              onLoadSurface: onLoadSurface,
            ),
        ],
      ),
    );
  }
}

class _PageSurfaceTile extends StatefulWidget {
  const _PageSurfaceTile({
    required this.record,
    required this.online,
    this.onAction,
    this.onDelete,
    this.onLoadSurface,
  });

  final Map<String, dynamic> record;
  final bool online;
  final void Function(
    String surfaceId,
    String actionName,
    Map<String, dynamic> payload,
    String sessionKey,
  )? onAction;
  final Future<bool> Function(String surfaceId)? onDelete;
  final Future<Map<String, dynamic>?> Function(String surfaceId)?
      onLoadSurface;

  @override
  State<_PageSurfaceTile> createState() => _PageSurfaceTileState();
}

class _PageSurfaceTileState extends State<_PageSurfaceTile> {
  Map<String, dynamic>? record;
  String? error;
  bool _loaded = false;

  String get _surfaceId => '${widget.record['surfaceId'] ?? ''}';
  String get _sessionKey => '${widget.record['sessionKey'] ?? ''}';

  Future<void> _load() async {
    final loader = widget.onLoadSurface;
    if (loader == null) return;
    try {
      final body = await loader(_surfaceId);
      if (!mounted) return;
      if (body == null) {
        setState(() => error = 'surface tidak ditemukan');
        return;
      }
      setState(() {
        record = _toViewRecord(body);
        error = null;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Map<String, dynamic> _toViewRecord(Map<String, dynamic> body) {
    final inner = body['body'];
    if (inner is Map<String, dynamic>) {
      return {
        for (final entry in inner.entries) entry.key.toString(): entry.value,
      };
    }
    return {
      for (final entry in body.entries) entry.key.toString(): entry.value,
    };
  }

  Future<void> _confirmDelete() async {
    final deleter = widget.onDelete;
    if (deleter == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus surface?'),
        content: Text('$_surfaceId akan dihapus dari halaman ini.'),
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
    if (ok == true) await deleter(_surfaceId);
  }

  @override
  Widget build(BuildContext context) {
    final updated = widget.record['updatedAt']?.toString() ?? '';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey('page-surface-$_surfaceId'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          title: Text(
            _surfaceId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            _sessionKey.isEmpty ? updated : '$_sessionKey · $updated',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: context.simpulMuted),
          ),
          onExpansionChanged: (open) {
            if (open && !_loaded && record == null && error == null) {
              _load();
            }
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onDelete != null)
                IconButton(
                  key: Key('btn-page-surface-delete-$_surfaceId'),
                  tooltip: 'Hapus surface',
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: context.simpulDanger),
                  onPressed: _confirmDelete,
                ),
              const Icon(Icons.expand_more),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _surfacePreview(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _surfacePreview() {
    if (error != null) {
      return Text(
        'Gagal memuat surface: $error',
        style: TextStyle(fontSize: 12, color: context.simpulDanger),
      );
    }
    final rec = record;
    if (rec == null) {
      return Text(
        'Memuat surface…',
        style: TextStyle(fontSize: 12, color: context.simpulMuted),
      );
    }
    return A2uiSurfaceRecordView(
      key: PageStorageKey('page-surface-view-$_surfaceId'),
      record: rec,
      onAction: widget.onAction == null
          ? null
          : (surfaceId, actionName, payload) =>
              widget.onAction!(surfaceId, actionName, payload, _sessionKey),
    );
  }
}
