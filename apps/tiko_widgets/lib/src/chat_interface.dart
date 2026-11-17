import 'package:flutter/material.dart';

import 'gen_ui_view.dart';

/// E4 — antarmuka chat generik untuk agen Tiko.
///
/// Widget stateful ringan: daftar pesan (peran + teks) + kolom input.
/// Sengaja tidak bergantung pada agentd/API client — host menyediakan
/// pesan lewat [TikoChatMessage] dan mengirim balasan lewat [onSend].
/// Renderer pesan asisten mendukung blok ```genui bila [renderGenUi]
/// aktif (E4 + D1).
class TikoChatMessage {
  const TikoChatMessage({
    required this.role,
    required this.text,
    this.error = false,
  });

  /// 'user' | 'assistant' | 'system'.
  final String role;
  final String text;

  /// Pesan error ditampilkan dengan warna error.
  final bool error;
}

class TikoChatInterface extends StatefulWidget {
  const TikoChatInterface({
    super.key,
    required this.messages,
    required this.onSend,
    this.renderGenUi = true,
    this.busy = false,
    this.hintText = 'Tulis pesan…',
    this.emptyMessage = 'Mulai percakapan dengan agen.',
    this.padding = const EdgeInsets.all(12),
  });

  final List<TikoChatMessage> messages;

  /// Dipanggil saat pengguna mengirim teks (tidak kosong).
  final void Function(String text) onSend;

  /// Render blok ```genui pada pesan asisten (butuh agent_core).
  final bool renderGenUi;

  /// Menonaktifkan input saat agen sedang memproses.
  final bool busy;

  final String hintText;
  final String emptyMessage;
  final EdgeInsetsGeometry padding;

  @override
  State<TikoChatInterface> createState() => _TikoChatInterfaceState();
}

class _TikoChatInterfaceState extends State<TikoChatInterface> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy) return;
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: Column(
        children: [
          Expanded(
            child: widget.messages.isEmpty
                ? Center(
                    child: Text(
                      widget.emptyMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).hintColor,
                          ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: widget.messages.length,
                    itemBuilder: (context, i) {
                      final m = widget.messages[i];
                      final isUser = m.role == 'user';
                      final align = isUser
                          ? Alignment.bottomRight
                          : Alignment.bottomLeft;
                      final color = m.error
                          ? Theme.of(context).colorScheme.errorContainer
                          : isUser
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest;
                      return Align(
                        alignment: align,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.sizeOf(context).width * 0.8,
                          ),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: isUser || m.error || !widget.renderGenUi
                              ? SelectableText(
                                  m.text,
                                  style: TextStyle(
                                    height: 1.4,
                                    color: m.error
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onErrorContainer
                                        : null,
                                  ),
                                )
                              : _assistantBody(context, m.text),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !widget.busy,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: widget.busy ? 'Memproses…' : widget.hintText,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: widget.busy ? null : _send,
                icon: const Icon(Icons.send),
                tooltip: 'Kirim',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Body asisten dengan dukungan GenUI (D1): blok ```genui dirender
  /// jadi widget; segmen teks biasa tetap selectable. Fail-closed sudah
  /// ditangani di dalam [GenUiMessageView].
  Widget _assistantBody(BuildContext context, String text) =>
      GenUiMessageView(text: text);
}
