import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Server OpenAI-compatible palsu yang menyertakan header `x-ratelimit-*`
/// (format Nous Portal) pada setiap respons chat — untuk memverifikasi
/// wiring rate-limit tracker fase 5.
class _FakeOpenAI {
  _FakeOpenAI._(this._server);
  final HttpServer _server;

  static Future<_FakeOpenAI> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _FakeOpenAI._(server);
    server.listen((req) async {
      req.response.headers.set('x-ratelimit-limit-requests', '100');
      req.response.headers.set('x-ratelimit-remaining-requests', '90');
      req.response.headers.set('x-ratelimit-reset-requests', '30');
      req.response.headers.contentType =
          ContentType.parse('text/event-stream');
      req.response.write(
        'data: {"choices": [{"delta": {"content": "dari provider palsu"}, '
        '"finish_reason": null}]}\n\n'
        'data: {"choices": [{"delta": {}, "finish_reason": "stop"}], '
        '"usage": {"prompt_tokens": 1, "completion_tokens": 1, '
        '"total_tokens": 2}}\n\n'
        'data: [DONE]\n\n',
      );
      await req.response.close();
    }, onError: (Object _) {});
    return api;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> close() => _server.close(force: true);
}

Future<String> _prepare(Directory temp, String baseUrl) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
    fake:
      type: openai_compat
      base_url: "$baseUrl"
      model: fake-1
agent:
  max_iterations: 4
''');
  return config.path;
}

void main() {
  late Directory temp;
  late _FakeOpenAI fake;
  late String configPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase5_');
    fake = await _FakeOpenAI.start();
    configPath = await _prepare(temp, fake.baseUrl);
  });

  tearDown(() async {
    await fake.close();
    await temp.delete(recursive: true);
  });

  group('/btw (side question)', () {
    test('menjawab pertanyaan tanpa mengubah riwayat sesi', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      await rt.chat('halo satu');
      await rt.chat('halo dua');
      final before = await rt.sessions.recent('cli:default', limit: 50);

      final answer = await rt.chat('/btw apa yang tadi saya tanyakan?');
      expect(answer, isNotEmpty);
      expect(answer, isNot(startsWith('Pakai:')));
      expect(answer, isNot(contains('masih berjalan')));

      final after = await rt.sessions.recent('cli:default', limit: 50);
      expect(after.length, before.length,
          reason: 'side question tidak menambah turn ke riwayat');
      for (var i = 0; i < after.length; i++) {
        expect(after[i].content, before[i].content);
      }
    });

    test('/btw tanpa argumen → pesan pemakaian', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final out = await rt.chat('/btw');
      expect(out, contains('Pakai: /btw'));
    });

    test('/btw beruntun dilarang oleh lease (satu aktif per sesi)', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('isi riwayat dulu');
      final results = await Future.wait([
        rt.chat('/btw pertanyaan paralel 1'),
        rt.chat('/btw pertanyaan paralel 2'),
      ]);
      final busy = results.where((r) => r.contains('masih berjalan'));
      expect(busy, hasLength(1),
          reason: 'tepat satu /btw paralel ditolak lease');
    });
  });

  group('/compact (kompresi manual)', () {
    test('riwayat pendek ditolak', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final out = await rt.chat('/compact');
      expect(out, contains('terlalu pendek'));
    });

    test('riwayat panjang terkompresi + persist', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      for (var i = 0; i < 5; i++) {
        await rt.chat('pertanyaan ke-$i');
      }
      final before = await rt.sessions.recent('cli:default', limit: 100);
      expect(before.length, 10);

      final out = await rt.chat('/compact');
      expect(out, contains('Kompresi selesai'));

      final after = await rt.sessions.recent('cli:default', limit: 100);
      expect(after.first.role, 'system');
      expect(after.first.content,
          startsWith('Ringkasan percakapan sebelumnya:'));
      expect(after.length, lessThan(before.length),
          reason: 'ringkasan + keepLastN 6 < 10 pesan asli? ringkasan + 6');
      expect(after.length, 7);

      final turn = await rt.chat('halo setelah kompaksi');
      expect(turn, isNotEmpty,
          reason: 'turn berikutnya tetap jalan setelah /compact');
    });
  });

  group('/usage', () {
    test('menampilkan pemakaian + anggaran + rate limit provider', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      final empty = await rt.chat('/usage');
      expect(empty, contains('turn: 0'));
      expect(empty, contains('belum ada header x-ratelimit'));

      await rt.chat('/model fake');
      await rt.chat('halo via fake');
      final out = await rt.chat('/usage');
      expect(out, contains('turn: '));
      expect(out, contains('token: '));
      expect(out, contains('Rate limit provider'));
      expect(out, contains('fake: 10/100 req'),
          reason: 'header x-ratelimit dari server palsu tertangkap');
    });
  });
}
