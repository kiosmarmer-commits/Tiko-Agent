import 'package:flutter/material.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

import '../ui/theme.dart';
import 'page_header.dart';

/// Halaman Surface A2UI (Fase E4): daftar snapshot surface tersimpan per
/// sesi (`GET /v1/surfaces`), detail yang dirender ulang dari record
/// (`GET /v1/surfaces/<id>`), dan penghapusan (`DELETE /v1/surfaces/<id>`).
class SurfacesPage extends StatelessWidget {
  const SurfacesPage({
    super.key,
    required this.surfaces,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onShowDetail,
    this.onDelete,
  });

  final List<Map<String, dynamic>>? surfaces;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;
  final Future<Map<String, dynamic>?> Function(String surfaceId)? onShowDetail;
  final Future<bool> Function(String surfaceId)? onDelete;

  @override
  Widget build(BuildContext context) {
    final list = surfaces;
    return Column(
      children: [
        PageHeader(
          title: 'Surface',
          subtitle: list == null
              ? 'UI generatif A2UI: perlu refresh untuk memuat'
              : '${list.length} surface tersimpan · fail-closed',
          online: online,
          trailing: onRefresh == null
              ? null
              : IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) StatusViews.loadingBanner(context),
        if (error != null)
            StatusViews.errorBanner(context, error!, onRetry: onRefresh),
        Expanded(
          child: list == null
              ? StatusViews.empty(context, message: 'Belum ada snapshot — tekan refresh.')
              : list.isEmpty
                  ? StatusViews.empty(context, message: 'Belum ada surface. Minta agent merender UI dengan tool render_a2ui.')
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        for (final s in list) _SurfaceTile(s: s, page: this),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _SurfaceTile extends StatelessWidget {
  const _SurfaceTile({required this.s, required this.page});

  final Map<String, dynamic> s;
  final SurfacesPage page;

  void _showDetail(BuildContext context) {
    final loader = page.onShowDetail;
    final id = s['surfaceId']?.toString() ?? '';
    if (loader == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (sheetContext, controller) => _SurfaceDetailSheet(
          surfaceId: id,
          loader: loader,
          scrollController: controller,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final deleter = page.onDelete;
    if (deleter == null) return;
    final id = s['surfaceId']?.toString() ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus surface?'),
        content: Text('$id beserta snapshot disk-nya akan dihapus.'),
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
    if (ok == true) await deleter(id);
  }

  @override
  Widget build(BuildContext context) {
    final id = s['surfaceId']?.toString() ?? '(tanpa id)';
    final updated = s['updatedAt']?.toString() ?? '';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.web_asset_outlined),
      title: Text(id, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${s['sessionKey'] ?? '-'}\n$updated', maxLines: 2),
      isThreeLine: true,
      onTap: () => _showDetail(context),
      trailing: IconButton(
        tooltip: 'Hapus surface',
        icon: Icon(Icons.delete_outline, color: context.simpulDanger),
        onPressed: () => _confirmDelete(context),
      ),
    );
  }
}

class _SurfaceDetailSheet extends StatefulWidget {
  const _SurfaceDetailSheet({
    required this.surfaceId,
    required this.loader,
    required this.scrollController,
  });

  final String surfaceId;
  final Future<Map<String, dynamic>?> Function(String surfaceId) loader;
  final ScrollController scrollController;

  @override
  State<_SurfaceDetailSheet> createState() => _SurfaceDetailSheetState();
}

class _SurfaceDetailSheetState extends State<_SurfaceDetailSheet> {
  Map<String, dynamic>? record;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => error = null);
    try {
      final doc = await widget.loader(widget.surfaceId);
      if (doc == null) {
        if (mounted) {
          setState(() => error = 'Surface "${widget.surfaceId}" tidak ditemukan.');
        }
        return;
      }
      if (mounted) setState(() => record = doc);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = record;
    final body = rec?['body'];
    final actions = body is Map ? body['components'] : null;
    Map<String, dynamic> viewRecord = const {};
    if (rec != null) {
      viewRecord = body is Map
          ? {
              for (final entry in body.entries) entry.key.toString(): entry.value,
              'sessionKey': rec['sessionKey'],
              'updatedAt': rec['updatedAt'],
            }
          : {
              for (final entry in rec.entries) entry.key.toString(): entry.value,
            };
    }
    final catalogId = body is Map ? body['catalogId'] ?? '-' : '-';
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Surface ${widget.surfaceId}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Muat ulang',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Tutup',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          )
        else if (rec == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          A2uiSurfaceRecordView(record: viewRecord),
        if (rec != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'catalogId: $catalogId'
              ' · ${actions is List ? actions.length : 0} komponen',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ),
      ],
    );
  }
}
