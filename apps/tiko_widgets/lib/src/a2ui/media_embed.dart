import 'package:flutter/material.dart';

import 'media_embed_io.dart'
    if (dart.library.html) 'media_embed_web.dart' as impl;
import 'media_placeholder.dart';

/// E9 — embed media A2UI antar-platform.
///
/// - Flutter Web: `<video>`/`<audio>` HTML asli via [HtmlElementView]
///   (pemutaran nyata, kontrol bawaan browser).
/// - Non-web (desktop/mobile): kartu placeholder yang jujur — runtime Tiko
///   tidak menautkan codec native; sumber media tetap ditampilkan.
Widget a2uiMediaEmbed({
  required String kind,
  required String src,
  String? poster,
  bool loop = false,
}) =>
    impl.buildMediaEmbed(kind: kind, src: src, poster: poster, loop: loop);

/// Dipakai versi web bila sumber gagal dibangun (defensive) — tetap jujur.
Widget fallbackMediaEmbed({
  required String kind,
  required String src,
  String? poster,
}) =>
    buildMediaPlaceholder(kind: kind, src: src, poster: poster);
