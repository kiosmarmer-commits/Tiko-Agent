import 'dart:convert';
import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

/// Hasil pencarian web
class SearchResult {
  final String title;
  final String url;
  final String snippet;
  final String? content;

  SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.content,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        if (content != null) 'content': content,
      };
}

/// Antarmuka provider pencarian web
abstract class WebSearchProvider {
  String get name;
  Future<List<SearchResult>> search(String query, {int limit = 5});
}

/// 1. Firecrawl Provider (Default, berbayar/keyless ring)
class FirecrawlProvider implements WebSearchProvider {
  @override
  String get name => 'firecrawl';
  final String? apiKey;
  final String baseUrl;

  FirecrawlProvider({this.apiKey, this.baseUrl = 'https://api.firecrawl.dev'});

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final client = http.Client();
    try {
      final headers = {
        'Content-Type': 'application/json',
        if (apiKey != null) 'Authorization': 'Bearer $apiKey',
      };
      final response = await client.post(
        Uri.parse('$baseUrl/v1/search'),
        headers: headers,
        body: jsonEncode({'query': query, 'limit': limit, 'scrapeOptions': {'formats': ['markdown']}}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['data'] as List<dynamic>? ?? [];
        return results.take(limit).map((r) {
          final map = r as Map<String, dynamic>;
          return SearchResult(
            title: map['title'] as String? ?? '',
            url: map['url'] as String? ?? '',
            snippet: map['description'] as String? ?? '',
            content: map['markdown'] as String?,
          );
        }).toList();
      }
      throw Exception('Firecrawl search failed: ${response.statusCode} ${response.body}');
    } finally {
      client.close();
    }
  }
}

/// 2. SearXNG Provider (Self-hosted, gratis)
class SearXNGProvider implements WebSearchProvider {
  @override
  String get name => 'searxng';
  final String baseUrl;

  SearXNGProvider({required this.baseUrl});

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$baseUrl/search').replace(queryParameters: {
        'q': query,
        'format': 'json',
        'categories': 'general',
        'pageno': '1',
      });
      final response = await client.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>? ?? [];
        return results.take(limit).map((r) {
          final map = r as Map<String, dynamic>;
          return SearchResult(
            title: map['title'] as String? ?? '',
            url: map['url'] as String? ?? '',
            snippet: map['content'] as String? ?? '',
          );
        }).toList();
      }
      throw Exception('SearXNG search failed: ${response.statusCode}');
    } finally {
      client.close();
    }
  }
}

/// 3. Brave Search Provider (Gratis 2000/bln, atau berbayar)
class BraveSearchProvider implements WebSearchProvider {
  @override
  String get name => 'brave';
  final String? apiKey;

  BraveSearchProvider({this.apiKey});

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final client = http.Client();
    try {
      final headers = {
        'Accept': 'application/json',
        if (apiKey != null) 'X-Subscription-Token': apiKey!,
      };
      final uri = Uri.parse('https://api.search.brave.com/res/v1/web/search').replace(queryParameters: {
        'q': query,
        'count': limit.toString(),
        'search_lang': 'en',
      });
      final response = await client.get(uri, headers: headers);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final webResults = data['web']?['results'] as List<dynamic>? ?? [];
        return webResults.take(limit).map((r) {
          final map = r as Map<String, dynamic>;
          return SearchResult(
            title: map['title'] as String? ?? '',
            url: map['url'] as String? ?? '',
            snippet: map['description'] as String? ?? '',
          );
        }).toList();
      }
      throw Exception('Brave search failed: ${response.statusCode} ${response.body}');
    } finally {
      client.close();
    }
  }
}

/// 4. DuckDuckGo Provider (Gratis, keyless, via HTML scraping)
class DDGProvider implements WebSearchProvider {
  @override
  String get name => 'ddg';

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://html.duckduckgo.com/html').replace(queryParameters: {'q': query});
      final response = await client.get(
        uri,
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
      );
      if (response.statusCode == 200) {
        final document = html_parser.parse(response.body);
        final results = <SearchResult>[];
        for (final element in document.querySelectorAll('.result')) {
          if (results.length >= limit) break;
          final titleEl = element.querySelector('.result__title a');
          final snippetEl = element.querySelector('.result__snippet');
          if (titleEl != null && snippetEl != null) {
            results.add(SearchResult(
              title: titleEl.text.trim(),
              url: titleEl.attributes['href'] ?? '',
              snippet: snippetEl.text.trim(),
            ));
          }
        }
        return results;
      }
      throw Exception('DDG search failed: ${response.statusCode}');
    } finally {
      client.close();
    }
  }
}

/// Web Search Tool yang merutekan ke provider yang dikonfigurasi
class WebSearchTool implements Tool {
  final WebSearchProvider provider;

  WebSearchTool({required this.provider});

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'web_search',
        description: 'Cari informasi terkini dari internet. Gunakan untuk pertanyaan faktual, berita, atau data yang tidak ada di memori.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': 'Kata kunci pencarian'},
            'limit': {'type': 'integer', 'description': 'Jumlah hasil maksimal (default 5)', 'default': 5},
          },
          'required': ['query'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final query = args['query'] as String?;
      if (query == null || query.trim().isEmpty) {
        return ToolResult(callId: '', content: 'query wajib diisi', isError: true);
      }
      final limit = (args['limit'] as num?)?.toInt() ?? 5;
      
      final results = await provider.search(query, limit: limit);
      if (results.isEmpty) {
        return ToolResult(callId: '', content: 'Tidak ada hasil ditemukan untuk: $query', isError: false);
      }

      final formatted = results.map((r) {
        final contentPreview = r.content != null && r.content!.length > 500 
            ? '${r.content!.substring(0, 500)}...' 
            : r.content;
        return '- **${r.title}**\n  URL: ${r.url}\n  Snippet: ${r.snippet}${contentPreview != null ? '\n  Content: $contentPreview' : ''}';
      }).join('\n\n');

      return ToolResult(
        callId: '',
        content: 'Hasil pencarian untuk "$query" (via ${provider.name}):\n\n$formatted',
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'Error saat pencarian web: ${e.toString()}',
        isError: true,
      );
    }
  }
}
