import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'artifact_view.dart';

/// C3: pola referensi `@file:` dalam pesan (user maupun assistant) — chip
/// bisa ditap untuk membuka file di panel. Karakter berisiko (`..`, `\`)
/// dilewati — fail-closed; path tetap divalidasi server.
final RegExp chatFileRefPattern = RegExp(r'@file:([^\s,!?)\]<>"]+)');

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

/// Panel file di dalam chat (C3 Chat-UX, read-only): daftar file artifacts
/// terkini + preview file yang dibuka (isi teks + diff vs `.bak`). Tampil
/// side-by-side di layar lebar (≥1100px) dan sebagai overlay penuh di
/// layar sempit (mobile) — pengganti lembar terpisah seperti artifacts
/// Claude mobile. Sumber data `GET /v1/artifacts*` yang sudah ada; tidak
/// ada akses tulis.
class ChatArtifactPanel extends StatelessWidget {
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

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final listing = this.listing;
    final preview = this.preview;
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
                      listing == null
                          ? 'File workspace'
                          : '${listing.files.length} file'
                              '${listing.truncated ? ' (terpotong)' : ''}'
                              ' · ${dir.isEmpty ? 'root' : dir}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (onRefresh != null)
                    IconButton(
                      tooltip: 'Muat ulang daftar file',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: onRefresh,
                    ),
                  if (onClosePreview != null)
                    IconButton(
                      tooltip: 'Tutup panel file',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onClosePreview,
                    ),
                ],
              ),
            ),
            if (listingLoading || previewLoading)
              const LinearProgressIndicator(minHeight: 2),
            if (listingError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  listingError!,
                  style: TextStyle(color: context.simpulDanger, fontSize: 12),
                ),
              ),
            Expanded(
              child: listing == null
                  ? Center(
                      child: Text(
                        'Belum ada daftar file artifacts.',
                        style: TextStyle(color: context.simpulMuted),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        if (dir.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward, size: 18),
                            title: const Text(
                              '.. (naik)',
                              style: TextStyle(fontSize: 13),
                            ),
                            onTap: () {
                              final parts = dir.split('/')..removeLast();
                              onOpenDir?.call(parts.join('/'));
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
                                ? () => onOpenDir?.call(
                                      dir.isEmpty
                                          ? file.path
                                          : '$dir/${file.path}',
                                    )
                                : () => onOpenFile?.call(
                                      dir.isEmpty
                                          ? file.path
                                          : '$dir/${file.path}',
                                    ),
                          ),
                      ],
                    ),
            ),
            if (preview != null)
              ArtifactPreviewPanel(
                content: preview,
                diff: diff,
                initialShowDiff: previewShowDiff,
                onClose: onClosePreview,
              ),
          ],
        ),
      ),
    );
  }
}
