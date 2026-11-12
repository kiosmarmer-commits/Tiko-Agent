import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class _MockTelegramApi {
  _MockTelegramApi._(this._server);
  final HttpServer _server;

  static Future<_MockTelegramApi> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _MockTelegramApi._(server);
    server.listen(api._handle, onError: (Object _) {});
    return api;
  }
  final sent = <Map<String, dynamic>>[];
  final edited = <Map<String, dynamic>>[];
  int nextMessageId = 100;

  int get port => _server.port;

  Future<void> _handle(HttpRequest req) async {
      final path = req.uri.path;
      var body = <String, dynamic>{};
      try {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
      if (path.endsWith('/sendMessage')) {
        final id = nextMessageId++;
        sent.add(body);
        _json(req, {
          'ok': true,
          'result': {'message_id': id},
        });
      } else if (path.endsWith('/editMessageText')) {
        edited.add(body);
        _json(req, {'ok': true, 'result': true});
      } else {
        _json(req, {'ok': false, 'description': 'unknown'});
      }
  }

  void _json(HttpRequest req, Map<String, dynamic> json) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(json));
    req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('streamer throttle: create sekali, edit dibatasi interval', () async {
    final api = await _MockTelegramApi.start();
    addTearDown(api.close);

    final creates = <String>[];
    final updates = <String, String>{};
    var updateCount = 0;
    final streamer = ProgressiveStreamer(
      create: (text) async {
        creates.add(text);
        return 'msg-1';
      },
      update: (id, text) async {
        updateCount++;
        updates[id] = text;
      },
      minInterval: const Duration(milliseconds: 30),
      maxLen: 100,
    );

    for (var i = 0; i < 10; i++) {
      streamer.add('delta$i ');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final editsDuring = updateCount;
    expect(creates.length, 1, reason: 'live message dibuat sekali');
    expect(editsDuring, lessThan(10), reason: 'edit di-throttle');

    final ids = await streamer.finish('jawaban final');
    expect(ids, ['msg-1']);
    expect(updates['msg-1'], 'jawaban final');
    expect(editsDuring, lessThanOrEqualTo(updateCount));
  });

  test('finish overflow: teks > maxLen displit ke pesan lanjutan', () async {
    final creates = <String>[];
    final finalTexts = <String>[];
    final streamer = ProgressiveStreamer(
      create: (text) async {
        creates.add(text);
        return 'msg-${creates.length}';
      },
      update: (id, text) async => finalTexts.add(text),
      minInterval: const Duration(milliseconds: 10),
      maxLen: 10,
    );
    streamer.add('1234567890ABCDEF');
    final ids = await streamer.finish('0123456789012345678901234');
    expect(ids.length, 3, reason: '25 char / maxLen 10 = 3 pesan');
    expect(finalTexts.join('|').length >= 25, isTrue);
  });

  test('kegagalan edit tidak melempar exception (best-effort)', () async {
    final streamer = ProgressiveStreamer(
      create: (text) async => 'msg-1',
      update: (id, text) async => throw StateError('rate limited'),
      minInterval: const Duration(milliseconds: 5),
      maxLen: 100,
    );
    streamer.add('halo');
    final ids = await streamer.finish('final');
    expect(ids, isEmpty, reason: 'edit gagal -> pemanggil fallback send()');
  });

  test('TelegramLiveMessage: sendMessage -> message_id, editMessageText',
      () async {
    final api = await _MockTelegramApi.start();
    addTearDown(api.close);
    final port = api.port;
    // The adapter URL is fixed to api.telegram.org; verify request shape by
    // intercepting with a custom http.Client.
    final client = _RoutedClient('127.0.0.1', port);
    addTearDown(client.close);
    final live = TelegramLiveMessage(
      token: 'tok',
      chatId: '77',
      httpClient: client,
    );
    final id = await live.create('mulai');
    expect(id, '100');
    await live.update('100', 'diperbarui');
    expect(client.paths, contains('/bottok/sendMessage'));
    expect(client.paths, contains('/bottok/editMessageText'));
    expect(client.bodies.any((b) => b['chat_id'] == '77'), isTrue);
    expect(
      client.bodies.any((b) => b['text'] == 'diperbarui'),
      isTrue,
    );
  });
}

class _RoutedClient extends http.BaseClient {
  _RoutedClient(this.host, this.port);
  final String host;
  final int port;
  final paths = <String>[];
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (request.method == 'POST') {
      final body = (request as http.Request).body;
      bodies.add(jsonDecode(body) as Map<String, dynamic>);
    }
    final uri = request.url.replace(host: host, port: port, scheme: 'http');
    final cloned = http.Request(request.method, uri)
      ..headers.addAll(request.headers);
    if (request is http.Request) cloned.body = request.body;
    final res = await _inner.send(cloned);
    return http.StreamedResponse(
      res.stream,
      res.statusCode,
      headers: res.headers,
    );
  }

  final _inner = http.Client();
}
