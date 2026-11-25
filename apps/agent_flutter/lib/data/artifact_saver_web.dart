import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Hermes S7 (download): unduh artifact di Web via anchor `package:web`
/// (W3C interop modern — pola sama dengan media embed S18); bytes sudah
/// diambil klien dengan auth header, tanpa dependency baru.
void saveArtifactDownloaded(String filename, Uint8List bytes) {
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  final parent = web.document.body;
  if (parent == null) {
    web.URL.revokeObjectURL(url);
    return;
  }
  parent.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
