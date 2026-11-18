import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

Map<String, dynamic> _profile(
  String id,
  String name, {
  String persona = '',
  String? model,
  String greeting = '',
  List<String> toolAllowlist = const [],
}) =>
    {
      'id': id,
      'name': name,
      'persona': persona,
      'model': model,
      'greeting': greeting,
      'tool_allowlist': toolAllowlist,
      'created_at': _now(),
      'updated_at': _now(),
    };

void main() {
  late HttpApiServer server;
  late Map<String, Map<String, dynamic>> bots;
  late Map<String, String> bindings;

  setUp(() async {
    bots = {
      'helper': _profile('helper', 'Helper', persona: 'rapih', model: 'm1'),
      'scribe': _profile('scribe', 'Scribe', toolAllowlist: ['read_file']),
    };
    bindings = {'ws:lab': 'helper'};
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      listBots: () async => bots.values.map((b) => Map<String, dynamic>.from(b)).toList(),
      getBot: (id) async =>
          bots[id] == null ? null : Map<String, dynamic>.from(bots[id]!),
      createBot: (body) async {
        final id = body['id'] as String;
        if (bots.containsKey(id)) {
          throw ApiRequestException(409, 'conflict', 'bot "$id" sudah ada');
        }
        bots[id] = _profile(
          id,
          body['name'] as String,
          persona: body['persona'] as String? ?? '',
          model: body['model'] as String?,
          greeting: body['greeting'] as String? ?? '',
          toolAllowlist:
              (body['tool_allowlist'] as List?)?.cast<String>().toList() ??
                  const [],
        );
        return Map<String, dynamic>.from(bots[id]!);
      },
      updateBot: (id, body) async {
        final current = bots[id];
        if (current == null) return null;
        final updated = Map<String, dynamic>.from(current);
        if (body.containsKey('name')) updated['name'] = body['name'];
        if (body.containsKey('persona')) updated['persona'] = body['persona'];
        if (body.containsKey('model')) updated['model'] = body['model'];
        if (body.containsKey('greeting')) updated['greeting'] = body['greeting'];
        if (body.containsKey('tool_allowlist')) {
          updated['tool_allowlist'] = body['tool_allowlist'];
        }
        bots[id] = updated;
        return Map<String, dynamic>.from(updated);
      },
      deleteBot: (id) async => bots.remove(id) != null,
      listBotBindings: () async => Map<String, String>.from(bindings),
      bindBot: (botId, sessionId) async {
        if (!bots.containsKey(botId)) return false;
        bindings[sessionId] = botId;
        return true;
      },
      unbindBot: (botId, sessionId) async {
        if (!bots.containsKey(botId) || bindings[sessionId] != botId) {
          return false;
        }
        bindings.remove(sessionId);
        return true;
      },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set('content-type', 'application/json');
      if (auth) {
        request.headers.set(
          'authorization',
          'Bearer manager-token-0123456789abcdef',
        );
      }
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>,
      };
    } finally {
      client.close(force: true);
    }
  }

  test('GET /v1/bots mengembalikan daftar bot', () async {
    final r = await send('GET', '/v1/bots');
    expect(r['status'], 200);
    final list = r['body']['bots'] as List;
    expect(list.length, 2);
    expect(list.map((b) => b['id']), containsAll(['helper', 'scribe']));
  });

  test('GET /v1/bots tanpa auth 401', () async {
    final r = await send('GET', '/v1/bots', auth: false);
    expect(r['status'], 401);
    expect(r['body']['code'], 'unauthorized');
  });

  test('POST /v1/bots membuat bot (201)', () async {
    final r = await send('POST', '/v1/bots', body: {
      'id': 'notaris',
      'name': 'Notaris',
      'persona': 'formal',
      'greeting': 'hai',
      'tool_allowlist': ['read_file', 'shell'],
    });
    expect(r['status'], 201);
    expect(r['body']['id'], 'notaris');
    expect(r['body']['tool_allowlist'], ['read_file', 'shell']);
  });

  test('POST /v1/bots duplikat 409 conflict', () async {
    final r = await send('POST', '/v1/bots', body: {
      'id': 'helper',
      'name': 'Duplikat',
    });
    expect(r['status'], 409);
    expect(r['body']['code'], 'conflict');
  });

  test('POST /v1/bots id tidak valid 400', () async {
    final r = await send('POST', '/v1/bots', body: {
      'id': 'Bad ID!',
      'name': 'X',
    });
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('POST /v1/bots tanpa name 400', () async {
    final r = await send('POST', '/v1/bots', body: {'id': 'kosong'});
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('POST /v1/bots field tidak dikenal 400', () async {
    final r = await send('POST', '/v1/bots', body: {
      'id': 'havier',
      'name': 'Havier',
      'hacker': true,
    });
    expect(r['status'], 400);
    expect(r['body']['error'], contains('hacker'));
  });

  test('POST /v1/bots tool_allowlist bukan daftar string 400', () async {
    final r = await send('POST', '/v1/bots', body: {
      'id': 'havier',
      'name': 'Havier',
      'tool_allowlist': [1, 2],
    });
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('GET /v1/bots/bindings mengembalikan map binding', () async {
    final r = await send('GET', '/v1/bots/bindings');
    expect(r['status'], 200);
    expect(r['body']['bindings'], {'ws:lab': 'helper'});
  });

  test('GET /v1/bots/<id> profil atau 404', () async {
    final ok = await send('GET', '/v1/bots/helper');
    expect(ok['status'], 200);
    expect(ok['body']['persona'], 'rapih');

    final miss = await send('GET', '/v1/bots/unknown-bot');
    expect(miss['status'], 404);
    expect(miss['body']['code'], 'not_found');
  });

  test('PATCH /v1/bots/<id> mengubah subset dan clear model', () async {
    final r1 = await send('PATCH', '/v1/bots/helper', body: {
      'name': 'Helper Baru',
      'model': null,
    });
    expect(r1['status'], 200);
    expect(r1['body']['name'], 'Helper Baru');
    expect(r1['body']['model'], isNull);
    expect(r1['body']['persona'], 'rapih');

    final r2 = await send('PATCH', '/v1/bots/helper', body: {
      'tool_allowlist': <String>[],
    });
    expect(r2['status'], 200);
    expect(r2['body']['tool_allowlist'], isEmpty);

    final miss = await send('PATCH', '/v1/bots/unknown-bot', body: {
      'name': 'X',
    });
    expect(miss['status'], 404);
  });

  test('PATCH /v1/bots/<id> field tidak dikenal 400', () async {
    final r = await send('PATCH', '/v1/bots/helper', body: {'id': 'zzz'});
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('DELETE /v1/bots/<id> menghapus atau 404', () async {
    final ok = await send('DELETE', '/v1/bots/scribe');
    expect(ok['status'], 200);
    expect(ok['body']['deleted'], isTrue);

    final miss = await send('DELETE', '/v1/bots/scribe');
    expect(miss['status'], 404);
  });

  test('POST /v1/bots/<id>/bind dan /unbind', () async {
    final bind = await send('POST', '/v1/bots/scribe/bind', body: {
      'session_id': 'ws:baru',
    });
    expect(bind['status'], 200);
    expect(bind['body']['bound'], isTrue);

    final bindings1 = await send('GET', '/v1/bots/bindings');
    expect(bindings1['body']['bindings']['ws:baru'], 'scribe');

    final bindMissing = await send('POST', '/v1/bots/unknown-bot/bind', body: {
      'session_id': 'ws:baru',
    });
    expect(bindMissing['status'], 404);

    final bindNoSession = await send('POST', '/v1/bots/scribe/bind', body: {});
    expect(bindNoSession['status'], 400);

    final unbind = await send('POST', '/v1/bots/scribe/unbind', body: {
      'session_id': 'ws:baru',
    });
    expect(unbind['status'], 200);

    final bindAgain = await send('POST', '/v1/bots/scribe/bind', body: {
      'session_id': 'ws:baru',
    });
    expect(bindAgain['status'], 200);

    final unbindWrongBot = await send('POST', '/v1/bots/helper/unbind', body: {
      'session_id': 'ws:baru',
    });
    expect(unbindWrongBot['status'], 404);
  });

  test('bot tanpa callback 501 not_implemented', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/bots');
      final request = await client.getUrl(uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      expect(response.statusCode, 501);
      expect(body['code'], 'not_implemented');
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });
}
