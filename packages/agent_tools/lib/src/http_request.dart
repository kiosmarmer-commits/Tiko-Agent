import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'ssrf.dart';

/// http_request — high risk, domain allowlist + SSRF (AGD-03).
class HttpRequestTool implements Tool {
  HttpRequestTool({
    this.domainAllowlist = const [],
    SsrfGuard? ssrf,
    http.Client? client,
  }) : _ssrf = ssrf ?? SsrfGuard(),
       _client = client;

  final List<String> domainAllowlist;
  final SsrfGuard _ssrf;
  final http.Client? _client;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'http_request',
    description:
        'HTTP request ke domain yang diizinkan. method GET/POST/PUT/DELETE. Body opsional.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'method': {'type': 'string'},
        'url': {'type': 'string'},
        'headers': {'type': 'object'},
        'body': {'type': 'string'},
      },
      'required': ['url'],
    },
    risk: 'high',
    timeoutSec: 30,
    maxOutputChars: 50000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final url = (args['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) {
      return const ToolResult(callId: '', content: 'url wajib', isError: true);
    }
    final method = ((args['method'] as String?) ?? 'GET').toUpperCase();
    final ssrfErr = await _ssrf.checkUrl(url);
    if (ssrfErr != null) {
      return ToolResult(
        callId: '',
        content: 'SSRF blocked: $ssrfErr',
        isError: true,
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const ToolResult(
        callId: '',
        content: 'URL invalid',
        isError: true,
      );
    }
    if (domainAllowlist.isNotEmpty) {
      final host = uri.host.toLowerCase();
      final ok = domainAllowlist.any((d) {
        final dd = d.toLowerCase();
        return host == dd || host.endsWith('.$dd');
      });
      if (!ok) {
        return ToolResult(
          callId: '',
          content: 'Domain tidak di allowlist: $host',
          isError: true,
        );
      }
    }

    final headers = <String, String>{'User-Agent': 'agent_dart/0.1'};
    final rawHeaders = args['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        headers['$k'] = '$v';
      });
    }
    final body = args['body'] as String?;
    final client = _client ?? IOClient(_ssrf.pinnedHttpClient());
    try {
      late http.Response res;
      switch (method) {
        case 'POST':
          res = await client
              .post(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 25));
          break;
        case 'PUT':
          res = await client
              .put(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 25));
          break;
        case 'DELETE':
          res = await client
              .delete(uri, headers: headers)
              .timeout(const Duration(seconds: 25));
          break;
        default:
          res = await client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 25));
      }
      var content = res.body;
      if (content.length > 40000) content = '${content.substring(0, 40000)}…';
      // Taint is applied by host when wrapping; mark clearly
      return ToolResult(
        callId: '',
        content:
            '<untrusted_data source="http_request">\nHTTP ${res.statusCode}\n$content\n</untrusted_data>',
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'http_request error: $e',
        isError: true,
      );
    } finally {
      if (_client == null) client.close();
    }
  }
}
