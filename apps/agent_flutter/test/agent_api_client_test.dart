import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'admin GET endpoints surface HTTP errors instead of empty data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'unauthorized'}));
        await request.response.close();
      });
      final client = AgentApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'invalid-token',
      );

      final calls = <Future<Object?> Function()>[
        () async => client.capabilities(),
        () async => client.doctor(),
        () async => client.listSessions(),
        () async => client.listApprovals(),
        () async => client.listEvents(),
      ];

      try {
        for (final call in calls) {
          await expectLater(call(), throwsA(isA<Exception>()));
        }
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
