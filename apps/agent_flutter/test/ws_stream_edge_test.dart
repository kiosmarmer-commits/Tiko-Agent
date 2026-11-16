import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server HTTP palsu dengan upgrade WebSocket di `/v1/stream` dan endpoint
/// ticket `/v1/auth/ticket` — untuk menguji edge case streamChat.
class _FakeWsServer {
  _FakeWsServer();

  final received = <dynamic>[];
  final upgradeQueries = <Map<String, String>>[];
  int ticketStatus = 200;
  bool upgradeStream = true;

  /// Dipanggil setelah upgrade selesai; boleh mengirim frame atau menutup.
  Future<void> Function(WebSocket ws)? onUpgrade;

  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      if (req.uri.path == '/v1/auth/ticket') {
        req.response.statusCode = ticketStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          if (ticketStatus < 400) 'ticket': 'tk-1' else 'error': 'no ticket',
        }));
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/stream') {
        upgradeQueries.add(req.uri.queryParameters);
        if (!upgradeStream) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final ws = await WebSocketTransformer.upgrade(req);
        await onUpgrade?.call(ws);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
    return 'ws://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

AgentApiClient _client(String wsBase) => AgentApiClient(
      baseUrl: wsBase.replaceFirst('ws://', 'http://'),
      token: 'secret-token',
    );

void main() {
  test('streamChat: karakter khusus (emoji, newline, kutip, backslash) '
      'round-trip utuh via JSON', () async {
    final server = _FakeWsServer();
    server.onUpgrade = (ws) async {
      await for (final raw in ws) {
        server.received.add(raw);
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        ws.add(jsonEncode({
          'type': 'delta',
          'text': 'balasan: ${msg['text']} 🎉\nbaris kedua "kutip" \\ok\\',
        }));
        ws.add(jsonEncode({'type': 'done'}));
        await ws.close();
      }
    };
    final wsBase = await server.start();
    final client = _client(wsBase);

    const tricky =
        'hai 🎉 "kutip ganda"\nbaris baru\ttab \\backslash\\ éè€';
    final events = await client
        .streamChat(tricky, sessionKey: 'flutter:sesi-_ué®/khusus?')
        .toList();

    expect(server.received, hasLength(1));
    final sent = jsonDecode(server.received.single as String)
        as Map<String, dynamic>;
    expect(sent['text'], tricky,
        reason: 'teks dengan karakter khusus harus sampai persis sama');
    expect(events.first['text'], contains(tricky));
    expect(events.last['type'], 'done');

    client.close();
    await server.close();
  });

  test('streamChat: frame biner (bukan string) dilaporkan sebagai error, '
      'bukan crash', () async {
    final server = _FakeWsServer();
    server.onUpgrade = (ws) async {
      await for (final _ in ws) {
        ws.add(<int>[1, 2, 3]); // frame biner
        await ws.close();
      }
    };
    final wsBase = await server.start();
    final client = _client(wsBase);

    final events = await client.streamChat('hai').toList();
    expect(events, hasLength(1));
    expect(events.single['type'], 'error');
    expect(events.single['message'], 'bad frame');

    client.close();
    await server.close();
  });

  test('streamChat: ticket endpoint gagal (401) → tetap connect TANPA '
      'ticket di query (token tidak pernah masuk URL)', () async {
    final server = _FakeWsServer();
    server.ticketStatus = 401;
    server.onUpgrade = (ws) async {
      await for (final _ in ws) {
        ws.add(jsonEncode({'type': 'done'}));
        await ws.close();
      }
    };
    final wsBase = await server.start();
    final client = _client(wsBase);

    final events = await client.streamChat('hai').toList();
    expect(events.single['type'], 'done');
    expect(server.upgradeQueries.single.containsKey('ticket'), isFalse,
        reason: 'fallback tanpa ticket: jangan kirim ticket kosong, dan '
            'secret token tidak boleh muncul di query');

    client.close();
    await server.close();
  });

  test('streamChat: server menutup koneksi mendadak → stream selesai tanpa '
      'menggantung', () async {
    final server = _FakeWsServer();
    server.onUpgrade = (ws) async {
      await for (final _ in ws) {
        // Tutup socket secara paksa (analogi koneksi putus).
        await ws.close();
      }
    };
    final wsBase = await server.start();
    final client = _client(wsBase);

    // Harus selesai (bukan hang) dalam waktu wajar.
    final events = await client
        .streamChat('hai')
        .timeout(const Duration(seconds: 15))
        .toList();
    expect(events, isEmpty);

    client.close();
    await server.close();
  });

  test('streamChat: upgrade ditolak (404) → error terangkat ke pemanggil', () async {
    final server = _FakeWsServer();
    server.upgradeStream = false;
    final wsBase = await server.start();
    final client = _client(wsBase);

    await expectLater(
      client.streamChat('hai').drain<void>(),
      throwsA(isA<Object>()),
    );

    client.close();
    await server.close();
  });

  test('streamChat: koneksi yang tidak pernah selesai upgrade ke-luar oleh '
      'timeout ready 10 detik', () async {
    // Server yang menerima TCP tetapi tidak pernah upgrade.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subs = <StreamSubscription<Uint8List>>[];
    server.listen((socket) {
      // Tidak membalas apa pun — biarkan koneksi menggantung.
      subs.add(socket.listen((_) {}));
    });

    final client = AgentApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'secret-token',
    );

    await expectLater(
      client.streamChat('hai').drain<void>(),
      throwsA(isA<TimeoutException>()),
    );

    client.close();
    for (final s in subs) {
      await s.cancel();
    }
    await server.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
