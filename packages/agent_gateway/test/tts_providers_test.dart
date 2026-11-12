import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/raw') {
        expect(body, contains('halo dunia'));
        req.response.statusCode = 200;
        req.response.add(utf8.encode('RAW-AUDIO'));
      } else if (req.uri.path == '/json-audio') {
        final parsed = jsonDecode(body) as Map<String, dynamic>;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': {
            'audio': base64Encode(utf8.encode('B64-${parsed['text']}')),
          },
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

  test('HttpTtsProvider returns raw bytes when no jsonAudioField', () async {
    final provider = HttpTtsProvider(
      config: HttpTtsProviderConfig(
        id: 'neutts',
        url: '${base.toString()}/raw',
        bodyTemplate: jsonEncode({
          'text': '{{text_json}}',
          'voice': '{{voice}}',
        }),
      ),
    );
    final audio = await provider.synthesize('halo dunia', voice: 'v1');
    expect(utf8.decode(audio), 'RAW-AUDIO');
  });

  test('HttpTtsProvider decodes base64 from a dotted JSON path', () async {
    final provider = HttpTtsProvider(
      config: HttpTtsProviderConfig(
        id: 'minimax-test',
        url: '${base.toString()}/json-audio',
        bodyTemplate: jsonEncode({'text': '{{text_json}}'}),
        jsonAudioField: 'data.audio',
      ),
    );
    final audio = await provider.synthesize('tes');
    expect(utf8.decode(audio), 'B64-tes');
  });

  test('CommandTtsProvider reads audio from stdout', () async {
    final provider = CommandTtsProvider(
      id: 'printf-test',
      commandTemplate: ['printf', '%s', '{{text}}'],
    );
    final audio = await provider.synthesize('dari stdout');
    expect(utf8.decode(audio), 'dari stdout');
  });

  test('CommandTtsProvider reads audio from the output file', () async {
    final provider = CommandTtsProvider(
      id: 'file-test',
      commandTemplate: [
        'sh',
        '-c',
        r'printf %s "$1" > "$2"',
        '--',
        '{{text}}',
        '{{output}}',
      ],
    );
    final audio = await provider.synthesize('dari file');
    expect(utf8.decode(audio), 'dari file');
  });

  test('CommandTtsProvider reports non-zero exits', () async {
    final provider = CommandTtsProvider(
      id: 'fail-test',
      commandTemplate: ['sh', '-c', 'exit 3'],
    );
    await expectLater(
      provider.synthesize('x'),
      throwsA(isA<StateError>()),
    );
  });

  test('TtsProviderCatalog matches the 10 Hermes-parity providers', () {
    expect(TtsProviderCatalog.ids.length, 10);
    expect(TtsProviderCatalog.ids, containsAll([
      'edge-tts',
      'elevenlabs',
      'openai-tts',
      'minimax',
      'mistral-voxtral',
      'google-gemini',
      'xai',
      'neutts',
      'kittentts',
      'piper',
    ]));
    expect(TtsProviderCatalog().byId('piper')!.kind, 'command');
  });

  test('TtsProviderFactory builds catalog providers', () {
    const factory = TtsProviderFactory();
    expect(factory.create('openai-tts', apiKey: 'k').id, 'openai-tts');
    expect(factory.create('xai', apiKey: 'k').id, 'xai');
    expect(factory.create('elevenlabs', apiKey: 'k').id, 'elevenlabs');
    expect(factory.create('edge-tts').id, 'edge-tts');
    expect(factory.create('piper').id, 'piper');
    expect(factory.create('neutts').id, 'neutts');
    expect(
      () => factory.create('custom'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      factory.create('custom', commandTemplate: ['my-tts', '{{text}}']).id,
      'custom',
    );
  });
}
