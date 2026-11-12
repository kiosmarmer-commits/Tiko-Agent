import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Routes requests aimed at external chat APIs to a loopback mock server so
/// the gateways exercise real HTTP serialization without touching production
/// services.
class _RoutedClient extends http.BaseClient {
  _RoutedClient(this.mockBase);

  final Uri mockBase;

  Uri _rewrite(Uri url) {
    Uri target;
    if (url.host == 'api.telegram.org') {
      final method = url.pathSegments.length > 1 ? url.pathSegments.last : '';
      target = mockBase.replace(path: method, queryParameters: url.queryParameters);
    } else if (url.host == 'discord.com') {
      target = mockBase.replace(path: '/discord${url.path}');
    } else if (url.host == 'slack.com') {
      target = mockBase.replace(path: '/slack${url.path}');
    } else if (url.host == 'graph.facebook.com') {
      target = mockBase.replace(path: '/wa${url.path}');
    } else {
      target = url;
    }
    return target;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, _rewrite(request.url));
    req.headers.addAll(request.headers);
    if (request is http.Request) {
      req.bodyBytes = request.bodyBytes;
    }
    final response = await req.send();
    return http.StreamedResponse(
      response.stream,
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
    );
  }
}

class _CapturedRequest {
  _CapturedRequest(
    this.method,
    this.path,
    this.headers,
    this.body,
  );

  final String method;
  final String path;
  final Map<String, String?> headers;
  final Map<String, dynamic> body;
}

void main() {
  late HttpServer server;
  late Uri mockBase;
  final captured = <_CapturedRequest>[];
  final queuedUpdates = <Map<String, dynamic>>[];

  setUp(() async {
    captured.clear();
    queuedUpdates.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (req) async {
        final raw = await utf8.decoder.bind(req).join();
        Map<String, dynamic> body = {};
        if (raw.isNotEmpty) {
          try {
            body = jsonDecode(raw) as Map<String, dynamic>;
          } catch (_) {
            body = {'_raw': raw};
          }
        }
        captured.add(_CapturedRequest(
          req.method,
          req.uri.path,
          {
            'authorization': req.headers.value('authorization'),
            'content-type': req.headers.value('content-type'),
          },
          body,
        ));
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        if (path == '/sendMessage') {
          req.response.write(jsonEncode({
            'ok': true,
            'result': {'message_id': 77},
          }));
        } else if (path == '/getUpdates') {
          req.response.write(jsonEncode({
            'ok': true,
            'result': queuedUpdates.isEmpty ? [] : [queuedUpdates.removeAt(0)],
          }));
        } else if (path == '/answerCallbackQuery') {
          req.response.write(jsonEncode({'ok': true}));
        } else if (path.startsWith('/discord/channels/') &&
            path.endsWith('/messages')) {
          req.response.write(jsonEncode({'id': 'm1'}));
        } else if (path.startsWith('/slack/') &&
            path.endsWith('/chat.postMessage')) {
          req.response.write(jsonEncode({'ok': true, 'ts': '1'}));
        } else if (path.startsWith('/wa/') && path.endsWith('/messages')) {
          req.response.write(jsonEncode({
            'messaging_product': 'whatsapp',
            'messages': [
              {'id': 'wamid.1'},
            ],
          }));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode({'error': 'not found'}));
        }
        await req.response.close();
      },
      onError: (Object _) {},
    );
    mockBase = Uri.parse('http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('telegram: send posts to sendMessage with chat id and text', () async {
    final gw = TelegramGateway(
      token: 'tok',
      allowedUserIds: const {42},
      httpClient: _RoutedClient(mockBase),
    );
    await gw.send(const OutboundMessage(sessionKey: 'tg:123', text: 'halo'));
    final req = captured.single;
    expect(req.path, '/sendMessage');
    expect(req.body['chat_id'], '123');
    expect(req.body['text'], 'halo');
    expect(req.body['parse_mode'], 'Markdown');
  });

  test('telegram: long-polling delivers an allowed update inbound',
      () async {
    queuedUpdates.add({
      'update_id': 5,
      'message': {
        'message_id': 1,
        'from': {'id': 42, 'username': 'budi'},
        'chat': {'id': 123},
        'text': 'halo bot',
        'date': 1700000000,
      },
    });
    final gw = TelegramGateway(
      token: 'tok',
      allowedUserIds: const {42},
      httpClient: _RoutedClient(mockBase),
      pollTimeoutSec: 1,
    );
    final inbound = gw.inbound.first.timeout(const Duration(seconds: 10));
    await gw.start();
    final msg = await inbound;
    await gw.stop();
    expect(msg.text, 'halo bot');
    expect(msg.sessionKey, 'tg:123');
    expect(msg.userKey, '42');
    expect(captured.any((r) => r.path == '/getUpdates'), isTrue);
  });

  test('telegram: update from a non-allowed user is dropped', () async {
    queuedUpdates.add({
      'update_id': 6,
      'message': {
        'message_id': 2,
        'from': {'id': 999},
        'chat': {'id': 123},
        'text': 'gate crash',
        'date': 1700000001,
      },
    });
    final gw = TelegramGateway(
      token: 'tok',
      allowedUserIds: const {42},
      httpClient: _RoutedClient(mockBase),
      pollTimeoutSec: 1,
    );
    await gw.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await gw.stop();
    final inbound = await gw.inbound.isEmpty.timeout(
      const Duration(milliseconds: 100),
      onTimeout: () => true,
    );
    expect(inbound, isTrue);
  });

  test('discord: bot send posts to the channel messages endpoint', () async {
    final gw = DiscordGateway(
      botToken: 'bottok',
      allowedUserIds: const {'42'},
      httpClient: _RoutedClient(mockBase),
    );
    await gw.send(
      const OutboundMessage(sessionKey: 'discord:chan1', text: 'pesan'),
    );
    final req = captured.single;
    expect(req.path, '/discord/api/v10/channels/chan1/messages');
    expect(req.headers['authorization'], 'Bot bottok');
    expect(req.body['content'], 'pesan');
  });

  test('slack: bot send posts chat.postMessage and reports ok', () async {
    final gw = SlackGateway(botToken: 'xoxb', client: _RoutedClient(mockBase));
    final ok = await gw.send('hai', channel: 'C1');
    expect(ok, isTrue);
    final req = captured.single;
    expect(req.path, '/slack/api/chat.postMessage');
    expect(req.headers['authorization'], 'Bearer xoxb');
    expect(req.body['channel'], 'C1');
    expect(req.body['text'], 'hai');
  });

  test('whatsapp: sendText posts to the Meta graph and returns the id',
      () async {
    final gw = WhatsAppGateway(
      phoneNumberId: 'pn1',
      accessToken: 'at',
      verifyToken: 'vt',
      client: _RoutedClient(mockBase),
    );
    final id = await gw.sendText('62812', 'halo wa');
    expect(id, 'wamid.1');
    final req = captured.single;
    expect(req.path, '/wa/v20.0/pn1/messages');
    expect(req.headers['authorization'], 'Bearer at');
    expect(req.body['messaging_product'], 'whatsapp');
    expect(req.body['to'], '62812');
    expect((req.body['text'] as Map)['body'], 'halo wa');
  });
}
