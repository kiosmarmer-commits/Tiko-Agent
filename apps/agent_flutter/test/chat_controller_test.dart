import 'dart:async';
import 'dart:convert';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/ui/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAgentApiClient extends AgentApiClient {
  _FakeAgentApiClient() : super(baseUrl: 'http://127.0.0.1:1', token: 'test');

  int sendMessageCalls = 0;
  final recordedAttachments = <List<ChatAttachmentPayload>>[];
  final decisions = <({String id, bool allow})>[];
  bool failDecision = false;
  int cancelCalls = 0;
  Stream<Map<String, dynamic>> Function(String text)? streamHandler;

  @override
  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
    List<ChatAttachmentPayload> attachments = const [],
  }) {
    recordedAttachments.add(attachments);
    return streamHandler?.call(text) ?? const Stream.empty();
  }

  @override
  Future<String> sendMessage(
    String text, {
    String sessionKey = 'flutter:default',
    List<ChatAttachmentPayload> attachments = const [],
  }) async {
    sendMessageCalls++;
    return 'fallback reply';
  }

  @override
  Future<bool> decideApproval(String id, bool approve) async {
    if (failDecision) throw StateError('network unavailable');
    decisions.add((id: id, allow: approve));
    return true;
  }

  @override
  Future<bool> cancelTurn(String sessionKey) async {
    cancelCalls++;
    return true;
  }
}

