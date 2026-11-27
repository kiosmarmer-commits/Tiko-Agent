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

enum AgentActivityPhase {
  idle,
  submitting,
  processing,
  writing,
  tool,
  approval,
  stopping,
  complete,
  failed,
  cancelled,
}

class ChatController extends ChangeNotifier {
  ChatController(this.repo, {this.sessionKey = 'flutter:default'});

  AgentRepository repo;
  String sessionKey;

  final messages = <Map<String, String>>[];
  bool busy = false;
  AgentActivityPhase activityPhase = AgentActivityPhase.idle;
  bool online = false;
  String? statusLabel;
  ConfirmRequest? pendingConfirm;
  bool useStreaming = true;

  /// C4 Chat-UX: status strip turn aktif — nama tool yang sedang dieksekusi
  /// (dari frame `chat.toolStart`) dan sinyal stop yang sudah dikirim.
  String? activeTool;
  final Map<String, String> _activeToolCalls = {};
  int _legacyToolCallId = 0;
  int get activeToolCount => _activeToolCalls.length;
  bool stopRequested = false;
  String? _activeSessionKey;

  /// LEARN-01: key sesi turn aktif (fallback ke [sessionKey]) — dipakai
  /// UI untuk feedback 👍/👎 tingkat turn.
  String get activeSessionKey => _activeSessionKey ?? sessionKey;

  /// C4 Chat-UX: trace tool turn terakhir (`chat.tool`) untuk ringkasan
  /// collapsible + kartu file otomatis; nama + durasi + status error.
  final List<Map<String, dynamic>> lastTurnTrace = [];

  /// Prompt terakhir yang gagal dikirim. UI menawarkan retry eksplisit;
  /// tidak ada replay otomatis karena request bisa saja sudah diterima daemon.
  String? retryText;
  List<ChatAttachmentPayload> retryAttachments = const [];

  /// C4: minta daemon menghentikan turn aktif (kooperatif via cancel token
  /// runtime). Tidak ada jaminan langsung; UI menampilkan "Menghentikan…"
  /// sampai frame akhir (done/error) datang.
  Future<void> stop() async {
    if (!busy || stopRequested) return;
    stopRequested = true;
    activityPhase = AgentActivityPhase.stopping;
    notifyListeners();
    try {
      final accepted = await repo.cancelTurn(_activeSessionKey ?? sessionKey);
      if (!accepted && busy) {
        _reportStopNotAccepted();
      }
    } catch (_) {
      if (busy) _reportStopNotAccepted();
    }
  }

