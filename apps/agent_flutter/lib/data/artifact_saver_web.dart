import 'dart:html' as html;
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:typed_data';

/// Hermes S7 (download): unduh artifact di Web via anchor `dart:html`
/// — dipilih sadar tanpa dependency baru (pola sama dengan attachment
/// picker); bytes sudah diambil klien dengan auth header.
void saveArtifactDownloaded(String filename, Uint8List bytes) {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
}
