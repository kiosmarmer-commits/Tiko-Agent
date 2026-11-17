import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/agent_repository.dart';
import '../data/api_error.dart';

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
  ChatController(this.repo, {this.sessionKey = 'flutter:default'});

  AgentRepository repo;
  String sessionKey;

  final messages = <Map<String, String>>[];
  bool busy = false;
  bool online = false;
  String? statusLabel;
  ConfirmRequest? pendingConfirm;
  bool useStreaming = true;

  Future<void> checkOnline() async {
    online = await repo.health();
    if (online) {
      try {
        final s = await repo.status();
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
        await for (final ev in repo.streamChat(t, sessionKey: sk)) {
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
        final reply = await repo.sendMessage(t, sessionKey: sk);
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
      final decided = await repo.decideApproval(request.id, allow);
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

  /// Typed GenUI action (GUI-P0-04): kirim aksi form/tombol via endpoint
  /// tervalidasi daemon. Bila daemon lama belum mendukung (501), fallback ke
  /// jalur teks lama `/ui ...`; kegagalan lain tampil sebagai pesan system
  /// tanpa mengirim ulang (menghindari side effect ganda).
  Future<void> sendUiAction(
    String actionId,
    Map<String, dynamic> values, {
    String? sessionKey,
  }) async {
    final sk = sessionKey ?? this.sessionKey;
    if (busy) return;
    final echo = values.isEmpty ? actionId : '$actionId ${jsonEncode(values)}';
    busy = true;
    messages.add({'role': 'user', 'text': echo});
    messages.add({'role': 'assistant', 'text': '…'});
    notifyListeners();
    final aiIndex = messages.length - 1;
    try {
      final reply = await repo.submitUiAction(sk, actionId, values);
      messages[aiIndex]['text'] = reply.isEmpty ? '(kosong)' : reply;
    } catch (e) {
      messages.removeRange(messages.length - 2, messages.length);
      busy = false;
      notifyListeners();
      if (e is ApiError && e.statusCode == 501) {
        await send('/ui $echo', sessionKey: sk);
      } else {
        messages.add({'role': 'system', 'text': 'Gagal mengirim aksi UI: $e'});
        notifyListeners();
      }
      return;
    }
    busy = false;
    notifyListeners();
  }

  /// Memuat transcript sesi dari daemon dan mengganti isi chat. Dipakai saat
  /// pengguna memilih sesi lama di halaman Sessions, sehingga riwayat
  /// percakapan terlihat kembali, bukan sekadar chat kosong.
  Future<void> openSession(String sessionKey, {int limit = 200}) async {
    try {
      final list = await repo.sessionMessages(sessionKey, limit: limit);
      messages
        ..clear()
        ..addAll([
          for (final m in list)
            {'role': m.role, 'text': m.content},
        ]);
    } catch (e) {
      messages
        ..clear()
        ..add({
          'role': 'system',
          'text': 'Gagal memuat transcript sesi: $e',
        });
    }
    notifyListeners();
  }
}
