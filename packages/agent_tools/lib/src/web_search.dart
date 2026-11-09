import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'ssrf.dart';

/// web_search via SearXNG with an optional Tavily fallback (AGD-04 §7).
class WebSearchTool implements Tool {
  WebSearchTool({
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.tavilyApiKey,
    this.tavilyBaseUrl = 'https://api.tavily.com',
    this.maxResults = 8,
    this.fetchTop = 3,
    this.fetchMaxChars = 2500,
    http.Client? client,
    SsrfGuard? ssrf,
  }) : _client = client,
       _ssrf = ssrf ?? SsrfGuard();

  final String searxngBaseUrl;

  /// Tavily API key (`tvly-...`). Null/empty berarti fallback nonaktif.
  final String? tavilyApiKey;
  final String tavilyBaseUrl;
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
        'Cari di web lewat SearXNG dengan cadangan Tavily bila terpasang. '
        'Mengembalikan judul, URL, cuplikan; opsional mengunduh isi singkat '
        'dari N hasil teratas.',
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

    final tavilyKey = (tavilyApiKey ?? '').trim();
    final client = _client ?? http.Client();
    try {
      final (hits, engine) = await _acquireHits(
        client,
        query,
        categories,
        tavilyKey,
      );
      if (hits.isEmpty) {
        return const ToolResult(callId: '', content: 'Tidak ada hasil.');
      }

      final lines = <String>[];
      final citations = <Map<String, String>>[];
      var i = 0;
      final seen = <String>{};
      for (final h in hits) {
        if (i >= maxResults) break;
        if (h.url.isEmpty || seen.contains(h.url)) continue;
        seen.add(h.url);
        i++;
        citations.add({'n': '$i', 'title': h.title, 'url': h.url});
        lines.add(
          '$i. ${h.title}\n   ${h.url}\n   '
          '${h.content.length > 240 ? '${h.content.substring(0, 240)}…' : h.content}',
        );
      }
      if (citations.isEmpty) {
        return const ToolResult(callId: '', content: 'Tidak ada hasil.');
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
      if (engine == 'tavily') {
        buf.writeln('## Mesin: Tavily (cadangan; SearXNG tidak tersedia)');
      }
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
    } on _SearchFailure catch (e) {
      return ToolResult(callId: '', content: e.message, isError: true);
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

  /// SearXNG first; bila gagal pada level transport dan key terpasang,
  /// coba Tavily (AGD-04 §7: cadangan berbayar/terkelola).
  Future<(List<({String title, String url, String content})>, String)>
  _acquireHits(
    http.Client client,
    String query,
    String categories,
    String tavilyKey,
  ) async {
    try {
      return (await _searchSearxng(client, query, categories), 'searxng');
    } on _SearchFailure catch (searxError) {
      if (!searxError.fallbackEligible || tavilyKey.isEmpty) {
        throw searxError;
      }
      try {
        return (
          await _searchTavily(client, query, categories, tavilyKey),
          'tavily',
        );
      } on _SearchFailure catch (tavilyError) {
        throw _SearchFailure(
          'SearXNG gagal: ${searxError.message}\n'
          'Tavily gagal: ${tavilyError.message}',
          fallbackEligible: false,
        );
      }
    }
  }

  Future<List<({String title, String url, String content})>> _searchSearxng(
    http.Client client,
    String query,
    String categories,
  ) async {
    final uri = Uri.parse(searxngBaseUrl).replace(
      path: '/search',
      queryParameters: {'q': query, 'format': 'json', 'categories': categories},
    );
    final http.Response res;
    try {
      res = await client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'agent_dart/0.1',
            },
          )
          .timeout(const Duration(seconds: 18));
    } catch (e) {
      throw _SearchFailure(
        'web_search error: $e\n'
        'Pastikan SearXNG jalan di $searxngBaseUrl dengan format JSON.',
        fallbackEligible: true,
      );
    }
    if (res.statusCode == 403) {
      throw const _SearchFailure(
        'SearXNG menolak format=json. '
        'Aktifkan di settings.yml: search.formats: [html, json]',
        fallbackEligible: false,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'SearXNG HTTP ${res.statusCode}',
        fallbackEligible: res.statusCode >= 500,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return _hitsFrom(json);
  }

  Future<List<({String title, String url, String content})>> _searchTavily(
    http.Client client,
    String query,
    String categories,
    String tavilyKey,
  ) async {
    final tavilyCheck = await _ssrf.checkUrl(tavilyBaseUrl);
    if (tavilyCheck != null) {
      throw _SearchFailure(
        'Tavily base URL ditolak: $tavilyCheck',
        fallbackEligible: false,
      );
    }
    final uri = Uri.parse(tavilyBaseUrl).replace(path: '/search');
    final http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $tavilyKey',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'search_depth': 'basic',
              'max_results': maxResults,
              'topic': categories == 'news' ? 'news' : 'general',
              'include_answer': false,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _SearchFailure('Tavily error: $e', fallbackEligible: false);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw _SearchFailure(
        'Tavily auth ditolak (HTTP ${res.statusCode}) — periksa API key',
        fallbackEligible: false,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'Tavily HTTP ${res.statusCode}',
        fallbackEligible: false,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return _hitsFrom(json);
  }

  static List<({String title, String url, String content})> _hitsFrom(
    Map<String, dynamic> json,
  ) {
    final results = json['results'] as List<dynamic>? ?? [];
    final hits = <({String title, String url, String content})>[];
    for (final raw in results) {
      if (raw is! Map<String, dynamic>) continue;
      hits.add((
        title: (raw['title'] as String?) ?? '(tanpa judul)',
        url: (raw['url'] as String?) ?? '',
        content: (raw['content'] as String?) ?? '',
      ));
    }
    return hits;
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

/// Kegagalan satu mesin pencarian; [fallbackEligible] menandai kegagalan
/// level transport di mana mencoba mesin lain masuk akal.
class _SearchFailure implements Exception {
  const _SearchFailure(this.message, {required this.fallbackEligible});

  final String message;
  final bool fallbackEligible;
}
