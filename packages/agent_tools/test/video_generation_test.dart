import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;
  late Directory tmpDir;
  var pollCount = 0;
  var pollsBeforeComplete = 1;
  var failSubmit = false;
  final videoPayload = List<int>.generate(2048, (i) => i % 256);

  setUp(() async {
    pollCount = 0;
    pollsBeforeComplete = 1;
    failSubmit = false;
    tmpDir = await Directory.systemTemp.createTemp('tiko_video_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      if (req.method == 'POST' && req.uri.path == '/veo3-fast') {
        if (failSubmit) {
          req.response.statusCode = 500;
          req.response.write('boom');
          await req.response.close();
          return;
        }
        expect(auth, 'Key test-key');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'request_id': 'req-1',
          'status_url': '$base/requests/req-1/status',
          'response_url': '$base/requests/req-1',
        }));
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/requests/req-1/status') {
        pollCount++;
        final done = pollCount >= pollsBeforeComplete;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'status': done ? 'COMPLETED' : 'IN_QUEUE',
        }));
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/requests/req-1') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'video': {'url': '$base/media/output.mp4'},
        }));
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/media/output.mp4') {
        req.response.headers.contentType = ContentType.binary;
        req.response.add(videoPayload);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmpDir.delete(recursive: true);
  });

  VideoGenerationTool buildTool() => VideoGenerationTool(
        provider: FalVideoGenerationProvider(
          apiKey: 'test-key',
          baseUrl: base,
          config: const VideoGenerationConfig(
            pollInterval: Duration(milliseconds: 10),
            maxPolls: 20,
          ),
        ),
        outputDirectory: tmpDir.path,
      );

  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: tmpDir.path,
      );

  test('queue flow: submit, poll, download, dan simpan file', () async {
    final tool = buildTool();
    final res = await tool.run(
      {'prompt': 'kucing menari', 'duration_sec': 8, 'aspect_ratio': '16:9'},
      ctx(),
    );
    expect(res.isError, isFalse, reason: res.content);
    final json = jsonDecode(res.content) as Map<String, dynamic>;
    expect(json['success'], isTrue);
    expect(json['provider'], 'fal');
    expect(json['model'], 'veo3-fast');
    expect(json['duration_sec'], 8);
    expect(json['video_size'], videoPayload.length);
    final saved = File(json['video_path'] as String);
    expect(await saved.exists(), isTrue);
    expect(await saved.length(), videoPayload.length);
    expect(tmpDir.listSync().whereType<File>(), isNotEmpty);
  });

  test('kegagalan submit -> isError dengan pesan', () async {
    failSubmit = true;
    final tool = buildTool();
    final res = await tool.run({'prompt': 'x'}, ctx());
    expect(res.isError, isTrue);
    final json = jsonDecode(res.content) as Map<String, dynamic>;
    expect(json['success'], isFalse);
    expect(json['error'], contains('500'));
  });

  test('polling melebihi batas -> gagal terkendali', () async {
    pollsBeforeComplete = 999; // tidak akan pernah selesai
    final tool = VideoGenerationTool(
      provider: FalVideoGenerationProvider(
        apiKey: 'test-key',
        baseUrl: base,
        config: const VideoGenerationConfig(
          pollInterval: Duration(milliseconds: 5),
          maxPolls: 3,
        ),
      ),
      outputDirectory: tmpDir.path,
    );
    final res = await tool.run({'prompt': 'x'}, ctx());
    expect(res.isError, isTrue);
    final json = jsonDecode(res.content) as Map<String, dynamic>;
    expect(json['error'], contains('did not complete'));
  });

  test('prompt kosong ditolak', () async {
    final tool = buildTool();
    final res = await tool.run({'prompt': ''}, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('Prompt is required'));
  });

  test('factory fal membuat tool dengan spec yang valid', () {
    final tool = VideoGenerationToolFactory.create(
      apiKey: 'k',
      outputDirectory: tmpDir.path,
    );
    final spec = tool.spec;
    expect(spec.name, 'generate_video');
    expect(spec.risk, 'medium');
    expect(spec.parallelSafe, isFalse);
    final props = spec.inputSchema['properties'] as Map;
    expect(props.containsKey('prompt'), isTrue);
    expect(props.containsKey('model'), isTrue);
    expect(props.containsKey('duration_sec'), isTrue);
  });
}
