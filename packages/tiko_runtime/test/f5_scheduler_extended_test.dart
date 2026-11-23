import 'dart:io';
import 'dart:async';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Fase F5 (docs/15 §6) — probe watcher, digest harian deterministik, dan
/// suntik konteks antar-job di sisi runtime.

Job _probeJob({List<String> contextFrom = const []}) => Job(
      id: 'job-f5',
      cron: '*/5 * * * *',
      prompt: 'cek status target',
      channel: 'cli',
      userKey: 'u1',
      nextRun: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      contextFrom: contextFrom,
    );

void main() {
  group('digest prompt prefix', () {
    test('isDigestJobPrompt: prefix tepat vs normal', () {
      expect(isDigestJobPrompt('[DIGEST]'), isTrue);
      expect(isDigestJobPrompt('  [DIGEST] setelah spasi'), isTrue);
      expect(isDigestJobPrompt('[RISET] siapa presiden Indonesia'), isFalse);
      expect(isDigestJobPrompt('halo dunia'), isFalse);
    });
  });

  group('buildJobContextBlock', () {
    test('kosong bila job tanpa context_from', () {
      final job = _probeJob(contextFrom: const []);
      final block = buildJobContextBlock(
        job,
        outputFor: (_) => 'x',
        atFor: (_) => DateTime.now().toUtc(),
      );
      expect(block, isEmpty);
    });

    test('menyuntik output + timestamp job sumber', () {
      final job = _probeJob(contextFrom: ['src-1', 'src-2']);
      final at = DateTime.utc(2025, 1, 1, 8, 0);
      final block = buildJobContextBlock(
        job,
        outputFor: (id) => id == 'src-1' ? 'output pertama' : null,
        atFor: (id) => id == 'src-1' ? at : null,
      );
      expect(block, contains('[Konteks otomatis dari job lain'));
      expect(block, contains('- job src-1 (${at.toIso8601String()}):'));
      expect(block, contains('output pertama'));
      expect(block, contains('job src-2: belum ada output tercatat'));
      expect(block, contains('read-only'));
    });

    test('setiap baris output di-indent', () {
      final job = _probeJob(contextFrom: ['src-1']);
      final block = buildJobContextBlock(
        job,
        outputFor: (_) => 'baris1\nbaris2',
        atFor: (_) => null,
      );
      expect(block, contains('  baris1\n  baris2'));
    });
  });

  group('runWatchProbe', () {
    late HttpServer server;
    late String url;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${server.port}/status';
      server.listen((req) async {
        final body = req.uri.queryParameters['body'] ?? 'ok';
        final status = int.tryParse(req.uri.queryParameters['status'] ?? '') ??
            200;
        req.response.statusCode = status;
        req.response.write(body);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('probe sukses: fingerprint berisi status+panjang+checksum', () async {
      final res = await runWatchProbe(WatchProbe.url(url));
      expect(res.ok, isTrue);
      expect(res.error, isNull);
      expect(res.fingerprint, startsWith('http:200:'));
      expect(res.fingerprint, endsWith(fnv1aHex('ok')));
      expect(res.detail, contains('status 200'));
    });

    test('konektivitas gagal -> error, tanpa melempar', () async {
      await server.close(force: true);
      final res = await runWatchProbe(
        WatchProbe.url('http://127.0.0.1:1/unreachable'),
      );
      expect(res.ok, isFalse);
      expect(res.fingerprint, 'error');
      expect(res.error, isNotNull);
    });
  });

  group('buildDailyDigest (runtime nyata)', () {
    late Directory temp;
    late TikoRuntime runtime;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('f5-digest-test');
      final configPath = File('${temp.path}/config.yaml');
      await configPath.writeAsString('''
providers:
  mock:
    type: openai_compat
    base_url: http://127.0.0.1:1/v1
    api_key: sk-test
default_provider: mock
data_dir: ${temp.path}/data
memory:
  backend: json
logs_dir: ${temp.path}/logs
workspace: ${temp.path}/workspace
security:
  mode: ask
mcp:
  servers: []
''');
      runtime = await TikoRuntime.create(configPath: configPath.path);
      addTearDown(runtime.close);
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('digest berisi header tanggal + status kanban & scheduler', () async {
      final digest = await runtime.buildDailyDigest();
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      expect(digest, contains('Digest harian'));
      expect(digest, contains(today));
      expect(digest, contains('Kanban:'));
      expect(digest, contains('Scheduler:'));
      expect(digest, contains('semua job sehat'));
    });
  });
}
