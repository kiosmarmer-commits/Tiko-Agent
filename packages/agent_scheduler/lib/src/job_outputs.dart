import 'dart:convert';
import 'dart:io';

/// Fase F5 (docs/15 §6) — memori output job untuk `context_from` chaining:
/// output terakhir tiap job disimpan durabel di satu file JSON kecil
/// (cap ketat) dan dibaca runtime saat membangun konteks prompt job lain.
class JobOutputStore {
  JobOutputStore({required this.persistPath});

  /// Cap per output (char) — job output hanya konteks, bukan laporan penuh.
  static const maxEntryLength = 4000;

  /// Cap jumlah job yang diingat — jobs.json sendiri cap 1000.
  static const maxEntries = 200;

  final String persistPath;
  final Map<String, ({String text, DateTime at})> _outputs = {};
  bool _loaded = false;

  int get length => _outputs.length;

  String? textFor(String jobId) => _outputs[jobId]?.text;

  DateTime? atFor(String jobId) => _outputs[jobId]?.at;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(persistPath);
    if (!await f.exists()) return;
    try {
      if (await f.length() > 1 * 1024 * 1024) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is! Map) return;
        final text = value['text']?.toString() ?? '';
        final at = DateTime.tryParse(value['at']?.toString() ?? '');
        if (key is String && text.isNotEmpty && at != null) {
          _outputs[key] = (text: text, at: at);
        }
      });
    } on Exception {
      // File korup dilompati — chaining bersifat best-effort.
    }
  }

  /// Simpan polla output terakhir; dieksekusi setiap run job sukses.
  Future<void> record(String jobId, String output) async {
    var text = output.trim();
    if (text.isEmpty) return;
    if (text.length > maxEntryLength) {
      text = '${text.substring(0, maxEntryLength)}…';
    }
    _outputs.remove(jobId);
    _outputs[jobId] = (text: text, at: DateTime.now().toUtc());
    while (_outputs.length > maxEntries) {
      _outputs.remove(_outputs.keys.first);
    }
    await save();
  }

  Future<void> save() async {
    final file = File(persistPath);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        for (final e in _outputs.entries)
          e.key: {'text': e.value.text, 'at': e.value.at.toIso8601String()},
      }),
      flush: true,
    );
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(await tmp.readAsString(), flush: true);
      try {
        await tmp.delete();
      } on FileSystemException {
        // best-effort
      }
    }
  }
}
