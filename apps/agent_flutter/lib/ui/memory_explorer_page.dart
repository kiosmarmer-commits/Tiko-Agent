import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'memory_graph_view.dart';
import 'page_header.dart';

/// Memory Explorer lanjutan (GUI-P1-12): empat tab — Fakta (kurasi kurir
/// `/v1/memories`), Kurasi (MEMORY.md/USER.md + anggaran karakter),
/// Lapisan (episodic/semantic/procedural CRUD), dan RAG (sumber dokumen,
/// read-only). Kontrol write hanya aktif bila backend endpoint tersedia.
class MemoryExplorerPage extends StatefulWidget {
  const MemoryExplorerPage({
    super.key,
    required this.memories,
    this.curated,
    this.layers,
    this.rag,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onDelete,
    this.onSaveCurated,
    this.onAddLayer,
    this.onDeleteLayer,
  });

  final List<MemoryFact> memories;
  final CuratedMemoryInfo? curated;
  final LayersSnapshot? layers;
  final RagSourcesInfo? rag;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(String id)? onDelete;
  final Future<String?> Function(String file, String text)? onSaveCurated;
  final Future<String?> Function(Map<String, dynamic> body)? onAddLayer;
  final Future<String?> Function(String id)? onDeleteLayer;

  @override
  State<MemoryExplorerPage> createState() => _MemoryExplorerPageState();
}

class _MemoryExplorerPageState extends State<MemoryExplorerPage> {
  final _memoryTextController = TextEditingController();
  final _userTextController = TextEditingController();
  CuratedMemoryInfo? _syncedCurated;

  @override
  void initState() {
    super.initState();
    _syncCurated();
  }

  @override
  void didUpdateWidget(covariant MemoryExplorerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCurated();
  }

  void _syncCurated() {
    final c = widget.curated;
    if (c == null || identical(c, _syncedCurated)) return;
    _syncedCurated = c;
    _memoryTextController.text = c.memory.text;
    _userTextController.text = c.user.text;
  }

