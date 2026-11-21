import 'dart:convert';
import 'dart:io';

import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// Hermes-parity model discovery Ollama native: `GET {base}/api/tags`
/// dengan fake server loopback; fail-open pada error.
void main() {
  late HttpServer server;
  late String baseUrl;
  int tagsRequests = 0;

  setUp(() async {
    tagsRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (req) async {
        await utf8.decoder.bind(req).drain();
        if (req.uri.path == '/api/tags') {
          tagsRequests++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'models': [
              {
                'name': 'qwen2.5:3b',
                'model': 'qwen2.5:3b',
                'size': 12345,
              },
              {'name': 'llama3.2:1b'},
              {'bukan-model': true},
            ],
          }));
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      },
      onError: (Object _) {},
    );
    baseUrl = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('discoverModels parsing /api/tags (field name)', () async {
    final p = OllamaNativeProvider(id: 'ollama-local', baseUrl: baseUrl);
    final models = await p.discoverModels();
    expect(tagsRequests, 1);
    expect(models, ['qwen2.5:3b', 'llama3.2:1b']);
  });

  test('server mati → fail-open daftar kosong', () async {
    await server.close(force: true);
    final p = OllamaNativeProvider(id: 'ollama-local', baseUrl: baseUrl);
    expect(await p.discoverModels(), isEmpty);
  });

  test('withModel salinan model berbeda', () async {
    final base = OllamaNativeProvider(id: 'ollama-local', baseUrl: baseUrl);
    final alt = base.withModel('llama3.2:1b');
    expect(alt.id, base.id);
    expect(alt.model, 'llama3.2:1b');
    expect(alt.baseUrl, base.baseUrl);
    expect(alt, isNot(same(base)));
  });
}
