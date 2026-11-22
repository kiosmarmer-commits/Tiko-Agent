import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// A.2 — `unzip_archive`: ekstrak arsip zip di dalam workspace dengan
/// batasan aman (anti path traversal, anti zip bomb). Agent lain (mis. user
/// upload zip proyek via gateway) maupun turn agent biasa memakai tool ini
/// untuk membongkar arsip lalu menjelajah isinya seperti folder biasa.
///
/// Prinsip keamanan (mengikuti PRD #8 / PathSafety):
/// - path arsip dan tujuan HARUS berada di dalam workspace root.
/// - entry dengan nama absolut atau `..` ditolak; symlink tidak dibuat.
/// - Batas: 500 entry, 16 MiB per entry, 64 MiB total ter-ekspansi —
///   lebih dari itu ekstraksi berhenti dengan penanda jujur.
class UnzipArchiveTool implements Tool {
  UnzipArchiveTool({required this.workspaceRoot});

  final String workspaceRoot;

  static const maxEntries = 500;
  static const maxPerEntryBytes = 16 * 1024 * 1024;
  static const maxTotalBytes = 64 * 1024 * 1024;
  static const listingCount = 50;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'unzip_archive',
        description:
            'Ekstrak arsip .zip di dalam workspace ke folder tujuan '
            '(default: folder `<nama-arsip>/` di sebelah berkas).'
            ' Entry berbahaya (path traversal) dan arsip bomb dibatasi.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path arsip .zip relatif workspace.',
            },
            'dest': {
              'type': 'string',
              'description': 'Folder tujuan relatif workspace '
                  '(opsional; default `<nama-arsip>/`).',
            },
          },
          'required': ['path'],
        },
        risk: 'medium',
        timeoutSec: 120,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '';
    if (rel.isEmpty) {
      return ToolResult(callId: '', content: 'error: path kosong',
        isError: true);
    }
    final zipResolved =
        PathSafety.resolveInRoot(workspaceRoot, rel);
    if (zipResolved == null) {
      return ToolResult(
        callId: '',
        content: 'error: path di luar workspace atau tidak valid: $rel',
        isError: true,
      );
    }
    final zipFile = File(zipResolved);
    if (!zipFile.existsSync()) {
      return ToolResult(
        callId: '',
        content: 'error: file tidak ditemukan: $rel',
        isError: true,
      );
    }

    final destRel = (args['dest'] as String?)?.trim() ?? '';
    final defaultDir = p.withoutExtension(zipResolved);
    final destPath = destRel.isEmpty
        ? defaultDir
        : p.join(p.dirname(zipResolved), destRel);
    final destResolved =
        PathSafety.resolveInRoot(workspaceRoot, destPath);
    if (destResolved == null) {
      return ToolResult(
        callId: '',
        content: 'error: dest di luar workspace atau tidak valid: $destRel',
        isError: true,
      );
    }

    try {
      final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
      final files = archive.where((e) => e.isFile).toList();
      if (files.isEmpty) {
        return ToolResult(
          callId: '',
          content: 'Arsip kosong (tidak ada file entry).',
        );
      }
      final destDir = Directory(destResolved);
      destDir.createSync(recursive: true);
      final listing = <String>[];
      var total = 0;
      var written = 0;
      var truncated = false;
      var rejected = 0;
      for (final entry in files) {
        if (written >= maxEntries) {
          truncated = true;
          break;
        }
        final unsafe = entry.name.startsWith('/') ||
            entry.name.startsWith(r'\\') ||
            entry.name.contains('..') ||
            p.isAbsolute(entry.name);
        if (unsafe) {
          rejected++;
          continue;
        }
        if (entry.size > maxPerEntryBytes) {
          truncated = true;
          continue;
        }
        total += entry.size;
        if (total > maxTotalBytes) {
          truncated = true;
          continue;
        }
        final target = p.normalize(p.join(destResolved, entry.name));
        if (!p.isWithin(destResolved, target)) {
          rejected++;
          continue;
        }
        final bytes = entry.content as List<int>;
        File(target)
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes, flush: true);
        written++;
        if (listing.length < listingCount) listing.add(entry.name);
      }
      final buf = StringBuffer()
        ..writeln(
          'Diekstrak $written/${files.length} entry dari ${p.basename(rel)} '
          'ke "$destRel${destRel.isEmpty ? p.basename(defaultDir) : ''}":',
        );
      for (final l in listing) {
        buf.writeln('- $l');
      }
      if (listing.length < listingCount && written > listing.length) {
        buf.writeln('- ... dan ${written - listing.length} entry lainnya');
      }
      if (rejected > 0) {
        buf.writeln('[DITOLAK: $rejected entry tidak aman / path traversal]');
      }
      if (truncated) {
        buf.writeln(
          '[Berhenti di batas aman: maks $maxEntries entry, '
          '${maxTotalBytes ~/ (1024 * 1024)} MiB total ter-ekspansi]',
        );
      }
      return ToolResult(callId: '', content: buf.toString());
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'error: gagal mengekstrak arsip ($e)',
        isError: true,
      );
    }
  }
}
