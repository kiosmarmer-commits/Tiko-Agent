import 'package:flutter/material.dart';

import '../data/models.dart';
import 'theme.dart';

/// Memory graph / learning timeline (GUI-P2-05): urutan kronologis entri
/// memori berlapis dengan provenance akurat dari `GET /v1/memory/layers`
/// (waktu, jumlah akses, sumber sesi, tag, importance) dan kontrol hapus.
/// Data berasal dari API yang sama dengan tab Lapisan — tidak ada API baru.
class MemoryGraphTimeline extends StatelessWidget {
  const MemoryGraphTimeline({
    super.key,
    required this.entries,
    required this.online,
    required this.loading,
    this.error,
    this.truncated = false,
    this.total = 0,
    this.onDelete,
  });

  final List<LayerEntry> entries;
  final bool online;
  final bool loading;
  final String? error;
  final bool truncated;
  final int total;
  final Future<void> Function(String id)? onDelete;

  String _dateKeyOf(LayerEntry entry) {
    final raw = entry.createdAt.trim();
    if (raw.length >= 10) return raw.substring(0, 10);
    return raw.isEmpty ? '(tanpa waktu)' : raw;
  }

  List<MapEntry<String, List<LayerEntry>>> _groupedByDate() {
    final sorted = [...entries]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final groups = <String, List<LayerEntry>>{};
    for (final entry in sorted) {
      groups.putIfAbsent(_dateKeyOf(entry), () => []).add(entry);
    }
    return groups.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(error!, style: TextStyle(color: context.simpulDanger)),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Belum ada memori berlapis untuk digambarkan \u2014 tambah lewat tab Lapisan.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.simpulMuted),
        ),
      );
    }
    final groups = _groupedByDate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Timeline ${entries.length} entri'
            '${truncated ? ' (terpotong dari $total)' : ''} \u00b7 diurutkan terbaru',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final group in groups) ...[
                _DateHeader(label: group.key, count: group.value.length),
                for (final entry in group.value)
                  _TimelineTile(entry: entry, onDelete: onDelete),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(Icons.timeline, size: 14, color: context.simpulMuted),
          const SizedBox(width: 6),
          Text(
            '$label \u00b7 $count entri',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.simpulMuted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: context.simpulBorder, thickness: 0.5)),
        ],
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.entry, required this.onDelete});
  final LayerEntry entry;
  final Future<void> Function(String id)? onDelete;

  @override
  Widget build(BuildContext context) {
    final layerColor = switch (entry.layer) {
      'episodic' => context.simpulInfo,
      'procedural' => context.simpulWarn,
      _ => context.simpulSuccess,
    };
    final provenance = [
      'akses ${entry.accessCount}',
      if (entry.sourceSession.isNotEmpty) 'sesi ${entry.sourceSession}',
      if (entry.lastAccessedAt.isNotEmpty) 'terakhir ${entry.lastAccessedAt}',
    ].join(' \u00b7 ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: context.simpulBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: layerColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    entry.layer.toUpperCase(),
                    style: TextStyle(
                      color: layerColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    key: Key('btn-delete-graph-${entry.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Hapus entri',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => onDelete!(entry.id),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(4),
                    value: entry.importance.clamp(0.0, 1.0),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'importance ${entry.importance.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 11, color: context.simpulMuted),
                ),
              ],
            ),
            if (entry.tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in entry.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.simpulPanel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.simpulBorder),
                      ),
                      child: Text(
                        '#$tag',
                        style: TextStyle(
                          fontSize: 10,
                          color: context.simpulMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              provenance,
              style: TextStyle(fontSize: 11, color: context.simpulMuted),
            ),
          ],
        ),
      ),
    );
  }
}
