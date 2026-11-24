/// Hermes S7 (download): simpan hasil unduhan artifact di semua target
/// build — Web via anchor `dart:html`, desktop/io via folder Downloads
/// atau temp. Pola conditional export sama dengan attachment picker.
library;

export 'artifact_saver_stub.dart'
    if (dart.library.js_interop) 'artifact_saver_web.dart';
