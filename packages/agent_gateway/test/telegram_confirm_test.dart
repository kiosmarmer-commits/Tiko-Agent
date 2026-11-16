import 'dart:convert';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _ok(Object result) =>
    http.Response(jsonEncode({'ok': true, 'result': result}), 200);

void main() {
  test('confirmation ids are unique within the same millisecond', () async {
    final bodies = <String>[];
    final client = MockClient((req) async {
      bodies.add(req.body);
      return _ok({'message_id': 1});
    });
    final gw = TelegramGateway(
      token: 't',
      allowedUserIds: {42},
      httpClient: client,
    );
    final pending = <Future<bool>>[
      gw.requestConfirm(
        sessionKey: 'tg:1',
        prompt: 'a',
        requesterKey: '42',
        timeout: const Duration(milliseconds: 200),
      ),
      gw.requestConfirm(
        sessionKey: 'tg:1',
        prompt: 'b',
        requesterKey: '42',
        timeout: const Duration(milliseconds: 200),
      ),
    ];
    await Future.wait(pending);
    final ids = RegExp(r'c\d+-\d+:yes')
        .allMatches(bodies.join())
        .map((m) => m.group(0)!)
        .toSet();
    expect(ids, hasLength(2));
    await gw.close();
  });

  Future<bool> press({
    required int presserUid,
    required String requester,
  }) async {
    String? buttonId;
    var delivered = false;
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/sendMessage')) {
        buttonId = RegExp(r'c\d+-\d+:yes').firstMatch(req.body)?.group(0);
        return _ok({'message_id': 1});
      }
      if (path.endsWith('/getUpdates')) {
        if (buttonId != null && !delivered) {
          delivered = true;
          return _ok([
            {
              'update_id': 1,
              'callback_query': {
                'id': 'cq1',
                'from': {'id': presserUid},
                'data': buttonId,
              },
            },
          ]);
        }
        return _ok(<Object>[]);
      }
      return _ok(<String, Object>{});
    });
    final gw = TelegramGateway(
      token: 't',
      allowedUserIds: {42, 999},
      httpClient: client,
    );
    await gw.start();
    final result = await gw.requestConfirm(
      sessionKey: 'tg:1',
      prompt: 'x',
      requesterKey: requester,
      timeout: const Duration(milliseconds: 900),
    );
    await gw.close();
    return result;
  }

  test('requester can approve their own tool call', () async {
    expect(await press(presserUid: 42, requester: '42'), isTrue);
  });

  test('another allowlisted user cannot approve it', () async {
    expect(await press(presserUid: 999, requester: '42'), isFalse);
  });
}
