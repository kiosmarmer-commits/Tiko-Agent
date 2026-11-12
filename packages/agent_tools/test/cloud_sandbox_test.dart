import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('daytona: run() POST exec + parse respons', () async {
    final requests = <Map<String, dynamic>>[];
    String? auth;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      auth = req.headers.value('authorization');
      requests.add(jsonDecode(body) as Map<String, dynamic>);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'exitCode': 3,
        'stdout': 'halo daytona',
        'stderr': 'peringatan',
      }));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    final runner = SandboxRunner(
      kind: SandboxKind.daytona,
      workspacePath: Directory.systemTemp.path,
      daytonaSandboxId: 'sbx-123',
      daytonaApiKey: 'dtk_secret',
      daytonaApiUrl: 'http://127.0.0.1:${server.port}',
    );
    final result = await runner.run(['echo', 'halo dunia']);
    expect(result.exitCode, 3);
    expect(result.stdout, 'halo daytona');
    expect(result.stderr, 'peringatan');
    expect(requests, hasLength(1));
    expect(requests.first['command'], 'echo halo dunia');
    expect(auth, 'Bearer dtk_secret');
  });

  test('daytona: HTTP 500 -> StateError', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = 500;
      req.response.write('boom');
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    final runner = SandboxRunner(
      kind: SandboxKind.daytona,
      workspacePath: Directory.systemTemp.path,
      daytonaSandboxId: 'sbx-123',
      daytonaApiKey: 'dtk_secret',
      daytonaApiUrl: 'http://127.0.0.1:${server.port}',
    );
    await expectLater(runner.run(['ls']), throwsStateError);
  });

  test('modal: run() memanggil CLI dengan argv benar', () async {
    final dir = await Directory.systemTemp.createTemp('tiko-modal');
    addTearDown(() => dir.delete(recursive: true));
    final shim = File('${dir.path}/modal-shim');
    await shim.writeAsString('#!/bin/sh\necho "ARGS: \$@"\necho "ERR-LINE" >&2\nexit 7\n');
    await Process.run('chmod', ['+x', shim.path]);

    final runner = SandboxRunner(
      kind: SandboxKind.modal,
      workspacePath: Directory.systemTemp.path,
      modalSandboxId: 'mb-777',
      modalBin: shim.path,
    );
    final result = await runner.run(['python', '-c', 'print(1)']);
    expect(result.exitCode, 7);
    expect(result.stdout, contains('sandbox'));
    expect(result.stdout, contains('mb-777'));
    expect(result.stdout, contains('python -c print(1)'));
    expect(result.stderr, contains('ERR-LINE'));
  });

  test('cloud kinds: startProcess ditolak (fail-closed)', () async {
    final modalRunner = SandboxRunner(
      kind: SandboxKind.modal,
      workspacePath: Directory.systemTemp.path,
      modalSandboxId: 'mb-1',
    );
    final daytonaRunner = SandboxRunner(
      kind: SandboxKind.daytona,
      workspacePath: Directory.systemTemp.path,
      daytonaSandboxId: 'sbx-1',
      daytonaApiKey: 'k',
    );
    await expectLater(modalRunner.startProcess(['ls']), throwsUnsupportedError);
    await expectLater(daytonaRunner.startProcess(['ls']), throwsUnsupportedError);
  });

  test('cloudFromEnv: daytona dari env; kosong -> null', () async {
    final daytona = await SandboxRunner.cloudFromEnv(environment: {
      'DAYTONA_SANDBOX_ID': 'sbx-9',
      'DAYTONA_API_KEY': 'dtk_9',
      'DAYTONA_API_URL': 'https://api.example.test',
    });
    expect(daytona, isNotNull);
    expect(daytona!.kind, SandboxKind.daytona);
    expect(daytona.daytonaSandboxId, 'sbx-9');
    expect(daytona.daytonaApiUrl, 'https://api.example.test');

    final none = await SandboxRunner.cloudFromEnv(environment: {});
    expect(none, isNull);

    final partial = await SandboxRunner.cloudFromEnv(environment: {
      'MODAL_SANDBOX_ID': 'mb-9',
    });
    expect(partial, isNull);
  });

  test('konstruktor cloud divalidasi (assert)', () {
    expect(
      () => SandboxRunner(kind: SandboxKind.modal),
      throwsA(isA<Error>()),
    );
    expect(
      () => SandboxRunner(kind: SandboxKind.daytona, daytonaSandboxId: 'sbx'),
      throwsA(isA<Error>()),
    );
  });
}
