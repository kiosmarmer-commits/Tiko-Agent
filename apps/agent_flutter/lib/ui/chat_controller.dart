import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../agent_api_client.dart' show ChatAttachmentPayload;
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

  /// C4 Chat-UX: status strip turn aktif — nama tool yang sedang dieksekusi
  /// (dari frame `chat.toolStart`) dan sinyal stop yang sudah dikirim.
  String? activeTool;
  bool stopRequested = false;

  /// C4 Chat-UX: trace tool turn terakhir (`chat.tool`) untuk ringkasan
  /// collapsible + kartu file otomatis; nama + durasi + status error.
  final List<Map<String, dynamic>> lastTurnTrace = [];

  /// C4: minta daemon menghentikan turn aktif (kooperatif via cancel token
  /// runtime). Tidak ada jaminan langsung; UI menampilkan "Menghentikan…"
  /// sampai frame akhir (done/error) datang.
  Future<void> stop() async {
    if (!busy || stopRequested) return;
    stopRequested = true;
    notifyListeners();
    try {
      await repo.cancelTurn(sessionKey);
    } catch (_) {
      // Kegagalan jaringan saat cancel tidak mengubah hasil turn yang
      // tetap mengalir lewat frame done/error; strip menandai jujur.
    }
  }

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

  Future<void> send(
    String text, {
    String? sessionKey,
    List<ChatAttachmentPayload> attachments = const [],
  }) async {
    final sk = sessionKey ?? this.sessionKey;
    final t = text.trim();
    if (t.isEmpty || busy) return;
    busy = true;
    // C2 Chat-UX: lampiran ditampilkan jujur sebagai ringkasan di gelembung
    // user (isi file nyata diekspansi runtime menjadi konteks `[lampiran:]`).
    final label = attachments.isEmpty
        ? t
        : '$t\n📎 ${attachments.map((a) => a.name).join(', ')}';
    messages.add({'role': 'user', 'text': label});
    messages.add({'role': 'assistant', 'text': '…'});
    notifyListeners();
    final aiIndex = messages.length - 1;
    activeTool = null;
    stopRequested = false;
    lastTurnTrace.clear();

    try {
      if (useStreaming) {
        await for (
          final ev in repo.streamChat(t, sessionKey: sk, attachments: attachments)
        ) {
          final type = ev['type'] as String? ?? '';
          if (type == 'typing') {
            messages[aiIndex]['text'] = 'Menulis…';
            notifyListeners();
          } else if (type == 'chat.status') {
            final state = ev['state'] as String? ?? '';
            if (state == 'running') {
              messages[aiIndex]['text'] = 'Menyusun…';
              notifyListeners();
            }
          } else if (type == 'chat.toolStart') {
            activeTool = ev['name'] as String? ?? '';
            notifyListeners();
          } else if (type == 'chat.tool') {
            activeTool = null;
            lastTurnTrace.add({
              'name': ev['name'] as String? ?? '',
              'is_error': ev['is_error'] == true,
              'duration_ms': (ev['duration_ms'] as num?)?.toInt() ?? 0,
              'path': ev['path'] as String?,
            });
            notifyListeners();
          } else if (type == 'text') {
            final t = ev['text'] as String? ?? '';
            if (t.isNotEmpty) messages[aiIndex]['text'] = t;
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
            if (cur == '…' || cur == 'Menulis…' || cur == 'Menyusun…') {
              messages[aiIndex]['text'] =
                  stopRequested ? '(turn dihentikan)' : '(selesai)';
            }
            _applyTurnFiles(aiIndex);
            activeTool = null;
            notifyListeners();
          }
        }
      } else {
        final reply =
            await repo.sendMessage(t, sessionKey: sk, attachments: attachments);
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
      activeTool = null;
      notifyListeners();
    }
  }

  /// C4 + C3: sumber OTOMATIS kartu file chat — path dari frame `chat.tool`
  /// (arg `path` tool file builtin, sudah tersanitasi runtime); flag
  /// "berubah" hanya untuk tool tulis. Kartu tetap read-only; Diff memakai
  /// endpoint `/v1/artifacts/diff` yang memvalidasi path di server.
  void _applyTurnFiles(int aiIndex) {
    const writeTools = {'write_file', 'patch_file'};
    final files = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final t in lastTurnTrace) {
      final path = t['path'] as String?;
      if (path == null || path.isEmpty || !seen.add(path)) continue;
      files.add({
        'path': path,
        'changed': writeTools.contains(t['name']),
      });
    }
    if (files.isNotEmpty) {
      messages[aiIndex]['files'] = jsonEncode(files);
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
    lastTurnTrace.clear();
    activeTool = null;
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
    String? surfaceId,
  }) async {
    final sk = sessionKey ?? this.sessionKey;
    if (busy) return;
    final echo = values.isEmpty ? actionId : '$actionId ${jsonEncode(values)}';
    busy = true;
    messages.add({
      'role': 'user',
      'text': echo,
      if (surfaceId != null) 'surface_id': surfaceId,
    });
    messages.add({'role': 'assistant', 'text': '…'});
    notifyListeners();
    final aiIndex = messages.length - 1;
    try {
      final reply =
          await repo.submitUiAction(sk, actionId, values, surfaceId: surfaceId);
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
