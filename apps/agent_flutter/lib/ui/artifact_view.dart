import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.sessionOptions = const [],
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

  /// Hermes S7: daftar sesi untuk filter artifacts per session.
  final List<SessionSummary> sessionOptions;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> {
  String _mode = 'preview';
  String _sessionFilter = '';

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
              if (widget.sessionOptions.isNotEmpty)
                DropdownButton<String>(
                  key: const Key('filter-artifacts-session'),
                  value: _sessionFilter.isEmpty ? null : _sessionFilter,
                  hint: const Text('Sesi', style: TextStyle(fontSize: 12)),
                  isDense: true,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Semua sesi')),
                    for (final session in widget.sessionOptions)
                      DropdownMenuItem(
                        value: session.id,
                        child: Text(
                          session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _sessionFilter = value ?? ''),
                ),
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
                          setState(() => _mode = 'preview');
                          final parent =
                              widget.dir.split('/')..removeLast();
                          widget.onOpenDir?.call(parent.join('/'));
                        },
                      ),
                    for (final file in _visibleFiles(listing))
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
                          setState(() => _mode = 'preview');
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
          mode: content.bakExists && widget.diff != null
              ? _mode
              : (_mode == 'diff' ? 'preview' : _mode),
          onModeChanged: (candidate) {
            if (candidate == 'diff' && !widget.content!.bakExists) return;
            setState(() => _mode = candidate);
          },
          onClose: widget.onClosePreview,
        ),
      ],
    );
  }

  List<ArtifactFileInfo> _visibleFiles(ArtifactsListing listing) {
    if (_sessionFilter.isEmpty) return listing.files;
    final started = widget.sessionOptions
        .where((s) => s.id == _sessionFilter)
        .map((s) => DateTime.tryParse(s.createdAt))
        .firstWhere((d) => d != null, orElse: () => null);
    if (started == null) return listing.files;
    return listing.files
        .where((file) => file.path.endsWith('/') ||
            (DateTime.tryParse(file.modified)?.isAfter(started) ?? false))
        .toList();
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// Widget preview publik (C3 Chat-UX): wrapper stateful di atas
/// [_PreviewCard] agar panel chat (dan target lain) dapat menampilkan
/// isi file + toggle diff tanpa mengelola state toggle sendiri.
class ArtifactPreviewPanel extends StatefulWidget {
  const ArtifactPreviewPanel({
    super.key,
    required this.content,
    this.diff,
    this.initialShowDiff = false,
    this.onClose,
    this.thumbnail,
    this.onLoadImage,
    this.onDownload,
    this.onPublish,
  });

  final ArtifactContent content;
  final ArtifactDiff? diff;
  final bool initialShowDiff;
  final VoidCallback? onClose;

  /// Hermes S7: thumbnail gambar yang sudah dimuat panel chat.
  final Uint8List? thumbnail;

  /// Hermes S7: muat byte gambar bila base64 inline belum tersedia.
  final Future<List<int>?> Function(String path)? onLoadImage;

  /// Hermes S7: tombol unduh (null → disembunyikan).
  final VoidCallback? onDownload;

  /// Hermes S7: tombol publish/share (null → disembunyikan).
  final VoidCallback? onPublish;

  @override
  State<ArtifactPreviewPanel> createState() => _ArtifactPreviewPanelState();
}

class _ArtifactPreviewPanelState extends State<ArtifactPreviewPanel> {
  static const _modes = ['preview', 'code', 'diff'];

  late String _mode = widget.initialShowDiff ? 'diff' : 'preview';
  Uint8List? _imageBytes;
  bool _imageTried = false;

  @override
  void initState() {
    super.initState();
    _imageBytes = _decodeBase64Image();
  }

  @override
  void didUpdateWidget(ArtifactPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.path != widget.content.path ||
        oldWidget.initialShowDiff != widget.initialShowDiff) {
      _mode = widget.initialShowDiff ? 'diff' : 'preview';
      _imageTried = false;
      if (!_modes.contains(_mode)) _mode = 'preview';
      _imageBytes = _decodeBase64Image();
    }
  }

  Uint8List? _decodeBase64Image() {
    if (!widget.content.isImage || widget.content.contentBase64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(widget.content.contentBase64);
    } on FormatException {
      return null;
    }
  }

  Future<void> _maybeLoadImageBytes() async {
    final loader = widget.onLoadImage;
    final current = _imageBytes ?? widget.thumbnail;
    if (_imageTried || loader == null || !widget.content.isImage) return;
    if (current != null) return;
    _imageTried = true;
    final bytes = await loader(widget.content.path).catchError((_) => null);
    if (!mounted || bytes == null || bytes.isEmpty) return;
    setState(() => _imageBytes = Uint8List.fromList(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final hasDiff = widget.content.bakExists && widget.diff != null;
    final mode = hasDiff ? _mode : (_mode == 'diff' ? 'preview' : _mode);
    if (mode == 'preview' && widget.content.isImage) {
      unawaited(_maybeLoadImageBytes());
    }
    return _PreviewCard(
      content: widget.content,
      diff: widget.diff,
      mode: mode,
      imageBytes: _imageBytes,
      onModeChanged: (candidate) {
        if (candidate == 'diff' && !hasDiff) return;
        setState(() => _mode = candidate);
      },
      onClose: widget.onClose,
      onDownload: widget.onDownload,
      onPublish: widget.onPublish,
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.content,
    required this.diff,
    required this.mode,
    required this.onModeChanged,
    this.imageBytes,
    this.onClose,
    this.onDownload,
    this.onPublish,
  });

  final ArtifactContent content;
  final ArtifactDiff? diff;
  final String mode;
  final ValueChanged<String> onModeChanged;
  final Uint8List? imageBytes;
  final VoidCallback? onClose;
  final VoidCallback? onDownload;
  final VoidCallback? onPublish;

  @override
  Widget build(BuildContext context) {
    final diff = this.diff;
    return Container(
      constraints: const BoxConstraints(maxHeight: 380),
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
              if (!content.binary)
                IconButton(
                  key: const Key('btn-artifact-copy'),
                  tooltip: 'Salin isi file',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: content.content),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('File tersalin'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
              if (onDownload != null)
                IconButton(
                  key: const Key('btn-artifact-download'),
                  tooltip: 'Unduh file',
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_rounded, size: 18),
                ),
              if (onPublish != null)
                IconButton(
                  key: const Key('btn-artifact-publish'),
                  tooltip: 'Publikasikan artifact (share)',
                  onPressed: onPublish,
                  icon: const Icon(Icons.share_outlined, size: 18),
                ),
              if (content.bakExists && diff != null)
                ToggleButtons(
                  isSelected: [
                    mode == 'preview',
                    mode == 'code',
                    mode == 'diff',
                  ],
                  onPressed: (i) => onModeChanged(['preview', 'code', 'diff'][i]),
                  borderRadius: BorderRadius.circular(8),
                  constraints:
                      const BoxConstraints(minHeight: 28, minWidth: 44),
                  children: const [
                    Text('Preview', style: TextStyle(fontSize: 11)),
                    Text('Code', style: TextStyle(fontSize: 11)),
                    Text('Diff', style: TextStyle(fontSize: 11)),
                  ],
                ),
              IconButton(
                  onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(child: _body(context, diff)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, ArtifactDiff? diff) {
    if (content.binary &&
        !(content.isImage && imageBytes != null)) {
      return Text('(File biner \u2014 pratinjau teks tidak tersedia)',
          style: TextStyle(color: context.simpulMuted, fontSize: 12));
    }
    if (mode == 'diff' && diff != null) {
      return SingleChildScrollView(child: _DiffView(diff: diff));
    }
    if (mode == 'preview' && content.isImage) {
      if (imageBytes == null) {
        return Text('(Gambar belum termuat...)',
            style: TextStyle(color: context.simpulMuted, fontSize: 12));
      }
      return Center(
        child: InteractiveViewer(
          maxScale: 8,
          child: Image.memory(imageBytes!, fit: BoxFit.contain, height: 220),
        ),
      );
    }
    if (mode == 'code') {
      final lines = content.content.split('\n');
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${(i + 1).toString().padLeft(4, ' ')}  ',
                      style: TextStyle(
                        color: context.simpulMuted,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    TextSpan(
                      text: lines[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            if (content.truncated)
              Text('\u2026 (terpotong di batas server)',
                  style: TextStyle(color: context.simpulMuted, fontSize: 11)),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      child: Text(
        content.content +
            (content.truncated ? '\n\u2026 (terpotong di batas server)' : ''),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
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
