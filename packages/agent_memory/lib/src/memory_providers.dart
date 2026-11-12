import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// External memory provider adapters (Hermes-style memory providers).
///
/// [HttpMemoryProvider] speaks a small REST contract against external
/// backends (RetainDB/ByteRover/Mem0-style services or self-hosted
/// stores):
/// - `POST {upsertPath}`  body: MemoryRecord JSON → 2xx
/// - `POST {searchPath}`  body: `{query, k, owner_key}` →
///   `{"records": [MemoryRecord...]}`
/// - `DELETE {deletePath}/{id}` → 2xx
///
/// [MemoryProviderRouter] fans writes out to every provider and merges
/// reads, so the built-in store and external backends behave as one
/// memory. Provider failures degrade retrieval instead of crashing.

class HttpMemoryProviderConfig {
  const HttpMemoryProviderConfig({
    required this.baseUrl,
    this.apiKey,
    this.upsertPath = '/memories',
    this.searchPath = '/memories/search',
    this.deletePath = '/memories',
    this.timeout = const Duration(seconds: 10),
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 200),
  });

  final String baseUrl;
  final String? apiKey;
  final String upsertPath;
  final String searchPath;
  final String deletePath;
  final Duration timeout;
  final int maxRetries;
  final Duration retryDelay;
}

/// REST adapter implementing [MemoryProvider] over `dart:io HttpClient`
/// (no extra dependency). Retries transient failures with a fixed delay.
class HttpMemoryProvider implements MemoryProvider {
  HttpMemoryProvider({
    required this.config,
    String? name,
    HttpClient? client,
  })  : name = name ?? 'http:${Uri.parse(config.baseUrl).host}',
        _client = client ?? HttpClient();

  @override
  final String name;
  final HttpMemoryProviderConfig config;
  final HttpClient _client;

  @override
  Future<void> upsert(MemoryRecord record) => _sendWithRetry(() async {
        final req = await _client
            .postUrl(Uri.parse('${config.baseUrl}${config.upsertPath}'))
          ..headers.contentType = ContentType.json
          .._applyAuth(config.apiKey)
          ..write(jsonEncode(record.toJson()));
        final res = await req.close().timeout(config.timeout);
        await _drain(res);
        if (res.statusCode >= 400) {
          throw HttpException('upsert failed: HTTP ${res.statusCode}');
        }
      });

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    List<MemoryRecord> last = const [];
    await _sendWithRetry(() async {
      final req = await _client
          .postUrl(Uri.parse('${config.baseUrl}${config.searchPath}'))
        ..headers.contentType = ContentType.json
        .._applyAuth(config.apiKey)
        ..write(jsonEncode({
          'query': query,
          'k': k,
          if (ownerKey != null) 'owner_key': ownerKey,
        }));
      final res = await req.close().timeout(config.timeout);
      final body = await _drain(res);
      if (res.statusCode >= 400) {
        throw HttpException('search failed: HTTP ${res.statusCode}');
      }
      final json = jsonDecode(body);
      final records = json is Map && json['records'] is List
          ? json['records'] as List
          : const [];
      last = [
        for (final raw in records)
          if (raw is Map<String, dynamic>) MemoryRecord.fromJson(raw),
      ];
    });
    return last;
  }

  @override
  Future<void> forget(String id) => _sendWithRetry(() async {
        final req = await _client.deleteUrl(
            Uri.parse('${config.baseUrl}${config.deletePath}/$id'))
          .._applyAuth(config.apiKey);
        final res = await req.close().timeout(config.timeout);
        await _drain(res);
        if (res.statusCode >= 400) {
          throw HttpException('forget failed: HTTP ${res.statusCode}');
        }
      });

  Future<void> _sendWithRetry(Future<void> Function() fn) async {
    var attempt = 0;
    while (true) {
      try {
        await fn();
        return;
      } catch (e) {
        attempt++;
        if (attempt > config.maxRetries) rethrow;
        await Future<void>.delayed(config.retryDelay * attempt);
      }
    }
  }

  Future<void> close() async => _client.close(force: true);
}

