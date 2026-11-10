import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('HTTP approval resolves the same runtime broker waiter', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_api_approval_');
    final broker = ApprovalBroker('${temp.path}/approvals.json');
    final session = Session(
      id: 'http:integration',
      channel: 'http',
      userKey: 'flutter',
    );
    final call = const ToolCall(
      id: 'call-integration',
      name: 'write_file',
      args: {'path': 'safe.txt', 'content': 'approved'},
    );
    final request = await broker.create(
      session: session,
      call: call,
      risk: 'medium',
    );

    final server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'integration-token',
      port: 0,
      listApprovals: () async =>
          (await broker.all()).map((item) => item.toJson()).toList(),
      decideApproval: (id, approve) async =>
          await broker.decide(id, approve: approve, actor: 'flutter') != null,
    );

    HttpClient? client;
    try {
      await server.start();
      final waiting = broker.wait(request.id);
      client = HttpClient();
      final uri = Uri.parse(
        'http://127.0.0.1:${server.boundPort}/v1/approvals/${request.id}',
      );
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer integration-token',
      );
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.write(jsonEncode({'approve': true}));
      final response = await httpRequest.close();
      final result = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(result['ok'], isTrue);
      expect(await waiting, isTrue);
      expect((await broker.all()).single.state, ApprovalState.approved);
    } finally {
      client?.close(force: true);
      await server.stop();
      await broker.close();
      await temp.delete(recursive: true);
    }
  });
}
