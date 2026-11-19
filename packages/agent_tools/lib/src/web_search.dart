import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;

import 'ssrf.dart';

/// web_search via multiple providers with fallback chain (AGD-04 §7).
/// Supports: SearXNG, Tavily, DDGS (DuckDuckGo), Brave, Exa, Firecrawl
class WebSearchTool implements Tool {
  WebSearchTool({
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.tavilyApiKey,
    this.tavilyBaseUrl = 'https://api.tavily.com',
    this.ddgsEnabled = true,
    this.braveApiKey,
    this.braveBaseUrl = 'https://api.bravesoftware.com',
    this.exaApiKey,
    this.exaBaseUrl = 'https://api.exa.ai',
    this.firecrawlApiKey,
    this.firecrawlBaseUrl = 'https://api.firecrawl.dev',
    this.maxResults = 8,
    this.fetchTop = 3,
    this.fetchMaxChars = 2500,
    this.providerOrder = const [
      'searxng',
      'tavily',
      'ddgs',
      'brave',
      'exa',
      'firecrawl',
    ],
    http.Client? client,
    SsrfGuard? ssrf,
  }) : _client = client,
       _ssrf = ssrf ?? SsrfGuard();

  final String searxngBaseUrl;

  /// Tavily API key (`tvly-...`). Null/empty berarti provider nonaktif.
  final String? tavilyApiKey;
  final String tavilyBaseUrl;

  /// DDGS (DuckDuckGo Search) - gratis, tanpa API key
  final bool ddgsEnabled;

  /// Brave Search API key. Null/empty berarti provider nonaktif.
  final String? braveApiKey;
  final String braveBaseUrl;

  /// Exa Search API key. Null/empty berarti provider nonaktif.
  final String? exaApiKey;
  final String exaBaseUrl;

  /// Firecrawl API key. Null/empty berarti provider nonaktif.
  final String? firecrawlApiKey;
  final String firecrawlBaseUrl;

  final int maxResults;
  final int fetchTop;
  final int fetchMaxChars;

  /// Urutan pencobaan provider (fallback chain)
  final List<String> providerOrder;

  final http.Client? _client;
  final SsrfGuard _ssrf;

  /// Simple TTL citation cache: url → (expires, snippet)
  static final _cache = <String, ({DateTime exp, String text})>{};
  static const cacheTtl = Duration(hours: 1);

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'web_search',
    description:
        'Cari di web lewat multiple provider: SearXNG, Tavily, DDGS (DuckDuckGo), '
        'Brave, Exa, Firecrawl. Mengembalikan judul, URL, cuplikan; '
        'opsional mengunduh isi singkat dari N hasil teratas. '
        'Provider aktif bergantung pada konfigurasi dan ketersediaan API key.',
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

    final client = _client ?? io.IOClient(_ssrf.pinnedHttpClient());
    
