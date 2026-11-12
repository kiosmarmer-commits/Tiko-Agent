import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('isPrivateOrReserved mendeteksi alamat terlarang', () {
    expect(
      SsrfGuard.isPrivateOrReserved(InternetAddress('10.0.0.5')),
      isTrue,
    );
    expect(
      SsrfGuard.isPrivateOrReserved(InternetAddress('127.0.0.1')),
      isTrue,
    );
    expect(
      SsrfGuard.isPrivateOrReserved(InternetAddress('169.254.169.254')),
      isTrue,
    );
    expect(
      SsrfGuard.isPrivateOrReserved(InternetAddress('8.8.8.8')),
      isFalse,
    );
  });

  test('pinned client memblokir loopback sebelum TCP connect', () async {
    var connected = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      connected = true;
      await request.response.close();
    });
    final client = SsrfGuard().pinnedHttpClient();
    Object? caught;
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      await req.close();
    } catch (e) {
      caught = e;
    } finally {
      client.close();
      await server.close();
    }
    expect(caught, isNotNull, reason: 'request harus gagal');
    expect(
      connected,
      isFalse,
      reason: 'server tidak boleh menerima koneksi',
    );
  });
}
