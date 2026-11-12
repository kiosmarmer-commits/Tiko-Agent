import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// SsrfGuard yang selalu lolos agar tes tidak melakukan DNS lookup.
class _NoopSsrf extends SsrfGuard {
  @override
  Future<String?> checkUrl(String url) async => null;
}

const _searxBody = {
  'results': [
    {
      'url': 'https://searx.example/a',
      'title': 'Hasil SearXNG',
      'content': 'dari searxng',
    },
  ],
};

const _tavilyBody = {
  'results': [
    {
      'url': 'https://tavily.example/b',
      'title': 'Hasil Tavily',
      'content': 'dari tavily',
    },
  ],
};

(http.Client, List<String>) _recordingClient(
  Future<http.Response> Function(http.Request) handler,
) {
  final hosts = <String>[];
  final client = MockClient((request) {
    hosts.add(request.url.host);
    return handler(request);
  });
  return (client, hosts);
}

Future<ToolResult> _run(WebSearchTool tool) async {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');
  return tool.run(
    {'query': 'tes'},
    ToolContext(session: session, workspacePath: '.'),
  );
}

Future<http.Response> _searxDown(http.Request request) async {
  throw Exception('connection refused');
}

WebSearchTool _tool({http.Client? client, String? key}) => WebSearchTool(
  searxngBaseUrl: 'http://127.0.0.1:8080',
  tavilyApiKey: key,
  fetchTop: 0,
  ssrf: _NoopSsrf(),
  client: client,
);

void main() {
  test('fallback ke Tavily saat SearXNG mati', () async {
    String? auth;
    Map<String, dynamic>? body;
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') return _searxDown(request);
      auth = request.headers['authorization'];
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode(_tavilyBody), 200);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isFalse);
    expect(r.content, contains('Hasil Tavily'));
    expect(r.content, contains('https://tavily.example/b'));
    expect(r.content, contains('Tavily (cadangan'));
    expect(hosts, contains('api.tavily.com'));
    expect(auth, 'Bearer tvly-test');
    expect(body!['query'], 'tes');
    expect(body!['max_results'], 8);
  });

  test('SearXNG HTTP 503 memicu fallback Tavily', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') {
        return http.Response('unavailable', 503);
      }
      return http.Response(jsonEncode(_tavilyBody), 200);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isFalse);
    expect(r.content, contains('Hasil Tavily'));
    expect(hosts, contains('api.tavily.com'));
  });

  test('SearXNG HTTP 403 tetap error konfigurasi tanpa fallback', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') {
        return http.Response('forbidden', 403);
      }
      return http.Response(jsonEncode(_tavilyBody), 200);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isTrue);
    expect(r.content, contains('settings.yml'));
    expect(hosts, isNot(contains('api.tavily.com')));
  });

  test('SearXNG mati tanpa key tetap error SearXNG', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') return _searxDown(request);
      return http.Response(jsonEncode(_tavilyBody), 200);
    });
    final r = await _run(_tool(client: client));
    expect(r.isError, isTrue);
    expect(r.content, contains('SearXNG'));
    expect(hosts, isNot(contains('api.tavily.com')));
  });

  test('SearXNG mati dan Tavily 401 menghasilkan error gabungan', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') return _searxDown(request);
      return http.Response('unauthorized', 401);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isTrue);
    expect(r.content, contains('SearXNG'));
    expect(r.content, contains('Tavily auth ditolak'));
    expect(hosts, contains('api.tavily.com'));
  });

  test('SearXNG sehat tidak memanggil Tavily', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') {
        return http.Response(jsonEncode(_searxBody), 200);
      }
      return http.Response(jsonEncode(_tavilyBody), 200);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isFalse);
    expect(r.content, contains('Hasil SearXNG'));
    expect(hosts, isNot(contains('api.tavily.com')));
  });

  test('Tavily hasil kosong mengembalikan tidak ada hasil', () async {
    final (client, hosts) = _recordingClient((request) async {
      if (request.url.host == '127.0.0.1') return _searxDown(request);
      return http.Response(jsonEncode({'results': <dynamic>[]}), 200);
    });
    final r = await _run(_tool(client: client, key: 'tvly-test'));
    expect(r.isError, isFalse);
    expect(r.content, 'Tidak ada hasil.');
    expect(hosts, contains('api.tavily.com'));
  });
}
