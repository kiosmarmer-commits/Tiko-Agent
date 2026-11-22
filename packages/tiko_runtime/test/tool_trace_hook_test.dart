import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// C4 Chat-UX: hook live per tool turn — [TikoRuntime.chat]/[TikoRuntime
/// .chatWithStatus] meneruskan `onToolStart` (sebelum eksekusi) dan
/// `onToolTrace` (nama, args tersanitasi, error, durasi) dari AgentLoop.
void main() {
  late Directory temp;
  late HttpServer fakeServer;
  late String configPath;
  late TikoRuntime rt;
  var requestCount = 0;
  final script = <Map<String, dynamic>>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_tool_trace_');
    script.clear();
    requestCount = 0;
    fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeServer.listen((req) async {
      await utf8.decoder.bind(req).join();
      final step = requestCount < script.length
          ? script[requestCount]
          : <String, dynamic>{'content': 'selesai'};
      requestCount++;
      req.response.headers.contentType =
          ContentType.parse('text/event-stream');
      if (step.containsKey('tool')) {
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_$requestCount',
                      'function': {
                        'name': step['tool'],
                        'arguments': jsonEncode(step['args'] ?? {}),
                      },
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
      } else {
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': step['content'] ?? 'selesai'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
      }
      req.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'total_tokens': 2,
          },
        })}\n\n',
      );
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });
    final configDir = Directory(p.join(temp.path, 'config'))
      ..createSync(recursive: true);
    final config = File(p.join(configDir.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: fake
  chat:
    fake:
      type: openai_compat
      base_url: "http://127.0.0.1:${fakeServer.port}"
      model: fake-1
agent:
  max_iterations: 4
''');
    configPath = config.path;
    rt = await TikoRuntime.create(configPath: configPath);
  });

  tearDown(() async {
    await rt.close();
    await fakeServer.close(force: true);
    await temp.delete(recursive: true);
  });

  test('onToolStart + onToolTrace dipanggil saat tool turn dieksekusi',
      () async {
    script.addAll([
      {'tool': 'datetime', 'args': <String, dynamic>{}},
      {'content': 'sudah dijawab'},
    ]);
    final starts = <String>[];
    final traces = <ToolCallTrace>[];
    final res = await rt.chatWithStatus(
      'jam berapa sekarang?',
      sessionId: 'trace:test',
      onToolStart: starts.add,
      onToolTrace: traces.add,
    );

    expect(res.success, isTrue, reason: res.text);
    expect(res.toolCallCount, 1);
    expect(starts, ['datetime']);
    expect(traces, hasLength(1));
    expect(traces.single.name, 'datetime');
    expect(traces.single.isError, isFalse);
  });

  test('tanpa hook, turn tetap jalan (param opsional)', () async {
    final res = await rt.chatWithStatus(
      'halo',
      sessionId: 'trace:plain',
    );
    expect(res.success, isTrue, reason: res.text);
    expect(res.toolCallCount, 0);
  });
}
