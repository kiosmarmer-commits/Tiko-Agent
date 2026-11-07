import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'text_split.dart';
import 'stt.dart';

/// Telegram Bot API long-polling gateway (TASK-05-02).
/// Pure Dart (no televerse) so it runs on server/Termux without Flutter.
class TelegramGateway implements Gateway {
  TelegramGateway({
    required this.token,
    this.stt,
    required this.allowedUserIds,
    this.httpClient,
    this.pollTimeoutSec = 25,
  });

  final String token;
  final SttClient? stt;
  final Set<int> allowedUserIds;
  final http.Client? httpClient;
  final int pollTimeoutSec;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _pendingConfirm = <String, Completer<bool>>{};
  int _offset = 0;
  bool _running = false;
  Timer? _pollTimer;

  @override
  String get channel => 'telegram';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  Uri _api(String method) =>
      Uri.parse('https://api.telegram.org/bot$token/$method');

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> body,
  ) async {
    final client = httpClient ?? http.Client();
    try {
      final res = await client.post(
        _api(method),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['ok'] != true) {
        throw StateError('Telegram API error: ${res.body}');
      }
      return json;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Start long-polling loop.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_pollLoop());
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final client = httpClient ?? http.Client();
        try {
          final uri = _api('getUpdates').replace(
            queryParameters: {
              'offset': '$_offset',
              'timeout': '$pollTimeoutSec',
              'allowed_updates': jsonEncode(['message', 'callback_query']),
            },
          );
          final res = await client
              .get(uri)
              .timeout(Duration(seconds: pollTimeoutSec + 10));
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          if (json['ok'] == true) {
            final updates = json['result'] as List<dynamic>? ?? [];
            for (final u in updates) {
              await _handleUpdate(u as Map<String, dynamic>);
            }
          }
        } finally {
          if (httpClient == null) client.close();
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _handleUpdate(Map<String, dynamic> update) async {
    final updateId = update['update_id'] as int? ?? 0;
    if (updateId >= _offset) _offset = updateId + 1;

    // Callback query (inline confirm buttons)
    final cb = update['callback_query'] as Map<String, dynamic>?;
    if (cb != null) {
      final from = cb['from'] as Map<String, dynamic>? ?? {};
      final uid = from['id'] as int? ?? 0;
      if (!_allowed(uid)) return;
      final data = cb['data'] as String? ?? '';
      final completer = _pendingConfirm.remove(data);
      if (completer != null && !completer.isCompleted) {
        completer.complete(data.endsWith(':yes'));
      }
      final cqId = cb['id'] as String?;
      if (cqId != null) {
        try {
          await _post('answerCallbackQuery', {'callback_query_id': cqId});
        } catch (_) {}
      }
      return;
    }

    final msg = update['message'] as Map<String, dynamic>?;
    if (msg == null) return;
    final from = msg['from'] as Map<String, dynamic>? ?? {};
    final uid = from['id'] as int? ?? 0;
    if (!_allowed(uid)) {
      // ignore silently + could log
      return;
    }
    final chat = msg['chat'] as Map<String, dynamic>? ?? {};
    final chatId = chat['id'];
    var text = msg['text'] as String? ?? '';
    // Voice / audio STT
    if (text.isEmpty && stt != null) {
      final voice =
          msg['voice'] as Map<String, dynamic>? ??
          msg['audio'] as Map<String, dynamic>?;
      if (voice != null) {
        final fileId = voice['file_id'] as String?;
        if (fileId != null) {
          final transcript = await _downloadAndStt(fileId);
          if (transcript != null && transcript.isNotEmpty) {
            text = transcript;
          }
        }
      }
    }
    if (text.isEmpty) return;

    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: '$uid',
        sessionKey: 'tg:$chatId',
        text: text,
        meta: {
          'chat_id': chatId,
          'message_id': msg['message_id'],
          'username': from['username'],
        },
      ),
    );
  }

  bool _allowed(int uid) {
    if (allowedUserIds.isEmpty) return false; // default-deny
    return allowedUserIds.contains(uid);
  }

  Future<String?> _downloadAndStt(String fileId) async {
    if (stt == null) return null;
    Directory? tempDir;
    try {
      final fileResponse = await _post('getFile', {'file_id': fileId});
      final filePath =
          (fileResponse['result'] as Map<String, dynamic>?)?['file_path']
              as String?;
      if (filePath == null || filePath.isEmpty) return null;

      tempDir = await Directory.systemTemp.createTemp('agent_dart_telegram_');
      final localPath = '${tempDir.path}/${filePath.split('/').last}';
      final client = httpClient ?? http.Client();
      try {
        final response = await client.get(
          Uri.parse('https://api.telegram.org/file/bot$token/$filePath'),
        );
        if (response.statusCode >= 400) return null;
        await File(localPath).writeAsBytes(response.bodyBytes, flush: true);
      } finally {
        if (httpClient == null) client.close();
      }
      return await stt!.transcribeFile(localPath);
    } catch (_) {
      return null;
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final chatId = m.sessionKey.startsWith('tg:')
        ? m.sessionKey.substring(3)
        : m.sessionKey;

    final chunks = splitMessage(m.text, maxLen: 3500);
    for (var i = 0; i < chunks.length; i++) {
      final body = <String, dynamic>{
        'chat_id': chatId,
        'text': chunks[i],
        'parse_mode': m.markdown ? 'Markdown' : null,
      };
      body.removeWhere((k, v) => v == null);
      if (i == 0 && m.buttons.isNotEmpty) {
        body['reply_markup'] = {
          'inline_keyboard': [
            m.buttons
                .map((b) => {'text': b.label, 'callback_data': b.id})
                .toList(),
          ],
        };
      }
      await _post('sendMessage', body);
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    final chatId = sessionKey.startsWith('tg:')
        ? sessionKey.substring(3)
        : sessionKey;
    try {
      await _post('sendChatAction', {'chat_id': chatId, 'action': 'typing'});
    } catch (_) {}
  }

  /// Request confirmation via inline buttons; returns false on timeout (120s).
  Future<bool> requestConfirm({
    required String sessionKey,
    required String prompt,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final id = 'c${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<bool>();
    _pendingConfirm['$id:yes'] = completer;
    // also track no as same completer path
    final noCompleter = Completer<bool>();
    _pendingConfirm['$id:no'] = noCompleter;

    await send(
      OutboundMessage(
        sessionKey: sessionKey,
        text: prompt,
        buttons: [
          ConfirmButton(id: '$id:yes', label: '✅ Izinkan'),
          ConfirmButton(id: '$id:no', label: '❌ Tolak'),
        ],
      ),
    );

    final result = await Future.any([
      completer.future,
      noCompleter.future.then((_) => false),
      Future<bool>.delayed(timeout, () => false),
    ]);
    _pendingConfirm.remove('$id:yes');
    _pendingConfirm.remove('$id:no');
    return result;
  }

  Future<void> close() async {
    await stop();
    await _inbound.close();
  }
}
