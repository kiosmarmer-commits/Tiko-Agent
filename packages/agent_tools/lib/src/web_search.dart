import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'ssrf.dart';

/// web_search via SearXNG + optional fetch top-N pages (AGD-04 §7).
class WebSearchTool implements Tool {
  WebSearchTool({
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.maxResults = 8,
    this.fetchTop = 3,
    this.fetchMaxChars = 2500,
    http.Client? client,
    SsrfGuard? ssrf,
  }) : _client = client,
       _ssrf = ssrf ?? SsrfGuard();

  final String searxngBaseUrl;
  final int maxResults;
  final int fetchTop;
  final int fetchMaxChars;
  final http.Client? _client;
  final SsrfGuard _ssrf;

  /// Simple TTL citation cache: url → (expires, snippet)
  static final _cache = <String, ({DateTime exp, String text})>{};
  static const cacheTtl = Duration(hours: 1);

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'web_search',
    description:
        'Cari di web lewat SearXNG. Mengembalikan judul, URL, cuplikan; '
        'opsional mengunduh isi singkat dari N hasil teratas.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Kata kunci pencarian'},
        'categories': {
          'type': 'string',
          'description': 'general | news | science (opsional)',
        },
        'fetch_pages': {
          'type': 'boolean',
          'description': 'Unduh isi singkat top hasil (default true)',
        },
      },
      'required': ['query'],
    },
    risk: 'low',
    timeoutSec: 45,
    maxOutputChars: 60000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'query wajib',
        isError: true,
      );
    }
    final categories = (args['categories'] as String?)?.trim() ?? 'general';
    final doFetch = args['fetch_pages'] != false;

    final baseUri = Uri.tryParse(searxngBaseUrl);
    final isLocalSearx =
        baseUri != null &&
        (baseUri.host == '127.0.0.1' ||
            baseUri.host == 'localhost' ||
            baseUri.host == '::1');
    final baseCheck = await _ssrf.checkUrl(searxngBaseUrl);
    if (baseCheck != null && !isLocalSearx) {
      return ToolResult(
        callId: '',
        content: 'SearXNG base URL ditolak: $baseCheck',
        isError: true,
      );
    }

    final uri = Uri.parse(searxngBaseUrl).replace(
      path: '/search',
      queryParameters: {'q': query, 'format': 'json', 'categories': categories},
    );

    final client = _client ?? http.Client();
    try {
      final res = await client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'agent_dart/0.1',
            },
          )
          .timeout(const Duration(seconds: 18));

      if (res.statusCode == 403) {
        return const ToolResult(
          callId: '',
          content:
              'SearXNG menolak format=json. Aktifkan di settings.yml: search.formats: [html, json]',
          isError: true,
        );
      }
      if (res.statusCode >= 400) {
        return ToolResult(
          callId: '',
          content: 'SearXNG HTTP ${res.statusCode}',
          isError: true,
        );
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (json['results'] as List<dynamic>? ?? []);
      if (results.isEmpty) {
        return const ToolResult(callId: '', content: 'Tidak ada hasil.');
      }

      final lines = <String>[];
      final citations = <Map<String, String>>[];
      var i = 0;
      final seen = <String>{};
      for (final raw in results) {
        if (i >= maxResults) break;
        final r = raw as Map<String, dynamic>;
        final url = (r['url'] as String?) ?? '';
        final title = (r['title'] as String?) ?? '(tanpa judul)';
        final content = (r['content'] as String?) ?? '';
        if (url.isEmpty || seen.contains(url)) continue;
        seen.add(url);
        i++;
        citations.add({'n': '$i', 'title': title, 'url': url});
        lines.add(
          '$i. $title\n   $url\n   ${content.length > 240 ? '${content.substring(0, 240)}…' : content}',
        );
      }

      // Fetch top-N page bodies (SSRF-checked), with TTL cache
      final pageBlocks = <String>[];
      if (doFetch && fetchTop > 0) {
        final top = citations.take(fetchTop);
        for (final c in top) {
          final url = c['url']!;
          final cached = _cache[url];
          if (cached != null && cached.exp.isAfter(DateTime.now().toUtc())) {
            pageBlocks.add('[${c['n']}] ${c['title']}\n${cached.text}');
            continue;
          }
          final err = await _ssrf.checkUrl(url);
          if (err != null) {
            pageBlocks.add('[${c['n']}] ${c['title']}\n(SSRF blocked: $err)');
            continue;
          }
          try {
            final page = await client
                .get(Uri.parse(url), headers: {'User-Agent': 'agent_dart/0.1'})
                .timeout(const Duration(seconds: 12));
            if (page.statusCode >= 400) {
              pageBlocks.add('[${c['n']}] HTTP ${page.statusCode}');
              continue;
            }
            final text = _stripHtml(page.body);
            final snippet = text.length > fetchMaxChars
                ? '${text.substring(0, fetchMaxChars)}…'
                : text;
            _cache[url] = (
              exp: DateTime.now().toUtc().add(cacheTtl),
              text: snippet,
            );
            pageBlocks.add('[${c['n']}] ${c['title']}\n$snippet');
          } catch (e) {
            pageBlocks.add('[${c['n']}] fetch error: $e');
          }
        }
      }

      final buf = StringBuffer();
      buf.writeln('<untrusted_data source="web_search">');
      buf.writeln('## Hasil pencarian: $query');
      buf.writeln(lines.join('\n\n'));
      if (pageBlocks.isNotEmpty) {
        buf.writeln('\n## Isi halaman (top $fetchTop)');
        buf.writeln(pageBlocks.join('\n\n---\n\n'));
      }
      buf.writeln('\n## Sitasi');
      for (final c in citations) {
        buf.writeln('[${c['n']}] ${c['title']} — ${c['url']}');
      }
      buf.writeln('</untrusted_data>');

      return ToolResult(callId: '', content: buf.toString());
    } catch (e) {
      return ToolResult(
        callId: '',
        content:
            'web_search error: $e\nPastikan SearXNG jalan di $searxngBaseUrl dengan format JSON.',
        isError: true,
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  static String _stripHtml(String html) {
    final s = html
        .replaceAll(
          RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s;
  }
}
