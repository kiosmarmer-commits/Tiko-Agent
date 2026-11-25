import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'media_embed.dart';

/// Flutter Web: elemen `<video>`/`<audio>` asli browser. Satu viewType unik
/// per elemen — setiap pemanggilan mendaftarkan view factory-nya sendiri.
Widget buildMediaEmbed({
  required String kind,
  required String src,
  String? poster,
  bool loop = false,
}) {
  final isVideo = kind == 'video';
  final web.HTMLMediaElement element;
  if (isVideo) {
    final video = web.HTMLVideoElement()
      ..controls = true
      ..style.width = '100%'
      ..style.height = '100%';
    if (poster != null && poster.isNotEmpty) video.poster = poster;
    element = video;
  } else {
    final audio = web.HTMLAudioElement()..controls = true;
    if (loop) audio.loop = true;
    element = audio;
  }
  try {
    element.src = src;
  } catch (_) {
    return fallbackMediaEmbed(kind: kind, src: src, poster: poster);
  }
  final viewType =
      'tiko-a2ui-media-$kind-${DateTime.now().microsecondsSinceEpoch}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) => element);
  return isVideo
      ? AspectRatio(
          aspectRatio: 16 / 9,
          child: HtmlElementView(viewType: viewType),
        )
      : SizedBox(
          height: 54,
          child: HtmlElementView(viewType: viewType),
        );
}
