import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// C2 Chat-UX: lampiran inline base64 pada POST /v1/messages dan frame
/// WS `/v1/stream` — validasi fail-closed (jumlah, nama, mime allowlist,
/// base64, batas 2 MiB) dan pemetaan ke `InboundMessage.attachments`.
void main() {
  late HttpApiServer server;
  String? lastText;
  List<dynamic>? lastAttachments;

  setUp(() async {
    lastText = null;
    lastAttachments = null;
    server = HttpApiServer(
      onMessage: (msg) async {
        lastText = msg.text;
        lastAttachments = [
          for (final a in msg.attachments)
            {
              'type': a.type,
              'name': a.name,
              'mime': a.mime,
              'bytes': (a.urlOrBytes is List<int>)
                  ? (a.urlOrBytes as List<int>).length
                  : -1,
            },
        ];
        return 'balasan: ${msg.text}';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<(HttpClientResponse, String)> send(
    String path, {
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl('POST', uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final res = await request.close();
      final text = await res.transform(utf8.decoder).join();
      return (res, text);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> requestTicket() async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/auth/ticket'),
      );
      req.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      expect(res.statusCode, lessThan(400),
          reason: 'ticket harus tersedia untuk WS test: $body');
      return (jsonDecode(body) as Map<String, dynamic>)['ticket'] as String;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> messageBody({Object? attachments}) => {
        'text': 'tolong baca lampiran',
        'session_key': 'http:test',
        if (attachments != null) 'attachments': attachments,
      };

  test('lampiran teks valid diteruskan ke InboundMessage', () async {
    final content = base64.encode(utf8.encode('isi laporan.md\nbaris dua'));
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {'name': 'laporan.md', 'mime': 'text/plain', 'data_base64': content},
      ]),
    );
    expect(res.statusCode, 200);
    expect(lastText, 'tolong baca lampiran');
    expect(lastAttachments, isA<List<dynamic>>());
    final att = (lastAttachments as List).single as Map;
    expect(att['type'], 'document');
    expect(att['name'], 'laporan.md');
    expect(att['mime'], 'text/plain');
    expect((att['bytes'] as num) > 0, isTrue);
    expect(body, contains('balasan'));
  });

  test('lampiran gambar valid dipetakan type image', () async {
    final png = base64.encode([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]);
    final (res, _) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {'name': 'snap.png', 'mime': 'image/png', 'data_base64': png},
      ]),
    );
    expect(res.statusCode, 200);
    final att = (lastAttachments as List).single as Map;
    expect(att['type'], 'image');
    expect(att['mime'], 'image/png');
  });

  test('tanpa attachments tetap bekerja (array kosong tidak wajib)', () async {
    final (res, _) = await send('/v1/messages', body: messageBody());
    expect(res.statusCode, 200);
    expect(lastAttachments, isEmpty);
  });

  test('lebih dari 4 lampiran ditolak 400', () async {
    final att = [
      for (var i = 0; i < 5; i++)
        {
          'name': 'f$i.txt',
          'mime': 'text/plain',
          'data_base64': base64.encode(utf8.encode('x')),
        },
    ];
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: att),
    );
    expect(res.statusCode, 400);
    expect(body, contains('maksimum 4 lampiran'));
  });

  test('mime di luar allowlist ditolak 400', () async {
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {
          'name': 'arch.zip',
          'mime': 'application/zip',
          'data_base64': base64.encode([1, 2, 3]),
        },
      ]),
    );
    expect(res.statusCode, 400);
    expect(body, contains('mime'));
  });

  test('ukuran melebihi 2 MiB ditolak 400', () async {
    final big = base64.encode(utf8.encode('x' * (2 * 1024 * 1024 + 10)));
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {'name': 'big.txt', 'mime': 'text/plain', 'data_base64': big},
      ]),
    );
    expect(res.statusCode, 400);
    expect(body, contains('terlalu besar'));
  });

  test('base64 invalid ditolak 400', () async {
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {'name': 'a.txt', 'mime': 'text/plain', 'data_base64': '@@@@'},
      ]),
    );
    expect(res.statusCode, 400);
    expect(body, contains('data_base64'));
  });

  test('nama karakter kontrol ditolak 400', () async {
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: [
        {
          'name': '../evil\u0000.txt',
          'mime': 'text/plain',
          'data_base64': base64.encode(utf8.encode('x')),
        },
      ]),
    );
    expect(res.statusCode, 400);
    expect(body, contains('nama wajib'));
  });

  test('attachments bukan array ditolak 400', () async {
    final (res, body) = await send(
      '/v1/messages',
      body: messageBody(attachments: 'bukan-array'),
    );
    expect(res.statusCode, 400);
    expect(body, contains('harus berupa array'));
  });

  test('WS /v1/stream lampiran valid diteruskan ke InboundMessage', () async {
    final uri = Uri.parse('ws://127.0.0.1:${server.boundPort}/v1/stream')
        .replace(queryParameters: {
      'ticket': await requestTicket(),
    });
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({
        'text': 'baca lampiran ws',
        'attachments': [
          {
            'name': 'catatan.md',
            'mime': 'text/plain',
            'data_base64': base64.encode(utf8.encode('isi ws')),
          },
        ],
      }));
      final frames = <Map<String, dynamic>>[];
      await for (final raw in ws.timeout(const Duration(seconds: 10))) {
        frames.add(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
        if (frames.last['type'] == 'done') break;
      }
      expect(frames.any((f) => f['type'] == 'text'), isTrue);
      final att = (lastAttachments as List).single as Map;
      expect(att['name'], 'catatan.md');
    } finally {
      await ws.close();
    }
  });

  test('WS lampiran invalid menghasilkan frame error, bukan prompt jalan',
      () async {
    final uri = Uri.parse('ws://127.0.0.1:${server.boundPort}/v1/stream')
        .replace(queryParameters: {'ticket': await requestTicket()});
    final ws = await WebSocket.connect(uri.toString());
    try {
      ws.add(jsonEncode({
        'text': 'baca lampiran ws',
        'attachments': [
          {'name': 'x.zip', 'mime': 'application/zip', 'data_base64': 'aGk='},
        ],
      }));
      final frames = <Map<String, dynamic>>[];
      await for (final raw in ws.timeout(const Duration(seconds: 10))) {
        frames.add(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
        if (frames.last['type'] == 'error') break;
      }
      expect(frames.last['type'], 'error');
      expect(frames.last['message'], contains('mime'));
      expect(lastText, isNull);
    } finally {
      await ws.close();
    }
  });

}
