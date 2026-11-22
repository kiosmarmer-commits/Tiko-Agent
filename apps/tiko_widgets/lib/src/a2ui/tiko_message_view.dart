import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../gen_ui_view.dart';
import '../markdown_view.dart';
import 'a2ui_surface_view.dart';

/// Satu tampilan pesan asisten untuk semua bahasa UI Tiko (Fase E2):
/// blok ```genui (grammar lama) dan blok ```a2ui (A2UI v1.0) hidup
/// berdampingan dengan teks markdown biasa. Blok tidak valid / belum
/// tertutup dirender sebagai teks biasa (fail-closed).
class TikoSurfaceOrMessageView extends StatelessWidget {
  const TikoSurfaceOrMessageView({
    super.key,
    required this.text,
    this.onAction,
    this.onSurfaceAction,
  });

  final String text;

  /// Aksi GenUI: (actionId, values).
  final void Function(String actionId, Map<String, dynamic> values)? onAction;

  /// Aksi A2UI surface: (surfaceId, actionName, payload).
  final void Function(
          String surfaceId, String actionName, Map<String, dynamic> payload)?
      onSurfaceAction;

  @override
  Widget build(BuildContext context) {
    final children = _segments(context);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }

  List<Widget> _segments(BuildContext context) {
    final widgets = <Widget>[];
    final cursorOut = <(int, int, Object)>[];
    for (final b in extractA2uiBlocks(text, includeStreaming: true)) {
      cursorOut.add((b.start, b.end, b.complete ? b.messages : b));
    }
    for (final b in extractGenUiBlocks(text)) {
      cursorOut.add((b.start, b.end, b.spec));
    }
    cursorOut.sort((a, b) => a.$1.compareTo(b.$1));
    var cursor = 0;
    for (final (start, end, payload) in cursorOut) {
      if (start > cursor) {
        widgets.add(TikoMarkdownView(text: text.substring(cursor, start)));
      }
      if (payload is GenUiSpec) {
        widgets.add(GenUiView(spec: payload, onAction: onAction));
      } else if (payload is A2uiBlock) {
        widgets.add(const _A2uiStreamingSkeleton());
      } else if (payload is List) {
        try {
          final messages =
              payload.whereType<A2uiMessage>().toList(growable: false);
          widgets.add(A2uiSurfaceStreamView(messages: messages));
        } on FormatException catch (e) {
          widgets.add(Text(
            'a2ui: surface tidak dapat dirender (${e.message})',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ));
        }
      }
      cursor = end;
    }
    if (cursor < text.length) {
      widgets.add(TikoMarkdownView(text: text.substring(cursor)));
    }
    return widgets;
  }
}

/// Skeleton temat A2UI saat fence masih mengalir (E4): placeholder netral
/// tanpa komponen yang dirender — batch tetap divalidasi atomik di akhir.
class _A2uiStreamingSkeleton extends StatelessWidget {
  const _A2uiStreamingSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Text(
            'Surface sedang dibuat... (A2UI)',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
