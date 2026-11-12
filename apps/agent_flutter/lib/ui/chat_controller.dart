import 'package:flutter/foundation.dart';

import '../agent_api_client.dart';

class ChatMessageVm {
  ChatMessageVm({required this.role, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final String role; // user | assistant | system
  String text;
  final DateTime at;
}

class ConfirmRequest {
  ConfirmRequest({required this.id, required this.prompt});
  final String id;
  final String prompt;
}

class ChatController extends ChangeNotifier {
  ChatController(this.client, {this.sessionKey = 'flutter:default'});

  AgentApiClient client;
  String sessionKey;

  final messages = <Map<String, String>>[];
  bool busy = false;
  bool online = false;
  String? statusLabel;
  ConfirmRequest? pendingConfirm;
  bool useStreaming = true;

  Future<void> checkOnline() async {
    online = await client.health();
    if (online) {
      try {
        final s = await client.status();
        final p = s['provider'];
        statusLabel = p != null ? 'online · $p' : 'online';
      } catch (_) {
        statusLabel = 'online';
      }
    } else {
      statusLabel = 'offline';
    }
    notifyListeners();
  }

  Future<void> send(String text, {String? sessionKey}) async {
    final sk = sessionKey ?? this.sessionKey;
    final t = text.trim();
    if (t.isEmpty || busy) return;
    busy = true;
    messages.add({'role': 'user', 'text': t});
    messages.add({'role': 'assistant', 'text': '…'});
    notifyListeners();
    final aiIndex = messages.length - 1;

    try {
      if (useStreaming) {
        await for (final ev in client.streamChat(t, sessionKey: sk)) {
          final type = ev['type'] as String? ?? '';
          if (type == 'typing') {
            messages[aiIndex]['text'] = 'Menulis…';
            notifyListeners();
          } else if (type == 'text') {
            messages[aiIndex]['text'] = ev['text'] as String? ?? '';
            notifyListeners();
          } else if (type == 'confirm') {
            final id = ev['id'] as String? ?? '';
            if (id.isNotEmpty) {
              pendingConfirm = ConfirmRequest(
                id: id,
                prompt: ev['prompt'] as String? ?? 'Izinkan tool?',
              );
              notifyListeners();
            }
          } else if (type == 'event') {
            final event = ev['event'];
            if (event is Map) {
              final eventType = event['type'] as String? ?? '';
              final eventId = event['id'] as String? ?? '';
              if (eventType == 'approval.decided' &&
                  pendingConfirm?.id == eventId) {
                final state = event['state'] as String? ?? 'decided';
                pendingConfirm = null;
                if (state != 'approved') {
                  messages.add({
                    'role': 'system',
                    'text': 'Persetujuan $eventId: $state.',
                  });
                }
                notifyListeners();
              }
            }
          } else if (type == 'error') {
            messages[aiIndex]['text'] = 'Gagal: ${ev['message']}';
            notifyListeners();
          } else if (type == 'done') {
            final cur = messages[aiIndex]['text'];
            if (cur == '…' || cur == 'Menulis…') {
              messages[aiIndex]['text'] = '(selesai)';
            }
            notifyListeners();
          }
        }
      } else {
        final reply = await client.sendMessage(t, sessionKey: sk);
        messages[aiIndex]['text'] = reply.isEmpty ? '(kosong)' : reply;
        notifyListeners();
      }
    } catch (e) {
      // Do not replay the same prompt over HTTP after a WebSocket failure:
      // the server may already have accepted it and started side effects.
      // The user can explicitly retry after checking the session state.
      messages[aiIndex]['text'] = 'Gagal: $e';
      notifyListeners();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> respondConfirm(bool allow) async {
    final request = pendingConfirm;
    if (request == null) return;
    var settled = false;
    try {
      final decided = await client.decideApproval(request.id, allow);
      settled = true;
      if (!decided) {
        messages.add({
          'role': 'system',
          'text': 'Persetujuan ${request.id} tidak lagi pending atau sudah kedaluwarsa.',
        });
      }
    } catch (error) {
      // Keep the same request visible so the user can retry. A network error
      // does not prove whether the daemon received the decision.
      messages.add({'role': 'system', 'text': 'Gagal mengirim keputusan: $error'});
    } finally {
      if (settled && pendingConfirm?.id == request.id) pendingConfirm = null;
      notifyListeners();
    }
  }

  void clearChat() {
    messages.clear();
    notifyListeners();
  }
}
