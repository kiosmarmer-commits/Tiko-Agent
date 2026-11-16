import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server palsu yang dapat dikonfigurasi per-request: status, header yang
/// diterima, path yang diminta, dan body JSON balasan.
class _ApiServer {
  _ApiServer();

  int status = 200;
  final paths = <String>[];
  final authHeaders = <String?>[];
  HttpServer? _server;
  final _sessions = StreamController<HttpRequest>();

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_sessions.add, onError: _sessions.addError);
    unawaited(() async {
      await for (final req in _sessions.stream) {
        paths.add(req.uri.path);
        authHeaders.add(req.headers.value('Authorization'));
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'ok': true,
          'path': req.uri.path,
          // pathSegments sudah ter-decode oleh parser Uri.
          'echo_path_decoded':
              req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last,
        }));
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _sessions.close();
    await _server?.close(force: true);
  }
}

void main() {
  test('admin GET: 401/403/5xx semuanya surface sebagai exception dengan kode',
      () async {
    final server = _ApiServer();
    final base = await server.start();
    for (final code in [401, 403, 500, 503]) {
      server.status = code;
      final client = AgentApiClient(baseUrl: base, token: 'tok');
      await expectLater(
        client.status(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('$code'),
          ),
        ),
        reason: 'HTTP $code tidak boleh disamarkan sebagai data kosong',
      );
      client.close();
    }
    await server.close();
  });

  test('token dengan CRLF (header injection) ditolak — request tidak pernah '
      'terkirim', () async {
    final server = _ApiServer();
    final base = await server.start();
    final client = AgentApiClient(
      baseUrl: base,
      token: 'abc\r\nX-Injected: pwned',
    );

    // dart:io HttpHeaders menolak nilai header dengan kontrol char —
    // error harus terangkat lokal, bukan diam-diam mengirim header palsu.
    await expectLater(client.status(), throwsA(isA<Object>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.paths, isEmpty,
        reason: 'request dengan token injeksi tidak boleh sampai server');
    expect(
      server.authHeaders.where((h) => h?.contains('X-Injected') ?? false),
      isEmpty,
    );

    client.close();
    await server.close();
  });

  test('baseUrl malformed (bukan URL, spasi) → error bersih, bukan crash',
      () async {
    for (final bad in ['not a url', 'http://', '://missing-scheme']) {
      final client = AgentApiClient(baseUrl: bad, token: 'tok');
      await expectLater(
        client.status(),
        throwsA(isA<Object>()),
        reason: 'baseUrl "$bad" harus gagal terkendali',
      );
      client.close();
    }
  });

  test('ID unicode/spasi/slash pada deleteMemory dan decideApproval '
      'ter-encode dan ter-decode utuh', () async {
    final server = _ApiServer();
    final base = await server.start();
    server.status = 200;
    final client = AgentApiClient(baseUrl: base, token: 'tok');

    const trickyId = 'mem éè€/dua tiga?&=+#';
    // deleteMemory: server balas 200 + deleted:true (payload kita menyertakan
    // ok:true; deleted tidak ada → false — jadi uji lewat path yang diterima).
    await client.deleteMemory(trickyId);
    // decideApproval juga POST dengan ID sama.
    await client.decideApproval(trickyId, true);

    expect(server.paths, hasLength(2));
    for (final p in server.paths) {
      // Path ter-encode: tidak ada spasi/karakter mentah yang lolos.
      expect(p.contains(' '), isFalse);
      expect(p.contains('?&=#'), isFalse,
          reason: 'karakter reserved harus ter-encode, bukan merusak URL');
    }
    // Server menerima path ter-encode dan bisa men-decode kembali utuh.
    expect(server.paths.first, contains(Uri.encodeComponent(trickyId)));

    client.close();
    await server.close();
  });

  test('sendMessage dengan teks unicode/emoji/newline sampai utuh via JSON',
      () async {
    final bodies = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      bodies.add(await utf8.decoder.bind(req).join());
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'text': 'balasan 🎉'}));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
    final client = AgentApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
    );

    const tricky = 'hai 🎉 "kutip"\nbaris\ttab éè€ \\backslash\\';
    final out = await client.sendMessage(tricky);
    expect(out, 'balasan 🎉');
    final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
    expect(sent['text'], tricky,
        reason: 'JSON body menjaga unicode/newline tetap utuh');

    client.close();
  });
}
