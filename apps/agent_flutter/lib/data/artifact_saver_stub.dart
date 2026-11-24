import 'dart:io';
import 'dart:typed_data';

/// Hermes S7 (download): simpan artifact ke folder bawaan (Desktop/mobile
/// tanpa plugin) — folder Downloads di HOME/USERPROFILE, fallback ke
/// temp sistem.
void saveArtifactDownloaded(String filename, Uint8List bytes) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final dir = home == null
      ? Directory.systemTemp
      : Directory('$home/Downloads').existsSync()
          ? Directory('$home/Downloads')
          : Directory.systemTemp;
  final safeName = filename.replaceAll(RegExp(r'[/\\]'), '_');
  File('${dir.path}/$safeName').writeAsBytesSync(bytes, flush: true);
}
