import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A single command-palette action (FR-44).
class PaletteAction {
  const PaletteAction(this.label, this.onSelected, {this.hint});

  final String label;
  final String? hint;
  final VoidCallback onSelected;
}

/// Opens a fuzzy-filtered command palette overlay (FR-44, Obsidian-style
/// Ctrl+K). Actions are filtered by case-insensitive substring, best match
/// first, and Enter/Tab runs the selected action; Escape closes.
Future<void> showCommandPalette(
  BuildContext context,
  List<PaletteAction> actions,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CommandPaletteDialog(actions: actions),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.actions});

  final List<PaletteAction> actions;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final TextEditingController filter = TextEditingController();
  final FocusNode filterFocus = FocusNode();
  int selected = 0;

  @override
  void dispose() {
    filter.dispose();
    filterFocus.dispose();
    super.dispose();
  }

  List<PaletteAction> get _filtered {
    final query = filter.text.trim().toLowerCase();
    if (query.isEmpty) return widget.actions;
    final scored = <(int, PaletteAction)>[];
    for (final action in widget.actions) {
      final label = action.label.toLowerCase();
      final idx = label.indexOf(query);
      if (idx < 0) continue;
      scored.add((idx, action));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return scored.map((s) => s.$2).toList();
  }

  void _run(PaletteAction action) {
    Navigator.of(context).pop();
    action.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    if (selected >= filtered.length) selected = 0;
    return Dialog(
      backgroundColor: context.simpulPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: filter,
                focusNode: filterFocus,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Ketik perintah atau nama catatan...',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => selected = 0),
              ),
            ),
            Flexible(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      setState(() {
                        if (selected < filtered.length - 1) selected++;
                      }),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      setState(() {
                        if (selected > 0) selected--;
                      }),
                  if (filtered.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.enter): () =>
                        _run(filtered[selected]),
                },
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final action = filtered[i];
                    return ListTile(
                      dense: true,
                      selected: i == selected,
                      title: Text(action.label),
                      subtitle:
                          action.hint == null ? null : Text(action.hint!),
                      onTap: () => _run(action),
                    );
                  },
                ),
              ),
            ),
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Tidak ada perintah yang cocok.'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ctrl+K binding helper: wraps [child] so pressing the palette shortcut
/// runs [onPalette] (which typically calls [showCommandPalette]).
class PaletteShortcut extends StatelessWidget {
  const PaletteShortcut({super.key, required this.onPalette, required this.child});

  final VoidCallback onPalette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
        ): onPalette,
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
        ): onPalette,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
