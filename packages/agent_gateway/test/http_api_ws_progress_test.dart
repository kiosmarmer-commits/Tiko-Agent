import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// C4 Chat-UX: frame progress turn via WS `/v1/stream` — callback
/// [HttpApiServer.onMessageWithProgress] dikirim langsung ke WS pemesan
/// (chat.status/chat.tool), dan frame `{type: cancel}` memanggil
/// [HttpApiServer.onCancelTurn] dengan jawaban `cancel_ack` (kooperatif).
void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (msg) async => 'balasan: ${msg.text}',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<String> requestTicket(HttpApiServer target) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${target.boundPort}/v1/auth/ticket'),
      );
      req.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return (jsonDecode(body) as Map<String, dynamic>)['ticket'] as String;
    } finally {
      client.close(force: true);
    }
  }

  test('WS frame progress dikirim live ke klien pemesan lalu text+done',
      () async {
    var progressClosed = false;
    final progressServer = HttpApiServer(
      onMessage: (msg) async => 'tidak dipakai',
      onMessageWithProgress: (msg, progress) async {
        progress({'type': 'chat.status', 'state': 'running'});
        progress({'type': 'chat.toolStart', 'name': 'read_file'});
        progress({
          'type': 'chat.tool',
          'name': 'read_file',
          'is_error': false,
          'duration_ms': 12,
          'path': 'halo.txt',
        });
        progressClosed = true;
        return 'jawaban akhir';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await progressServer.start();
    addTearDown(progressServer.stop);

    final uri = Uri.parse(
      'ws://127.0.0.1:${progressServer.boundPort}/v1/stream',
    ).replace(queryParameters: {'ticket': await requestTicket(progressServer)});
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({'text': 'baca file', 'session_key': 'ws:t1'}));
      final frames = <Map<String, dynamic>>[];
      await for (final raw in ws.timeout(const Duration(seconds: 10))) {
        frames.add(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
        if (frames.last['type'] == 'done') break;
      }
      final types = [for (final f in frames) f['type'] as String];
      expect(types.first, 'typing');
      expect(types, contains('chat.status'));
      expect(types, contains('chat.toolStart'));
      expect(types, contains('chat.tool'));
      expect(types.where((t) => t == 'text'), hasLength(1));
      expect(types.last, 'done');
      expect(progressClosed, isTrue);
      final tool = frames.firstWhere((f) => f['type'] == 'chat.tool');
      expect(tool['name'], 'read_file');
      expect(tool['path'], 'halo.txt');
      final textFrame = frames.firstWhere((f) => f['type'] == 'text');
      expect(textFrame['text'], 'jawaban akhir');
    } finally {
      await ws.close();
    }
  });

  test('WS frame cancel memanggil onCancelTurn dan membalas cancel_ack',
      () async {
    final cancelled = <String>[];
    final cancelServer = HttpApiServer(
      onMessage: (msg) async => 'tidak dipakai',
      onCancelTurn: (sessionKey) async {
        cancelled.add(sessionKey);
        return true;
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await cancelServer.start();
    addTearDown(cancelServer.stop);

    final uri = Uri.parse(
      'ws://127.0.0.1:${cancelServer.boundPort}/v1/stream',
    ).replace(queryParameters: {'ticket': await requestTicket(cancelServer)});
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({'type': 'cancel', 'session_key': 'ws:t2'}));
      final raw = await ws.first.timeout(const Duration(seconds: 5));
      final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      expect(frame['type'], 'cancel_ack');
      expect(frame['ok'], isTrue);
      expect(cancelled, ['ws:t2']);
    } finally {
      await ws.close();
    }
  });

  test('WS cancel tanpa onCancelTurn tetap membalas cancel_ack ok:false',
      () async {
    final uri = Uri.parse(
      'ws://127.0.0.1:${server.boundPort}/v1/stream',
    ).replace(queryParameters: {'ticket': await requestTicket(server)});
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({'type': 'cancel', 'session_key': 'ws:t3'}));
      final raw = await ws.first.timeout(const Duration(seconds: 5));
      final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      expect(frame['type'], 'cancel_ack');
      expect(frame['ok'], isFalse);
    } finally {
      await ws.close();
    }
  });

  test('WS cancel saat turn berjalan tetap diproses dan turn selesai',
      () async {
    final turnDone = Completer<void>();
    final cancelServer = HttpApiServer(
      onMessage: (msg) async => 'tidak dipakai',
      onMessageWithProgress: (msg, progress) async {
        await turnDone.future.timeout(const Duration(seconds: 10));
        return 'turn selesai setelah cancel';
      },
      onCancelTurn: (sessionKey) async {
        // Simulasi runtime: sinyal stop dikirim, lalu turn berangka sendiri.
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            turnDone.complete();
          }),
        );
        return true;
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await cancelServer.start();
    addTearDown(cancelServer.stop);

    final uri = Uri.parse(
      'ws://127.0.0.1:${cancelServer.boundPort}/v1/stream',
    ).replace(queryParameters: {'ticket': await requestTicket(cancelServer)});
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({'text': 'kerja panjang', 'session_key': 'ws:t4'}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ws.add(jsonEncode({'type': 'cancel', 'session_key': 'ws:t4'}));
      final frames = <Map<String, dynamic>>[];
      await for (final raw in ws.timeout(const Duration(seconds: 10))) {
        frames.add(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
        if (frames.last['type'] == 'done') break;
      }
      expect(frames.any((f) => f['type'] == 'cancel_ack'), isTrue);
      expect(frames.last['type'], 'done');
      final textFrame = frames.firstWhere((f) => f['type'] == 'text');
      expect(textFrame['text'], 'turn selesai setelah cancel');
    } finally {
      await ws.close();
    }
  });
}

