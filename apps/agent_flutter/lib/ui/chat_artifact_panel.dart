import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'artifact_view.dart';

/// C3: pola referensi `@file:` dalam pesan (user maupun assistant) — chip
/// bisa ditap untuk membuka file di panel. Karakter berisiko (`..`, `\\`)
/// dilewati — fail-closed; path tetap divalidasi server.
final RegExp chatFileRefPattern = RegExp(r'@file:([^\s,!?)\]<>\"]+)');

/// Kumpulkan referensi `@file:` unik dari teks pesan (maks 6), referensi
/// dengan `..` atau backslash dilewati; tanda baca di akhir dipangkas agar
/// ekstensi file tidak terpotong.
List<String> collectFileRefs(String text) {
  final out = <String>[];
  for (final m in chatFileRefPattern.allMatches(text)) {
    final path = m.group(1)!.replaceAll(RegExp(r'[.,;:)]+$'), '');
    if (path.isEmpty) continue;
    if (path.contains('..') || path.contains('\\')) continue;
    if (!out.contains(path) && out.length < 6) out.add(path);
  }
  return out;
}

/// Satu entri kartu file dalam chat (`message['files']`).
class ChatFileCardData {
  const ChatFileCardData({required this.path, this.changed = false});

  final String path;
  final bool changed;
}

