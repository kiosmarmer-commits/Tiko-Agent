import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Archive low-importance facts older than [maxAge] into archive JSONL.
class MemoryArchiver {
  MemoryArchiver({
    required this.dataDir,
    this.maxAge = const Duration(days: 180),
  });

  final String dataDir;
  final Duration maxAge;

  Future<int> archiveFactsFile() async {
    final factsFile = File(p.join(dataDir, 'facts.json'));
    if (!await factsFile.exists()) return 0;
    final list = jsonDecode(await factsFile.readAsString()) as List<dynamic>;
    final keep = <Map<String, dynamic>>[];
    final archived = <Map<String, dynamic>>[];
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    for (final raw in list) {
      final m = Map<String, dynamic>.from(raw as Map);
      final imp = (m['importance'] as num?)?.toDouble() ?? 0.5;
      final created = DateTime.tryParse(m['created_at'] as String? ?? '');
      final old = created != null && created.isBefore(cutoff);
      if (old && imp < 0.4) {
        archived.add(m);
      } else {
        keep.add(m);
      }
    }
    if (archived.isEmpty) return 0;
    await factsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(keep),
    );
    final arch = File(p.join(dataDir, 'facts-archive.jsonl'));
    for (final m in archived) {
      await arch.writeAsString('${jsonEncode(m)}\n', mode: FileMode.append);
    }
    return archived.length;
  }
}
