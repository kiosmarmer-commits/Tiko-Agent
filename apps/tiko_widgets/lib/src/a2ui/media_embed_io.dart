import 'package:flutter/material.dart';

import 'media_placeholder.dart';

/// Non-web: pemutaran media native tidak ditautkan (codec butuh plugin);
/// panggilan fall back ke placeholder jujur.
Widget buildMediaEmbed({
  required String kind,
  required String src,
  String? poster,
  bool loop = false,
}) => buildMediaPlaceholder(kind: kind, src: src, poster: poster);