extension _AuthRequest on HttpClientRequest {
  void _applyAuth(String? apiKey) {
    if (apiKey != null && apiKey.isNotEmpty) {
      headers.set('Authorization', 'Bearer $apiKey');
    }
  }
}

Future<String> _drain(HttpClientResponse res) =>
    res.transform(utf8.decoder).join();

/// Merge policy for [MemoryProviderRouter] reads.
enum MemoryMergePolicy {
  /// Concatenate provider results, best-scored first.
  interleave,

  /// Only use external providers when the local store returns fewer
  /// than [MemoryProviderRouter.localFallbackThreshold] hits.
  fallback,
}

/// Routes memory operations across the built-in store and any number of
/// external [MemoryProvider]s. Writes fan out; reads merge with per-
/// provider weights and dedupe by (ownerKey, text).
class MemoryProviderRouter implements MemoryProvider {
  MemoryProviderRouter({
    required this.local,
    this.external = const [],
    this.mergePolicy = MemoryMergePolicy.interleave,
    this.localFallbackThreshold = 3,
    this.weights = const {},
  });

  /// The built-in store adapter (e.g. wraps `LayeredMemory`).
  final MemoryProvider local;
  final List<MemoryProvider> external;
  final MemoryMergePolicy mergePolicy;
  final int localFallbackThreshold;

  /// Optional per-provider score multipliers keyed by provider name.
  final Map<String, double> weights;

  @override
  String get name => 'router';

  @override
  Future<void> upsert(MemoryRecord record) async {
    Object? localError;
    try {
      await local.upsert(record);
    } catch (e) {
      localError = e;
    }
    var externalOk = 0;
    for (final provider in external) {
      try {
        await provider.upsert(record);
        externalOk++;
      } catch (_) {}
    }
    if (localError != null && (external.isEmpty || externalOk == 0)) {
      throw localError;
    }
  }

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    final localHits = await _safeSearch(local, query, k: k, ownerKey: ownerKey);
    if (mergePolicy == MemoryMergePolicy.fallback &&
        localHits.length >= localFallbackThreshold) {
      return localHits.take(k).toList();
    }
    final externalHits = <MemoryRecord>[];
    for (final provider in external) {
      final weight = weights[provider.name] ?? 1.0;
      for (final record
          in await _safeSearch(provider, query, k: k, ownerKey: ownerKey)) {
        externalHits.add(MemoryRecord(
          id: record.id,
          text: record.text,
          score: record.score * weight,
          ownerKey: record.ownerKey,
          tags: record.tags,
          createdAt: record.createdAt,
        ));
      }
    }
    return _merge(localHits, externalHits, k);
  }

  @override
  Future<void> forget(String id) async {
    await _forEachProvider((provider) => provider.forget(id));
  }

  Future<void> _forEachProvider(Future<void> Function(MemoryProvider) fn) =>
      Future.wait([
        () async {
          try {
            await fn(local);
          } catch (_) {}
        }(),
        for (final provider in external)
          () async {
            try {
              await fn(provider);
            } catch (_) {}
          }(),
      ]);

  Future<List<MemoryRecord>> _safeSearch(
    MemoryProvider provider,
    String query, {
    required int k,
    String? ownerKey,
  }) async {
    try {
      return await provider.search(query, k: k, ownerKey: ownerKey);
    } catch (_) {
      return const [];
    }
  }

  List<MemoryRecord> _merge(
    List<MemoryRecord> localHits,
    List<MemoryRecord> externalHits,
    int k,
  ) {
    final seen = <String, MemoryRecord>{};
    for (final record in localHits) {
      seen[_key(record)] = record;
    }
    for (final record in externalHits) {
      final key = _key(record);
      final existing = seen[key];
      if (existing == null) {
        seen[key] = record;
      } else if (record.score > existing.score) {
        seen[key] = record;
      }
    }
    final merged = seen.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.id.compareTo(b.id);
      });
    return merged.take(k).toList();
  }

  static String _key(MemoryRecord r) => '${r.ownerKey ?? ''}:${r.text}';
}

