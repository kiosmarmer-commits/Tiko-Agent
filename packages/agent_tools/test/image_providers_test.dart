import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri base;
  int polls = 0;

  setUp(() async {
    polls = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'POST' && path == '/fal-ai/flux-2-klein') {
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'status': 'IN_QUEUE',
          'status_url': '$base/status/1',
          'response_url': '$base/response/1',
        }));
      } else if (path == '/status/1') {
        polls++;
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({'status': polls >= 2 ? 'COMPLETED' : 'IN_PROGRESS'}),
        );
      } else if (path == '/response/1') {
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'images': [
            {'url': '$base/image.png'},
          ],
        }));
      } else if (path == '/image.png') {
        req.response.statusCode = 200;
        req.response.add(base64Decode('aGVsbG8gaW1hZ2U='));
      } else if (req.method == 'POST' && path == '/v1/images/generations') {
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            {'b64_json': base64Encode(utf8.encode('openai-bytes'))},
          ],
        }));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('ImageModelCatalog lists 11 Hermes-parity models', () {
    final catalog = const ImageModelCatalog();
    expect(catalog.models.length, 11);
    expect(catalog.byId('fal-ai/flux-2-pro')!.label, 'FLUX 2 Pro');
    expect(catalog.byProvider('openai').length, 2);
    expect(catalog.ids(), contains('fal-ai/nano-banana-pro'));
  });

  test('FalAiImageProvider submits, polls, and downloads the image',
      () async {
    final provider = FalAiImageProvider(
      apiKey: 'k',
      baseUrl: base.toString(),
      pollInterval: const Duration(milliseconds: 1),
    );
    final result = await provider.generateImage(
      prompt: 'kucing astronot',
      model: 'fal-ai/flux-2-klein',
      width: 512,
      height: 512,
    );
    expect(result.success, isTrue);
    expect(result.provider, 'fal');
    expect(utf8.decode(result.imageBytes!), 'hello image');
    expect(polls, greaterThanOrEqualTo(2));
    expect(await provider.listModels(), contains('fal-ai/flux-2-pro'));
  });

  test('OpenAiImagesProvider decodes b64_json responses', () async {
    final provider = OpenAiImagesProvider(
      apiKey: 'k',
      baseUrl: base.toString(),
    );
    final result = await provider.generateImage(
      prompt: 'test',
      model: 'openai/gpt-image-1.5',
    );
    expect(result.success, isTrue);
    expect(utf8.decode(result.imageBytes!), 'openai-bytes');
  });

  test('ImageModelRouter dispatches by model prefix', () async {
    final router = ImageModelRouter(providers: {
      'openai': OpenAiImagesProvider(
        apiKey: 'k',
        baseUrl: base.toString(),
      ),
    });
    final result = await router.generateImage(
      prompt: 'p',
      model: 'openai/gpt-image-2',
    );
    expect(result.success, isTrue);
    expect(result.model, 'openai/gpt-image-2');

    final missing = await router.generateImage(
      prompt: 'p',
      model: 'fal-ai/flux-2-pro',
    );
    expect(missing.success, isFalse);
    expect(missing.error, contains('Provider tidak terdaftar'));
  });
}
