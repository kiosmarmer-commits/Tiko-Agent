import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Artifacts browser & diff viewer (GUI-P2-04, read-only): daftar file
/// workspace, preview isi teks, dan diff versus `.bak` — semua via API
/// aman (`/v1/artifacts*`, PathSafety fail-closed di runtime); tanpa
/// akses tulis dan tanpa path di luar workspace.
class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({
    super.key,
    required this.listing,
    required this.online,
    required this.loading,
    this.error,
    this.dir = '',
    this.onOpenDir,
    this.onOpenFile,
    this.onRefresh,
    this.content,
    this.diff,
    this.contentLoading = false,
    this.onClosePreview,
  });

  final ArtifactsListing? listing;
  final bool online;
  final bool loading;
  final String? error;
  final String dir;
  final ValueChanged<String>? onOpenDir;
  final ValueChanged<String>? onOpenFile;
  final Future<void> Function()? onRefresh;

  /// Preview file yang dipilih (null → belum ada file dibuka).
  final ArtifactContent? content;
  final ArtifactDiff? diff;
  final bool contentLoading;
  final VoidCallback? onClosePreview;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> {
  bool _showDiff = false;

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final content = widget.content;
    return Column(
      children: [
        PageHeader(
          title: 'Artifacts',
          subtitle: listing == null
              ? 'Browser file workspace (read-only)'
              : '${listing.files.length} file${listing.truncated ? ' (terpotong)' : ''}'
                  '\u00b7 ${widget.dir.isEmpty ? 'root' : widget.dir}',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onRefresh != null)
                IconButton(
                    onPressed: widget.onRefresh, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        if (widget.loading || widget.contentLoading)
          const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.error!,
                style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: listing == null
              ? Center(
                  child: Text('Belum ada data artifacts.',
                      style: TextStyle(color: context.simpulMuted)))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    if (widget.dir.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.arrow_upward, size: 18),
                        title: const Text('.. (naik)',
                            style: TextStyle(fontSize: 13)),
                        onTap: () {
                          setState(() => _showDiff = false);
                          final parent =
                              widget.dir.split('/')..removeLast();
                          widget.onOpenDir?.call(parent.join('/'));
                        },
                      ),
                    for (final file in listing.files)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          file.path.endsWith('/')
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        title: Text(file.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                        trailing: Text(_sizeLabel(file.bytes),
                            style: TextStyle(
                                fontSize: 11,
                                color: context.simpulMuted)),
                        onTap: () {
                          setState(() => _showDiff = false);
                          widget.onOpenFile?.call(
                              widget.dir.isEmpty
                                  ? file.path
                                  : '${widget.dir}/${file.path}');
                        },
                      ),
                  ],
                ),
        ),
        if (content != null) _PreviewCard(
          content: content,
          diff: widget.diff,
          showDiff: _showDiff,
          onToggleDiff: (v) => setState(() => _showDiff = v),
          onClose: widget.onClosePreview,
        ),
      ],
    );
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.content,
    required this.diff,
    required this.showDiff,
    required this.onToggleDiff,
    this.onClose,
  });

  final ArtifactContent content;
  final ArtifactDiff? diff;
  final bool showDiff;
  final ValueChanged<bool> onToggleDiff;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final diff = this.diff;
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
        border: Border.all(color: context.simpulBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(content.path,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (content.bakExists && diff != null)
                ToggleButtons(
                  isSelected: [!showDiff, showDiff],
                  onPressed: (i) => onToggleDiff(i == 1),
                  borderRadius: BorderRadius.circular(8),
                  constraints:
                      const BoxConstraints(minHeight: 28, minWidth: 48),
                  children: const [
                    Text('Preview', style: TextStyle(fontSize: 11)),
                    Text('Diff', style: TextStyle(fontSize: 11)),
                  ],
                ),
              IconButton(
                  onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: content.binary
                ? Text('(File biner \u2014 pratinjau teks tidak tersedia)',
                    style: TextStyle(color: context.simpulMuted, fontSize: 12))
                : showDiff && diff != null
                    ? SingleChildScrollView(
                        child: _DiffView(diff: diff),
                      )
                    : SingleChildScrollView(
                        child: Text(
                          content.content +
                              (content.truncated
                                  ? '\n\u2026 (terpotong di batas server)'
                                  : ''),
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});

  final ArtifactDiff diff;

  @override
  Widget build(BuildContext context) {
    if (!diff.oldExists) {
      return Text('Tidak ada versi `.bak` untuk dibandingkan.',
          style: TextStyle(color: context.simpulMuted, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in diff.lines)
          Text(
            '${line.type} ${line.text}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: line.type == '+'
                  ? context.simpulSuccess
                  : line.type == '-'
                      ? context.simpulDanger
                      : context.simpulMuted,
            ),
          ),
        if (diff.truncated)
          Text('\u2026 diff terpotong di batas server',
              style: TextStyle(color: context.simpulMuted, fontSize: 11)),
      ],
    );
  }
}