  @override
  void dispose() {
    _memoryTextController.dispose();
    _userTextController.dispose();
    super.dispose();
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? context.simpulDanger : null,
      ),
    );
  }

  Future<void> _saveCurated(String file) async {
    final save = widget.onSaveCurated;
    if (save == null) return;
    final error = await save(
      file,
      file == 'user' ? _userTextController.text : _memoryTextController.text,
    );
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    _toast('Kurasi $file tersimpan');
  }

  Future<void> _addLayer() async {
    if (widget.onAddLayer == null) return;
    final layerCtl = TextEditingController(text: 'semantic');
    final textCtl = TextEditingController();
    final tagsCtl = TextEditingController();
    double importance = 0.5;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Tambah entri lapisan',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('layer-select'),
                initialValue: 'semantic',
                decoration: const InputDecoration(
                  labelText: 'Lapisan',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'episodic', child: Text('episodic')),
                  DropdownMenuItem(value: 'semantic', child: Text('semantic')),
                  DropdownMenuItem(
                    value: 'procedural',
                    child: Text('procedural'),
                  ),
                ],
                onChanged: (v) =>
                    setSheetState(() => layerCtl.text = v ?? 'semantic'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('layer-text'),
                controller: textCtl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Teks',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('layer-tags'),
                controller: tagsCtl,
                decoration: const InputDecoration(
                  labelText: 'Tag (pisahkan koma)',
                  border: OutlineInputBorder(),
                ),
              ),
              StatefulBuilder(
                builder: (sheetContext, setSliderState) => Row(
                  children: [
                    const Text('Importance'),
                    Expanded(
                      child: Slider(
                        key: const Key('layer-importance'),
                        value: importance,
                        divisions: 10,
                        label: importance.toStringAsFixed(1),
                        onChanged: (v) => setSliderState(() => importance = v),
                      ),
                    ),
                    Text(importance.toStringAsFixed(1)),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: const Text('Batal'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('btn-submit-layer'),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    child: const Text('Tambah'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    final selectedLayer = layerCtl.text;
    final sheetText = textCtl.text;
    final sheetImportance = importance;
    final sheetTags = [
      for (final t in tagsCtl.text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ];
    if (confirmed != true) return;
    // controller dibuang saat sheet unmounted; entri nggak menggunakan
    // kontroler setelah sheet tertutup
    final error = await widget.onAddLayer!({
      'layer': selectedLayer,
      'text': sheetText,
      'importance': sheetImportance,
      'tags': sheetTags,
    });
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    _toast('Entri lapisan ditambahkan');
  }

  @override
  Widget build(BuildContext context) {
    final cur = _syncedCurated ?? widget.curated;
    final layers = widget.layers;
    final rag = widget.rag;
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          PageHeader(
            title: 'Memory',
            subtitle:
                '${widget.memories.length} fakta \u00b7 ${layers?.total ?? 0} entri berlapis \u00b7 ${rag?.chunkCount ?? 0} chunk RAG',
            online: widget.online,
            trailing: widget.onRefresh == null
                ? null
                : IconButton(
                    key: const Key('btn-refresh-memory'),
                    onPressed: widget.onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
          ),
          if (widget.loading) const LinearProgressIndicator(minHeight: 2),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                widget.error!,
                style: TextStyle(color: context.simpulDanger),
              ),
            ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: const [
              Tab(text: 'Fakta'),
              Tab(text: 'Kurasi'),
              Tab(text: 'Lapisan'),
              Tab(text: 'RAG'),
              Tab(text: 'Timeline'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildFacts(context),
                _buildCurated(context, cur),
                _buildLayers(context, layers),
                _buildRag(context, rag),
                MemoryGraphTimeline(
                  entries: layers?.entries ?? const [],
                  online: widget.online,
                  loading: widget.loading,
                  truncated: layers?.truncated ?? false,
                  total: layers?.total ?? 0,
                  onDelete: widget.onDeleteLayer == null
                      ? null
                      : (id) => _deleteLayer(id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFacts(BuildContext context) {
    if (widget.memories.isEmpty) {
      return Center(
        child: Text('Kosong', style: TextStyle(color: context.simpulMuted)),
      );
    }
    return ListView.builder(
      itemCount: widget.memories.length,
      itemBuilder: (context, i) {
        final memory = widget.memories[i];
        return ListTile(
          title: Text(
            memory.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${memory.id} \u00b7 ${memory.kind}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: widget.onDelete == null
              ? null
              : IconButton(
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
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('Hapus'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await widget.onDelete!(memory.id);
                  },
                ),
        );
      },
    );
  }

  Widget _buildCurated(BuildContext context, CuratedMemoryInfo? cur) {
    if (cur == null) {
      return Center(
        child: Text(
          'Belum ada snapshot \u2014 tekan refresh.',
          style: TextStyle(color: context.simpulMuted),
        ),
      );
    }
    final ratio = cur.budget <= 0
        ? 0.0
        : (cur.used / cur.budget).clamp(0.0, 1.0);
    final over = cur.budget > 0 && cur.used >= cur.budget;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(
              '${cur.memory.chars + cur.user.chars}/${cur.budget} karakter',
              key: const Key('curated-budget'),
              style: TextStyle(
                fontSize: 12,
                color: over ? context.simpulDanger : context.simpulMuted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 6,
                color: over ? context.simpulDanger : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'MEMORY.md',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('memory-curated-mem'),
          controller: _memoryTextController,
          maxLines: null,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Fakta kurasi',
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('btn-save-curated-memory'),
            onPressed: () => _saveCurated('memory'),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Simpan'),
          ),
        ),
        const Text(
          'USER.md',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('memory-curated-user'),
          controller: _userTextController,
          maxLines: null,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Profil pengguna',
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('btn-save-curated-user'),
            onPressed: () => _saveCurated('user'),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Simpan'),
          ),
        ),
      ],
    );
  }

  Widget _buildLayers(BuildContext context, LayersSnapshot? layers) {
    if (layers == null) {
      return Center(
        child: Text(
          'Belum ada snapshot \u2014 tekan refresh.',
          style: TextStyle(color: context.simpulMuted),
        ),
      );
    }
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                key: const Key('layers-stats'),
                spacing: 12,
                children: [
                  for (final e in layers.stats.entries)
                    Text(
                      '${e.key}: ${e.value.count} entri',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.simpulMuted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: layers.entries.isEmpty
                  ? Center(
                      child: Text(
                        'Belum ada entri berlapis.',
                        style: TextStyle(color: context.simpulMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: layers.entries.length,
                      itemBuilder: (context, i) =>
                          _LayerTile(entry: layers.entries[i], page: this),
                    ),
            ),
          ],
        ),
        if (widget.onAddLayer != null)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              key: const Key('btn-add-layer'),
              heroTag: 'btn-add-layer',
              onPressed: _addLayer,
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }

  Widget _buildRag(BuildContext context, RagSourcesInfo? rag) {
    if (rag == null) {
      return Center(
        child: Text(
          'Belum ada snapshot \u2014 tekan refresh.',
          style: TextStyle(color: context.simpulMuted),
        ),
      );
    }
    return ListView(
      key: const Key('rag-list'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${rag.chunkCount} chunk dalam ${rag.docs.length} dokumen'
          '${rag.truncated ? ' (terpotong)' : ''}',
          style: TextStyle(fontSize: 12, color: context.simpulMuted),
        ),
        const SizedBox(height: 8),
        for (final doc in rag.docs)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              doc.docId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${doc.chunks} chunk \u00b7 ${doc.chars} karakter'
              '${doc.preview.isEmpty ? '' : '\n${doc.preview}'}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Future<void> _deleteLayer(String id) async {
    final del = widget.onDeleteLayer;
    if (del == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus entri lapisan?'),
        content: const Text('Entri akan dihapus dari memori berlapis.'),
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
    if (confirmed != true) return;
    final error = await del(id);
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    _toast('Entri lapisan dihapus');
  }
}

class _LayerTile extends StatelessWidget {
  const _LayerTile({required this.entry, required this.page});
  final LayerEntry entry;
  final _MemoryExplorerPageState page;

  static const _layerColor = {
    'episodic': Icons.schedule,
    'semantic': Icons.lightbulb_outline,
    'procedural': Icons.handyman_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      leading: Icon(_layerColor[entry.layer] ?? Icons.lightbulb_outline),
      title: Text(
        entry.text.isEmpty ? '(tanpa teks)' : entry.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$layerLabel \u00b7 ${(entry.importance * 100).round()}%'
        '${entry.tags.isEmpty ? '' : ' \u00b7 ${entry.tags.join(',')}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.simpulMuted, fontSize: 12),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            entry.text,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'dibuat ${entry.createdAt}${entry.lastAccessedAt.isEmpty ? '' : ' \u00b7 akses ${entry.accessCount}x'}'
            '${entry.ownerKey.isEmpty ? '' : ' \u00b7 owner ${entry.ownerKey}'}'
            '${entry.sourceSession.isEmpty ? '' : ' \u00b7 sesi ${entry.sourceSession}'}',
            style: TextStyle(color: context.simpulMuted, fontSize: 11),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: Key('btn-delete-layer-${entry.id}'),
            onPressed: () => page._deleteLayer(entry.id),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Hapus'),
          ),
        ),
      ],
    );
  }

  String get layerLabel => switch (entry.layer) {
    'episodic' => 'episodik',
    'procedural' => 'prosedral',
    _ => 'semantik',
  };
}