void main() {
  test('WebSocket failure does not replay the prompt over HTTP', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        throw StateError('connection dropped after send');
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('buat file');

    expect(client.sendMessageCalls, 0);
    expect(controller.messages.last['text'], contains('connection dropped'));
  });

  test('chat.delta mengalirkan teks assistant secara bertahap', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'chat.status', 'state': 'running'};
        yield {'type': 'chat.delta', 'text': 'Halo, '};
        yield {'type': 'chat.toolStart', 'name': 'read_file'};
        yield {'type': 'chat.delta', 'text': 'ini jawaban'};
        yield {
          'type': 'chat.tool',
          'name': 'read_file',
          'is_error': false,
          'duration_ms': 120,
        };
        yield {'type': 'text', 'text': 'Halo, ini jawaban lengkap'};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    final snapshots = <String>[];
    controller.addListener(() {
      final t = controller.messages.last['text'] ?? '';
      if (snapshots.isEmpty || snapshots.last != t) snapshots.add(t);
    });

    await controller.send('sapa');

    expect(snapshots, contains('Halo, '));
    expect(snapshots, contains('Halo, ini jawaban'));
    expect(controller.messages.last['text'], 'Halo, ini jawaban lengkap');
    expect(controller.lastTurnTrace, hasLength(1));
  });

  test('retryLast mengulang prompt hanya setelah user meminta retry', () async {
    var attempts = 0;
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        attempts++;
        if (attempts == 1) {
          throw StateError('temporary failure');
        }
        yield {'type': 'text', 'text': 'berhasil pada percobaan kedua'};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('coba lagi nanti');

    expect(attempts, 1);
    expect(controller.retryText, 'coba lagi nanti');
    expect(controller.messages.last['text'], contains('temporary failure'));

    await controller.retryLast();

    expect(attempts, 2);
    expect(controller.retryText, isNull);
    expect(controller.messages.map((m) => m['text']).toList(), [
      'coba lagi nanti',
      'berhasil pada percobaan kedua',
    ]);
  });

  test('approval decided in another UI surface clears the chat prompt', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_123', 'prompt': 'Izinkan write_file?'};
        yield {
          'type': 'event',
          'event': {'type': 'approval.decided', 'id': 'apr_123', 'state': 'approved'},
        };
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('buat file');

    expect(controller.pendingConfirm, isNull);
    expect(controller.messages.where((message) => message['role'] == 'system'), isEmpty);
  });

  test('approval stays visible after a network error so the user can retry', () async {
    final client = _FakeAgentApiClient()
      ..failDecision = true
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_retry', 'prompt': 'Izinkan write_file?'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('buat file');
    await controller.respondConfirm(true);

    expect(controller.pendingConfirm?.id, 'apr_retry');
  });

  test('chat approval sends the broker request ID to the API', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_456', 'prompt': 'Izinkan write_file?'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('buat file');
    await controller.respondConfirm(true);

    expect(client.decisions, [(id: 'apr_456', allow: true)]);
    expect(controller.pendingConfirm, isNull);
  });


  test('lampiran composer diteruskan ke streamChat dan tampil di gelembung user', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'typing'};
        yield {'type': 'text', 'text': 'hasil lampiran'};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('analisis ini', attachments: [
      ChatAttachmentPayload(
        name: 'laporan.md',
        mime: 'text/plain',
        dataBase64: 'aGVsbG8=',
      ),
    ]);

    expect(client.recordedAttachments.single.single.name, 'laporan.md');
    expect(
      controller.messages.any((m) => m['text'].toString().contains('laporan.md')),
      isTrue,
    );
    expect(controller.messages.last['text'], 'hasil lampiran');
  });

  test('lampiran gambar tersimpan di bubble user untuk pratinjau thumbnail',
      () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'text', 'text': 'oke'};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('lihat gambar ini', attachments: [
      ChatAttachmentPayload(
        name: 'foto.png',
        mime: 'image/png',
        dataBase64: 'aGVsbG8=',
      ),
      ChatAttachmentPayload(
        name: 'catatan.txt',
        mime: 'text/plain',
        dataBase64: 'aGVsbG8=',
      ),
    ]);

    final userMessage = controller.messages.firstWhere(
      (m) => m['role'] == 'user',
    );
    expect(userMessage['attachments'], isNotNull);
    final parsed = jsonDecode(userMessage['attachments']!) as List;
    expect(parsed, hasLength(2));
    expect((parsed.first as Map)['mime'], 'image/png');
    expect((parsed.first as Map)['data_base64'], 'aGVsbG8=');
  });

  test('C4: frame chat.tool* mengisi trace dan kartu file otomatis muncul',
      () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'chat.status', 'state': 'running'};
        yield {'type': 'chat.toolStart', 'name': 'write_file'};
        yield {
          'type': 'chat.tool',
          'name': 'write_file',
          'is_error': false,
          'duration_ms': 24,
          'path': 'catatan.txt',
        };
        yield {'type': 'chat.toolStart', 'name': 'read_file'};
        yield {
          'type': 'chat.tool',
          'name': 'read_file',
          'is_error': true,
          'duration_ms': 3,
          'path': 'catatan.txt',
        };
        yield {'type': 'text', 'text': 'selesai menulis'};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.send('tulis catatan');

    expect(controller.lastTurnTrace, hasLength(2));
    expect(controller.lastTurnTrace.first['name'], 'write_file');
    expect(controller.lastTurnTrace.last['is_error'], isTrue);
    expect(controller.activeTool, isNull);
    final files = jsonDecode(controller.messages.last['files']!) as List;
    expect(files, hasLength(1));
    expect((files.single as Map)['path'], 'catatan.txt');
    expect((files.single as Map)['changed'], isTrue);
  });

  test('C4: stop() mengirim cancelTurn dan menandai strip jika busy',
      () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'chat.status', 'state': 'running'};
        // Turn panjang: tungguingga cancel dikirim sebelum stream lanjut.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        yield {'type': 'text', 'text': ''};
        yield {'type': 'done'};
      };
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    final turn = controller.send('kerja panjang');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.busy, isTrue);
    await controller.stop();
    expect(controller.stopRequested, isTrue);
    expect(client.cancelCalls, 1);
    await turn;
    expect(controller.busy, isFalse);
    expect(controller.messages.last['text'], '(turn dihentikan)');
  });

  test('C4: stop() saat idle tidak mengirim apa pun', () async {
    final controller =
        ChatController(HttpAgentRepository(_FakeAgentApiClient()));
    addTearDown(controller.dispose);

    await controller.stop();

    expect(controller.stopRequested, isFalse);
  });

  test('openSession ditolak saat turn masih berjalan', () async {
    final gate = StreamController<Map<String, dynamic>>();
    addTearDown(gate.close);
    final client = _FakeAgentApiClient()..streamHandler = (_) => gate.stream;
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    final turn = controller.send('halo');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.busy, isTrue);
    final snapshot = List<Map<String, String>>.of(controller.messages);

    await controller.openSession('flutter:old');

    expect(controller.messages.length, snapshot.length + 1);
    expect(controller.messages.last['role'], 'system');
    expect(controller.messages.last['text'], contains('turn masih berjalan'));
    expect(controller.messages.take(snapshot.length), snapshot);

    await gate.close();
    await turn;
    expect(controller.busy, isFalse);
  });

  test('openSession saat idle tetap memuat transcript', () async {
    final client = _FakeAgentApiClient();
    final controller = ChatController(HttpAgentRepository(client));
    addTearDown(controller.dispose);

    await controller.openSession('flutter:old');

    expect(controller.busy, isFalse);
  });
}
