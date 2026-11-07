import 'dart:convert';
import 'dart:io';

/// Minimal HTTP client to talk to running agentd (mode daemon/auto).
class TikoRemoteClient {
  TikoRemoteClient({
    required this.baseUrl,
    required this.token,
  });

  final String baseUrl;
  final String token;

  Future<bool> health() async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }


  Future<List<Map<String, dynamic>>> approvals({bool includeHistory = false}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$baseUrl/v1/approvals'));
      req.headers.set('Authorization', 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final items = (json['approvals'] as List<dynamic>? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map));
      return items
          .where((item) => includeHistory || item['state'] == 'pending')
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> decideApproval(String id, {required bool approve}) async {
    final client = HttpClient();
    try {
      final safeId = Uri.encodeComponent(id);
      final req = await client.postUrl(
        Uri.parse('$baseUrl/v1/approvals/$safeId'),
      );
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'approve': approve}));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['ok'] == true;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> shutdown() async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl/v1/shutdown'));
      req.headers.set('Authorization', 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['ok'] == true;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> chat(String text, {String sessionKey = 'cli:remote'}) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl/v1/messages'));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'text': text,
        'session_key': sessionKey,
        'user_key': 'cli',
      }));
      final res = await req.close().timeout(const Duration(seconds: 180));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['text'] as String? ?? body;
    } finally {
      client.close(force: true);
    }
  }
}