    // Build list of active providers based on configuration
    final activeProviders = <String>[];
    for (final providerId in providerOrder) {
      switch (providerId) {
        case 'searxng':
          activeProviders.add(providerId);
          break;
        case 'tavily':
          if ((tavilyApiKey ?? '').trim().isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'ddgs':
          if (ddgsEnabled) {
            activeProviders.add(providerId);
          }
          break;
        case 'brave':
          if ((braveApiKey ?? '').trim().isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'exa':
          if ((exaApiKey ?? '').trim().isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'firecrawl':
          if ((firecrawlApiKey ?? '').trim().isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
      }
    }

    if (activeProviders.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada provider pencarian yang aktif. '
            'Konfigurasi setidaknya satu provider.',
        isError: true,
      );
    }

    try {
      final (hits, engine) = await _acquireHits(
        client,
        query,
        categories,
        activeProviders,
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
            // Manual redirect handling: re-check every hop (B-07).
            var current = url;
            http.Response? page;
            var blocked = false;
            for (var hop = 0; hop <= _ssrf.maxRedirects; hop++) {
              final blockHop = await _ssrf.checkUrl(current);
              if (blockHop != null) {
                pageBlocks.add(
                  '[${c['n']}] ${c['title']}\n(SSRF blocked on redirect: $blockHop)',
                );
                blocked = true;
                break;
              }
              page = await client
                  .get(Uri.parse(current),
                      headers: {'User-Agent': 'agent_dart/0.1'})
                  .timeout(const Duration(seconds: 12));
              if (page.statusCode >= 300 && page.statusCode < 400) {
                final loc = page.headers['location'];
                if (loc == null) break;
                current = Uri.parse(current).resolve(loc).toString();
                page = null;
                continue;
              }
              break;
            }
            if (blocked || page == null) {
              if (!blocked) {
                pageBlocks.add('[${c['n']}] ${c['title']}\n(tidak ada respons)');
              }
              continue;
            }
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
    List<String> activeProviders,
  ) async {
    final errors = <String>[];
    
    for (final providerId in activeProviders) {
      try {
        final hits = await _searchWithProvider(
          client,
          query,
          categories,
          providerId,
        );
        return (hits, providerId);
      } on _SearchFailure catch (e) {
        errors.add('[$providerId] ${e.message}');
        // Continue to next provider in fallback chain
        continue;
      }
    }
    
    // All providers failed
    throw _SearchFailure(
      'Semua provider gagal:\n${errors.join('\\n')}',
      fallbackEligible: false,
    );
  }

  Future<List<({String title, String url, String content})>> _searchWithProvider(
    http.Client client,
    String query,
    String categories,
    String providerId,
  ) async {
    switch (providerId) {
      case 'searxng':
        return _searchSearxng(client, query, categories);
      case 'tavily':
        return _searchTavily(client, query, categories, tavilyApiKey!);
      case 'ddgs':
        return _searchDDGS(client, query);
      case 'brave':
        return _searchBrave(client, query);
      case 'exa':
        return _searchExa(client, query);
      case 'firecrawl':
        return _searchFirecrawl(client, query);
      default:
        throw _SearchFailure('Provider $providerId tidak dikenal', fallbackEligible: false);
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

  Future<List<({String title, String url, String content})>> _searchDDGS(
    http.Client client,
    String query,
  ) async {
    // DDGS (DuckDuckGo Search) - no API key required
    // Uses ddgs Python package API endpoint
    final uri = Uri.parse('https://api.duckduckgo.com/');
    final http.Response res;
    try {
      res = await client
          .get(
            uri.replace(
              queryParameters: {
                'q': query,
                'format': 'json',
                'no_redirect': '1',
                'no_html': '1',
              },
            ),
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'agent_dart/0.1',
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _SearchFailure(
        'DDGS error: $e',
        fallbackEligible: true,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'DDGS HTTP ${res.statusCode}',
        fallbackEligible: res.statusCode >= 500,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return _hitsFromDDGS(json);
  }

  Future<List<({String title, String url, String content})>> _searchBrave(
    http.Client client,
    String query,
  ) async {
    // Brave Search API
    final braveCheck = await _ssrf.checkUrl(braveBaseUrl);
    if (braveCheck != null) {
      throw _SearchFailure(
        'Brave base URL ditolak: $braveCheck',
        fallbackEligible: false,
      );
    }
    final uri = Uri.parse('$braveBaseUrl/api/v1/search/web');
    final http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${braveApiKey!}',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'count': maxResults,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _SearchFailure(
        'Brave error: $e',
        fallbackEligible: true,
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw _SearchFailure(
        'Brave auth ditolak (HTTP ${res.statusCode}) - periksa API key',
        fallbackEligible: false,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'Brave HTTP ${res.statusCode}',
        fallbackEligible: false,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return _hitsFrom(json);
  }

  Future<List<({String title, String url, String content})>> _searchExa(
    http.Client client,
    String query,
  ) async {
    // Exa Search API
    final exaCheck = await _ssrf.checkUrl(exaBaseUrl);
    if (exaCheck != null) {
      throw _SearchFailure(
        'Exa base URL ditolak: $exaCheck',
        fallbackEligible: false,
      );
    }
    final uri = Uri.parse('$exaBaseUrl/search');
    final http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${exaApiKey!}',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'numResults': maxResults,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _SearchFailure(
        'Exa error: $e',
        fallbackEligible: true,
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw _SearchFailure(
        'Exa auth ditolak (HTTP ${res.statusCode}) - periksa API key',
        fallbackEligible: false,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'Exa HTTP ${res.statusCode}',
        fallbackEligible: false,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return _hitsFrom(json);
  }

  Future<List<({String title, String url, String content})>> _searchFirecrawl(
    http.Client client,
    String query,
  ) async {
    // Firecrawl Search API
    final firecrawlCheck = await _ssrf.checkUrl(firecrawlBaseUrl);
    if (firecrawlCheck != null) {
      throw _SearchFailure(
        'Firecrawl base URL ditolak: $firecrawlCheck',
        fallbackEligible: false,
      );
    }
    final uri = Uri.parse('$firecrawlBaseUrl/v1/search');
    final http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${firecrawlApiKey!}',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'limit': maxResults,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _SearchFailure(
        'Firecrawl error: $e',
        fallbackEligible: true,
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw _SearchFailure(
        'Firecrawl auth ditolak (HTTP ${res.statusCode}) - periksa API key',
        fallbackEligible: false,
      );
    }
    if (res.statusCode >= 400) {
      throw _SearchFailure(
        'Firecrawl HTTP ${res.statusCode}',
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

  static List<({String title, String url, String content})> _hitsFromDDGS(
    Map<String, dynamic> json,
  ) {
    // DDGS (DuckDuckGo) API response format
    // Results are in 'RelatedTopics' array
    final results = json['RelatedTopics'] as List<dynamic>? ?? [];
    final hits = <({String title, String url, String content})>[];
    for (final raw in results) {
      if (raw is! Map<String, dynamic>) continue;
      final title = (raw['Text'] as String?) ?? (raw['Name'] as String?) ?? '(tanpa judul)';
      // Handle nested Icon.URL safely
      final icon = raw['Icon'] as Map<String, dynamic>?;
      final iconUrl = icon?['URL'] as String?;
      final url = (raw['FirstURL'] as String?) ?? iconUrl ?? '';
      final content = (raw['Text'] as String?) ?? '';
      if (url.isNotEmpty) {
        hits.add((title: title, url: url, content: content));
      }
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
