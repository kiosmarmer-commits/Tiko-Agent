import 'package:flutter/material.dart';
import 'package:simpul_core/simpul_core.dart';

import 'theme.dart';

/// AI chat panel with active-note context (AI-U01): scope selector
/// (this note / folder / whole vault), answer with cited sources and token
/// count (AI-U02), and insert-into-note with an AI provenance marker
/// (AI-U05, DIF-03).
class SimpulNoteChatPanel extends StatefulWidget {
  const SimpulNoteChatPanel({
    super.key,
    required this.vault,
    required this.notePath,
    required this.onInsert,
    this.sessionOverride,
    this.askOverride,
  });

  final String vault;
  final String notePath;

  /// Receives the rendered AI block (with provenance header) to insert into
  /// the active note.
  final ValueChanged<String> onInsert;

  /// Prebuilt session (tests) — skips policy file loading quirks and lets
  /// tests inject a fake LLM.
  final NoteChatSession? sessionOverride;

  /// Full ask override (widget tests): avoids real vault I/O, which cannot
  /// complete inside the test FakeAsync zone.
  final Future<NoteChatAnswer> Function(
    String question, {
    required NoteChatScope scope,
    String? notePath,
    bool confirmAsk,
  })? askOverride;

  @override
  State<SimpulNoteChatPanel> createState() => _SimpulNoteChatPanelState();
}

class _SimpulNoteChatPanelState extends State<SimpulNoteChatPanel> {
  NoteChatScope scope = NoteChatScope.note;
  final TextEditingController question = TextEditingController();
  bool busy = false;
  NoteChatAnswer? answer;
  String? error;

  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  NoteChatSession _session() =>
      widget.sessionOverride ?? NoteChatSession(vaultDir: widget.vault);

  Future<void> _send({bool confirmAsk = false}) async {
    final q = question.text.trim();
    if (q.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = widget.askOverride != null
          ? await widget.askOverride!(
              q,
              scope: scope,
              notePath: widget.notePath,
              confirmAsk: confirmAsk,
            )
          : await _session().ask(
              q,
              scope: scope,
              notePath: widget.notePath,
              confirmAsk: confirmAsk,
            );
      setState(() {
        answer = result;
        busy = false;
      });
    } on AiAccessDenied catch (e) {
      if (!mounted) return;
      setState(() => busy = false);
      if (e.decision == AiAccessDecision.ask) {
        final approved = await _confirmDialog(e.message);
        if (approved) {
          await _send(confirmAsk: true);
        }
      } else {
        setState(() {
          error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Gagal: $e';
        });
      }
    }
  }

  Future<bool> _confirmDialog(String message) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Persetujuan AI (AI-41)'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Tolak'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Izinkan sekali ini'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(left: BorderSide(color: context.simpulBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: DropdownButtonFormField<NoteChatScope>(
              initialValue: scope,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Cakupan konteks (AI-U01)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: NoteChatScope.note,
                  child: Text('Catatan ini'),
                ),
                DropdownMenuItem(
                  value: NoteChatScope.folder,
                  child: Text('Folder catatan ini'),
                ),
                DropdownMenuItem(
                  value: NoteChatScope.vault,
                  child: Text('Seluruh vault'),
                ),
              ],
              onChanged: (v) => setState(() => scope = v ?? NoteChatScope.note),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: question,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Tanya tentang catatan ini...',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: busy ? null : () => _send(),
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 16),
              label: const Text('Tanya AI lokal'),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: context.simpulDanger, fontSize: 12),
              ),
            ),
          Expanded(child: _answerView()),
        ],
      ),
    );
  }

  Widget _answerView() {
    final a = answer;
    if (a == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'AI lokal (Ollama) akan menjawab memakai konteks catatan. '
            'Sumber dan jumlah token ditampilkan di bawah jawaban (AI-U02).',
            style: TextStyle(fontSize: 12),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        SelectableText(a.answer, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Text(
          'Konteks: ~${a.contextTokens} token (AI-U02)',
          style: TextStyle(fontSize: 11, color: context.simpulMuted),
        ),
        const SizedBox(height: 4),
        for (final source in a.sources)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined, size: 16),
            title: Text(source.path,
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(
              '${source.headingPath} \u2022 skor ${source.score.toStringAsFixed(1)}',
              style: TextStyle(fontSize: 10, color: context.simpulMuted),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: () {
            final session = widget.sessionOverride;
            widget.onInsert(NoteChatInsertion.block(
              a.answer,
              model: session?.chat.model ?? 'lokal',
            ));
          },
          icon: const Icon(Icons.playlist_add, size: 16),
          label: const Text('Sisipkan ke catatan (AI-U05)'),
        ),
      ],
    );
  }
}