  void _reportStopNotAccepted() {
    stopRequested = false;
    if (activityPhase == AgentActivityPhase.stopping) {
      activityPhase = _activeToolCalls.isEmpty
          ? AgentActivityPhase.processing
          : AgentActivityPhase.tool;
      activeTool = _activeToolCalls.isEmpty
          ? null
          : _activeToolCalls.values.last;
    }
    messages.add({
      'role': 'system',
      'text': 'Daemon belum mengonfirmasi penghentian. Turn masih berjalan.',
    });
    notifyListeners();
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
    _activeSessionKey = sk;
    activityPhase = AgentActivityPhase.submitting;
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
    _activeToolCalls.clear();
    stopRequested = false;
    lastTurnTrace.clear();
    retryText = null;
    retryAttachments = const [];
    var failed = false;
    var receivedTerminalFrame = false;

    try {
      if (useStreaming) {
        await for (final ev in repo.streamChat(
          t,
          sessionKey: sk,
          attachments: attachments,
        )) {
          final type = ev['type'] as String? ?? '';
          if (type == 'typing') {
            activityPhase = AgentActivityPhase.writing;
            messages[aiIndex]['text'] = 'Menulis…';
            notifyListeners();
          } else if (type == 'chat.status') {
            final state = ev['state'] as String? ?? '';
            if (state == 'running') {
              activityPhase = AgentActivityPhase.processing;
              messages[aiIndex]['text'] = 'Menyusun…';
              notifyListeners();
            }
          } else if (type == 'chat.delta') {
            final d = ev['text'] as String? ?? '';
            if (d.isNotEmpty) {
              activityPhase = AgentActivityPhase.writing;
              final cur = messages[aiIndex]['text'] ?? '';
              final placeholder =
                  cur == '…' || cur == 'Menulis…' || cur == 'Menyusun…';
              messages[aiIndex]['text'] = placeholder ? d : cur + d;
              notifyListeners();
            }
          } else if (type == 'chat.toolStart') {
            final toolName = ev['name'] as String? ?? '';
            final eventCallId = ev['call_id'] as String?;
            final callId = eventCallId == null || eventCallId.isEmpty
                ? 'legacy:${_legacyToolCallId++}'
                : eventCallId;
            _activeToolCalls[callId] = toolName;
            activeTool = toolName;
            activityPhase = AgentActivityPhase.tool;
            lastTurnTrace.add({
              'call_id': callId,
              'name': activeTool,
              'is_error': false,
              'duration_ms': 0,
              'status': 'running',
            });
            notifyListeners();
          } else if (type == 'chat.tool') {
            final toolName = ev['name'] as String? ?? '';
            final callId = ev['call_id'] as String?;
            final runningIndex = callId != null && callId.isNotEmpty
                ? lastTurnTrace.lastIndexWhere(
                    (tool) =>
                        tool['status'] == 'running' &&
                        tool['call_id'] == callId,
                  )
                : lastTurnTrace.lastIndexWhere(
                    (tool) =>
                        tool['status'] == 'running' &&
                        tool['name'] == toolName,
                  );
            final activeCallId = runningIndex < 0
                ? callId
                : lastTurnTrace[runningIndex]['call_id'] as String?;
            if (activeCallId != null) _activeToolCalls.remove(activeCallId);
            activeTool = _activeToolCalls.isEmpty
                ? null
                : _activeToolCalls.values.last;
            activityPhase = _activeToolCalls.isEmpty
                ? AgentActivityPhase.processing
                : AgentActivityPhase.tool;
            final result = <String, dynamic>{
              if (callId != null && callId.isNotEmpty) 'call_id': callId,
              'name': toolName,
              'is_error': ev['is_error'] == true,
              'duration_ms': (ev['duration_ms'] as num?)?.toInt() ?? 0,
              'path': ev['path'] as String?,
              'status': ev['is_error'] == true ? 'failed' : 'complete',
            };
            if (runningIndex >= 0) {
              lastTurnTrace[runningIndex] = result;
            } else {
              lastTurnTrace.add(result);
            }
            notifyListeners();
          } else if (type == 'text') {
            final t = ev['text'] as String? ?? '';
            if (t.isNotEmpty) {
              activityPhase = AgentActivityPhase.writing;
              messages[aiIndex]['text'] = t;
            }
            notifyListeners();
          } else if (type == 'confirm') {
            final id = ev['id'] as String? ?? '';
            if (id.isNotEmpty) {
              activityPhase = AgentActivityPhase.approval;
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
                activityPhase = AgentActivityPhase.processing;
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
            receivedTerminalFrame = true;
            failed = true;
            activityPhase = AgentActivityPhase.failed;
            retryText = t;
            retryAttachments = List.of(attachments);
            messages[aiIndex]['text'] = 'Gagal: ${ev['message']}';
            notifyListeners();
          } else if (type == 'done') {
            receivedTerminalFrame = true;
            activityPhase = failed
                ? AgentActivityPhase.failed
                : stopRequested
                ? AgentActivityPhase.cancelled
                : AgentActivityPhase.complete;
            final cur = messages[aiIndex]['text'];
            if (cur == '…' || cur == 'Menulis…' || cur == 'Menyusun…') {
              messages[aiIndex]['text'] = stopRequested
                  ? '(turn dihentikan)'
                  : '(selesai)';
            }
            _applyTurnFiles(aiIndex);
            _activeToolCalls.clear();
            activeTool = null;
            if (!failed) retryText = null;
            notifyListeners();
          }
        }
        if (!receivedTerminalFrame) {
          failed = true;
          activityPhase = AgentActivityPhase.failed;
          retryText = t;
          retryAttachments = List.of(attachments);
          messages[aiIndex]['text'] =
              'Gagal: koneksi ditutup sebelum turn selesai.';
          notifyListeners();
        }
      } else {
        activityPhase = AgentActivityPhase.processing;
        notifyListeners();
        final reply = await repo.sendMessage(
          t,
          sessionKey: sk,
          attachments: attachments,
        );
        messages[aiIndex]['text'] = reply.isEmpty ? '(kosong)' : reply;
        activityPhase = AgentActivityPhase.complete;
        notifyListeners();
      }
    } catch (e) {
      // Do not replay the same prompt over HTTP after a WebSocket failure:
      // the server may already have accepted it and started side effects.
      // The user can explicitly retry after checking the session state.
      messages[aiIndex]['text'] = 'Gagal: $e';
      activityPhase = AgentActivityPhase.failed;
      retryText = t;
      retryAttachments = List.of(attachments);
      notifyListeners();
    } finally {
      for (final step in lastTurnTrace) {
        if (step['status'] == 'running') {
          step['status'] = 'interrupted';
        }
      }
      if (activityPhase == AgentActivityPhase.submitting ||
          activityPhase == AgentActivityPhase.processing ||
          activityPhase == AgentActivityPhase.writing ||
          activityPhase == AgentActivityPhase.tool ||
          activityPhase == AgentActivityPhase.approval ||
          activityPhase == AgentActivityPhase.stopping) {
        activityPhase = stopRequested
            ? AgentActivityPhase.cancelled
            : failed
            ? AgentActivityPhase.failed
            : AgentActivityPhase.complete;
      }
      busy = false;
      _activeSessionKey = null;
      _activeToolCalls.clear();
      activeTool = null;
      notifyListeners();
    }
  }

  /// Mengulang prompt terakhir yang gagal setelah user menekan Retry.
  /// Pesan user/error lama dibuang agar transcript tidak menggandakan turn.
  Future<void> retryLast({String? sessionKey}) async {
    final text = retryText;
    if (text == null || busy) return;
    final attachments = List<ChatAttachmentPayload>.of(retryAttachments);
    if (messages.length >= 2 &&
        messages.last['role'] == 'assistant' &&
        messages[messages.length - 2]['role'] == 'user') {
      messages.removeRange(messages.length - 2, messages.length);
    }
    retryText = null;
    retryAttachments = const [];
    notifyListeners();
    await send(text, sessionKey: sessionKey, attachments: attachments);
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
      files.add({'path': path, 'changed': writeTools.contains(t['name'])});
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
          'text':
              'Persetujuan ${request.id} tidak lagi pending atau sudah kedaluwarsa.',
        });
      }
    } catch (error) {
      // Keep the same request visible so the user can retry. A network error
      // does not prove whether the daemon received the decision.
      messages.add({
        'role': 'system',
        'text': 'Gagal mengirim keputusan: $error',
      });
    } finally {
      if (settled && pendingConfirm?.id == request.id) pendingConfirm = null;
      notifyListeners();
    }
  }

  void clearChat() {
    messages.clear();
    lastTurnTrace.clear();
    _activeToolCalls.clear();
    activeTool = null;
    activityPhase = AgentActivityPhase.idle;
    retryText = null;
    retryAttachments = const [];
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
    activityPhase = AgentActivityPhase.submitting;
    messages.add({
      'role': 'user',
      'text': echo,
      if (surfaceId != null) 'surface_id': surfaceId,
    });
    messages.add({'role': 'assistant', 'text': '…'});
    notifyListeners();
    final aiIndex = messages.length - 1;
    try {
      final reply = await repo.submitUiAction(
        sk,
        actionId,
        values,
        surfaceId: surfaceId,
      );
      messages[aiIndex]['text'] = reply.isEmpty ? '(kosong)' : reply;
      activityPhase = AgentActivityPhase.complete;
    } catch (e) {
      messages.removeRange(messages.length - 2, messages.length);
      busy = false;
      activityPhase = AgentActivityPhase.failed;
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
    activityPhase = AgentActivityPhase.complete;
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
          for (final m in list) {'role': m.role, 'text': m.content},
        ]);
    } catch (e) {
      messages
        ..clear()
        ..add({'role': 'system', 'text': 'Gagal memuat transcript sesi: $e'});
    }
    notifyListeners();
  }
}
