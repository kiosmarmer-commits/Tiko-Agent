import 'package:flutter/material.dart';
import 'package:simpul_core/simpul_core.dart';

/// Computed index status snapshot (NFR-O03). Pure computation over a scan
/// result so it can be unit-tested without I/O.
class IndexStatusSummary {
  const IndexStatusSummary({
    required this.noteCount,
    required this.linkCount,
    required this.brokenLinkCount,
    required this.tagCount,
    required this.scanMs,
    required this.totalWords,
  });

  final int noteCount;
  final int linkCount;
  final int brokenLinkCount;
  final int tagCount;
  final int scanMs;
  final int totalWords;

  static IndexStatusSummary fromNotes(
    List<ScannedNote> notes, {
    required int scanMs,
  }) {
    final resolver = VaultLinkResolver(notes);
    var linkCount = 0;
    var broken = 0;
    final tags = <String>{};
    var words = 0;
    for (final note in notes) {
      tags.addAll(note.parsed.tags);
      words += note.parsed.wordCount;
      for (final link in note.parsed.links) {
        if (link.embed || link.target.isEmpty) continue;
        linkCount++;
        if (resolver.resolve(link.target) == null) broken++;
      }
    }
    return IndexStatusSummary(
      noteCount: notes.length,
      linkCount: linkCount,
      brokenLinkCount: broken,
      tagCount: tags.length,
      scanMs: scanMs,
      totalWords: words,
    );
  }
}

/// Opens the vault index dashboard (NFR-O03): entry counts, scan speed,
/// and error (broken link) totals.
Future<void> showIndexDashboard(
  BuildContext context,
  String vault,
) async {
  final summary = await computeSummary(vault);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Status Indeks (NFR-O03)'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('Vault', vault),
            _row('Catatan terindeks', '${summary.noteCount}'),
            _row('Total kata', '${summary.totalWords}'),
            _row('Tautan keluar', '${summary.linkCount}'),
            _row(
              'Tautan rusak',
              '${summary.brokenLinkCount}',
              danger: summary.brokenLinkCount > 0,
            ),
            _row('Tag unik', '${summary.tagCount}'),
            _row('Durasi scan', '${summary.scanMs} ms'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Tutup'),
        ),
      ],
    ),
  );
}

Future<IndexStatusSummary> computeSummary(String vault) async {
  final watch = Stopwatch()..start();
  final notes = await VaultScanner.scan(vault);
  watch.stop();
  return IndexStatusSummary.fromNotes(notes, scanMs: watch.elapsedMilliseconds);
}

Widget _row(String label, String value, {bool danger = false}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: danger ? const Color(0xFFB3261E) : null,
          ),
        ),
      ],
    ),
  );
}
