import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('upsert vectorises text through the embedder', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    });
    final provider = ByteRoverMemoryProvider(
      apiKey: 'k',
      httpClient: client,
      embedder: (text) async => <double>[0.1, 0.2, 0.3],
    );
    await provider.upsert(const MemoryRecord(id: 'a', text: 'hello'));
    expect(bodies.single['values'], <double>[0.1, 0.2, 0.3]);
    expect((bodies.single['metadata'] as Map)['text'], 'hello');
  });

  test('upsert without an embedder fails closed', () async {
    final provider = ByteRoverMemoryProvider(
      apiKey: 'k',
      httpClient: MockClient((req) async => http.Response('{}', 200)),
    );
    await expectLater(
      provider.upsert(const MemoryRecord(id: 'a', text: 'x')),
      throwsStateError,
    );
  });

  test('empty embedder result is rejected', () async {
    final provider = ByteRoverMemoryProvider(
      apiKey: 'k',
      httpClient: MockClient((req) async => http.Response('{}', 200)),
      embedder: (text) async => <double>[],
    );
    await expectLater(
      provider.upsert(const MemoryRecord(id: 'a', text: 'x')),
      throwsArgumentError,
    );
  });

  test('search maps results without an embedding field', () async {
    final client = MockClient((req) async => http.Response(
          jsonEncode({
            'results': [
              {
                'id': 'a',
                'metadata': {'text': 'hello', 'tags': ['t']},
              },
            ],
          }),
          200,
        ));
    final provider = ByteRoverMemoryProvider(apiKey: 'k', httpClient: client);
    final rows = await provider.search('q');
    expect(rows.single.id, 'a');
    expect(rows.single.text, 'hello');
    expect(rows.single.tags, <String>['t']);
  });
}