/// Parse JSON string `message['files']` (daftar `{path, changed}`) menjadi
/// kartu file chat. Sumber otomatis dari tool trace dikerjakan di C4;
/// parser ini fail-closed — non-JSON / non-list / bukan map diabaikan.
List<ChatFileCardData> parseMessageFileCards(String? raw) {
  if (raw == null || raw.isEmpty || !raw.startsWith('[')) return const [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [
    for (final e in decoded.take(8))
      if (e is Map)
        ChatFileCardData(
          path: '${e['path'] ?? ''}',
          changed: e['changed'] == true,
        ),
  ];
}

/// Hermes S7: ekstensi gambar yang bisa dirender inline di GUI.
const artifactImageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

bool isImageArtifactPath(String path) =>
    artifactImageExtensions.contains(
      path.contains('.') ? path.split('.').last.toLowerCase() : '',
    );

/// Panel file di dalam chat (C3 Chat-UX, read-only): daftar file artifacts
/// terkini + preview file yang dibuka (isi teks + diff vs `.bak`). Tampil
/// side-by-side di layar lebar (≥1100px) dan sebagai overlay penuh di
/// layar sempit (mobile) — pengganti lembar terpisah seperti artifacts
/// Claude mobile.
///
/// Hermes S7: filter "Sesi ini" (file yang dibuat/diubah setelah sesi
/// dimulai atau yang direferensikan pesan sesi), thumbnail gambar inline,
/// preview gambar, download, dan publish/share. Sumber data tetap
/// `GET /v1/artifacts*`; tidak ada akses tulis ke workspace.
class ChatArtifactPanel extends StatefulWidget {
  const ChatArtifactPanel({
    super.key,
    required this.online,
    this.listing,
    this.dir = '',
    this.listingLoading = false,
    this.listingError,
    this.preview,
    this.diff,
    this.previewLoading = false,
    this.previewShowDiff = false,
    this.onOpenDir,
    this.onOpenFile,
    this.onClosePreview,
    this.onRefresh,
    this.sessionStartedAt = '',
    this.sessionRefs = const [],
    this.sessionLabel,
    this.onLoadImage,
    this.onDownload,
    this.onPublish,
  });

  final bool online;
  final ArtifactsListing? listing;
  final String dir;
  final bool listingLoading;
  final String? listingError;
  final ArtifactContent? preview;
  final ArtifactDiff? diff;
  final bool previewLoading;
  final bool previewShowDiff;
  final ValueChanged<String>? onOpenDir;
  final ValueChanged<String>? onOpenFile;
  final VoidCallback? onClosePreview;
  final VoidCallback? onRefresh;

  /// Hermes S7: waktu mulai sesi aktif (ISO) — dasar filter "Sesi ini";
  /// kosong berarti filter tidak tersedia.
  final String sessionStartedAt;

  /// Hermes S7: path file yang direferensikan sesi aktif (chip @file: dan
  /// kartu file) — ikut dihitung dalam filter "Sesi ini".
  final List<String> sessionRefs;

  final String? sessionLabel;

  /// Hermes S7: muat byte gambar untuk thumbnail/preview inline.
  final Future<List<int>?> Function(String path)? onLoadImage;

  /// Hermes S7: unduh file (web: anchor; desktop: folder Downloads).
  final void Function(String path)? onDownload;

  /// Hermes S7: publish/share artifact ke `.tiko/published/`.
  final void Function(String path)? onPublish;

  @override
  State<ChatArtifactPanel> createState() => _ChatArtifactPanelState();
}

class _ChatArtifactPanelState extends State<ChatArtifactPanel> {
  bool sessionOnly = false;
  final _thumbs = <String, Uint8List>{};
  final _thumbInFlight = <String>{};

  bool _sessionFilterAvailable() =>
      widget.sessionStartedAt.isNotEmpty || widget.sessionRefs.isNotEmpty;

  bool _matchesSession(ArtifactFileInfo file) {
    final modified = DateTime.tryParse(file.modified);
    final started = DateTime.tryParse(widget.sessionStartedAt);
    if (modified != null && started != null && modified.isAfter(started)) {
      return true;
    }
    for (final ref in widget.sessionRefs) {
      if (ref.isEmpty) continue;
      if (file.path == ref ||
          file.path.endsWith('/$ref') ||
          ref.endsWith('/${file.path}')) {
        return true;
      }
    }
    return false;
  }

  List<ArtifactFileInfo> _visibleFiles() {
    final listing = widget.listing;
    if (listing == null) return const [];
    if (!(sessionOnly && _sessionFilterAvailable())) return listing.files;
    return listing.files
        .where((file) => file.path.endsWith('/') || _matchesSession(file))
        .toList();
  }

  void _maybeFetchThumbs(List<ArtifactFileInfo> files) {
    final loader = widget.onLoadImage;
    if (loader == null) return;
    for (final file in files) {
      if (file.path.endsWith('/') || !isImageArtifactPath(file.path)) continue;
      if (_thumbs.containsKey(file.path) || _thumbInFlight.contains(file.path)) {
        continue;
      }
      _thumbInFlight.add(file.path);
      loader(file.path).then((bytes) {
        _thumbInFlight.remove(file.path);
        if (bytes == null || bytes.isEmpty) return;
        if (!mounted) return;
        setState(() => _thumbs[file.path] = Uint8List.fromList(bytes));
      }).catchError((Object _) {
        _thumbInFlight.remove(file.path);
      });
    }
  }

  @override
  void didUpdateWidget(ChatArtifactPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listing != widget.listing) {
      _maybeFetchThumbs(_visibleFiles());
    }
  }

  @override
  void initState() {
    super.initState();
    _maybeFetchThumbs(_visibleFiles());
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final visible = _visibleFiles();
    return Material(
      color: context.simpulPanel,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: context.simpulBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.insert_drive_file_outlined,
                    size: 18,
                    color: context.simpulMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.listing == null
                          ? 'File workspace'
                          : '${visible.length} file'
                              '${widget.listing!.truncated ? ' (terpotong)' : ''}'
                              ' · ${widget.dir.isEmpty ? 'root' : widget.dir}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (widget.onRefresh != null)
                    IconButton(
                      tooltip: 'Muat ulang daftar file',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: widget.onRefresh,
                    ),
                  if (widget.onClosePreview != null)
                    IconButton(
                      tooltip: 'Tutup panel file',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: widget.onClosePreview,
                    ),
                ],
              ),
            ),
            if (_sessionFilterAvailable())
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: FilterChip(
                    key: const Key('chip-artifact-session-only'),
                    label: Text(
                      'Sesi ini${widget.sessionLabel == null ? '' : ' · ${widget.sessionLabel}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: sessionOnly,
                    onSelected: (value) => setState(() => sessionOnly = value),
                  ),
                ),
              ),
            if (widget.listingLoading || widget.previewLoading)
              const LinearProgressIndicator(minHeight: 2),
            if (widget.listingError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  widget.listingError!,
                  style: TextStyle(color: context.simpulDanger, fontSize: 12),
                ),
              ),
            Expanded(
              child: widget.listing == null
                  ? Center(
                      child: Text(
                        'Belum ada daftar file artifacts.',
                        style: TextStyle(color: context.simpulMuted),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        if (widget.dir.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward, size: 18),
                            title: const Text(
                              '.. (naik)',
                              style: TextStyle(fontSize: 13),
                            ),
                            onTap: () {
                              final parts = widget.dir.split('/')..removeLast();
                              widget.onOpenDir?.call(parts.join('/'));
                            },
                          ),
                        for (final file in visible)
                          ListTile(
                            dense: true,
                            leading: _leadingIcon(file),
                            title: Text(
                              file.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            trailing: Text(
                              file.path.endsWith('/')
                                  ? ''
                                  : _sizeLabel(file.bytes),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.simpulMuted,
                              ),
                            ),
                            onTap: file.path.endsWith('/')
                                ? () => widget.onOpenDir?.call(
                                      widget.dir.isEmpty
                                          ? file.path
                                          : '${widget.dir}/${file.path}',
                                    )
                                : () => widget.onOpenFile?.call(
                                      widget.dir.isEmpty
                                          ? file.path
                                          : '${widget.dir}/${file.path}',
                                    ),
                          ),
                      ],
                    ),
            ),
            if (preview != null)
              ArtifactPreviewPanel(
                content: preview,
                diff: widget.diff,
                initialShowDiff: widget.previewShowDiff,
                onClose: widget.onClosePreview,
                thumbnail: _thumbs[preview.path],
                onLoadImage: widget.onLoadImage,
                onDownload: widget.onDownload == null
                    ? null
                    : () => widget.onDownload!(preview.path),
                onPublish: widget.onPublish == null
                    ? null
                    : () => widget.onPublish!(preview.path),
              ),
          ],
        ),
      ),
    );
  }

  Widget _leadingIcon(ArtifactFileInfo file) {
    if (file.path.endsWith('/')) {
      return const Icon(Icons.folder_outlined, size: 18);
    }
    final thumb = _thumbs[file.path];
    if (thumb != null && isImageArtifactPath(file.path)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          thumb,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.insert_drive_file_outlined,
            size: 18,
          ),
        ),
      );
    }
    return const Icon(Icons.insert_drive_file_outlined, size: 18);
  }
}
