import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cdp_browser.dart';

/// A session created by a cloud browser backend.
class CloudBrowserSession {
  const CloudBrowserSession({
    required this.id,
    required this.cdpUrl,
    this.viewUrl,
  });

  final String id;
  final String cdpUrl;
  final String? viewUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'cdpUrl': cdpUrl,
        if (viewUrl != null) 'viewUrl': viewUrl,
      };
}

/// Contract for cloud browser providers (Browserbase, Browser Use, ...).
abstract class CloudBrowserBackend {
  String get id;

  Future<CloudBrowserSession> createSession();

  Future<void> closeSession(String id);
}

/// Browserbase cloud browser (https://browserbase.com).
///
/// REST v1: `POST /v1/sessions` returns a session whose `connectUrl` is a CDP
/// WebSocket endpoint; `POST /v1/sessions/{id}` stops it.
class BrowserbaseBackend implements CloudBrowserBackend {
  BrowserbaseBackend({
    http.Client? client,
    required this.apiKey,
    this.projectId,
    this.baseUrl = 'https://api.browserbase.com',
    this.region,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String? projectId;
  final String baseUrl;
  final String? region;
  final Duration timeout;

  @override
  String get id => 'browserbase';

  @override
  Future<CloudBrowserSession> createSession() async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/sessions'),
          headers: {
            'x-api-key': apiKey,
            'content-type': 'application/json',
          },
          body: jsonEncode({
            if (projectId != null) 'projectId': projectId,
            if (region != null) 'region': region,
          }),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BrowserBackendException(
        'Browserbase createSession gagal: HTTP ${res.statusCode} ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final id = body['id']?.toString();
    final cdpUrl = (body['connectUrl'] ?? body['connection_url'])?.toString();
    if (id == null || cdpUrl == null || cdpUrl.isEmpty) {
      throw BrowserBackendException(
        'Respons Browserbase tidak berisi id/connectUrl',
      );
    }
    return CloudBrowserSession(
      id: id,
      cdpUrl: cdpUrl,
      viewUrl: body['debugUrl']?.toString(),
    );
  }

  @override
  Future<void> closeSession(String id) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/sessions/$id'),
          headers: {'x-api-key': apiKey},
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BrowserBackendException(
        'Browserbase closeSession gagal: HTTP ${res.statusCode}',
      );
    }
  }
}

/// Browser Use cloud browser (https://browser-use.com).
///
/// REST: `POST /api/v1/sessions` with a Bearer token; the response exposes
/// `cdp_url` (or `connect_url`) and `id`.
class BrowserUseBackend implements CloudBrowserBackend {
  BrowserUseBackend({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://api.browser-use.com',
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get id => 'browser-use';

  @override
  Future<CloudBrowserSession> createSession() async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/sessions'),
          headers: {
            'authorization': 'Bearer $apiKey',
            'content-type': 'application/json',
          },
          body: jsonEncode(const {}),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BrowserBackendException(
        'BrowserUse createSession gagal: HTTP ${res.statusCode} ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final id = body['id']?.toString();
    final cdpUrl =
        (body['cdpUrl'] ?? body['cdp_url'] ?? body['connectUrl'])?.toString();
    if (id == null || cdpUrl == null || cdpUrl.isEmpty) {
      throw BrowserBackendException(
        'Respons Browser Use tidak berisi id/cdp_url',
      );
    }
    return CloudBrowserSession(
      id: id,
      cdpUrl: cdpUrl,
      viewUrl: body['viewUrl']?.toString() ?? body['live_url']?.toString(),
    );
  }

  @override
  Future<void> closeSession(String id) async {
    final res = await _client
        .delete(
          Uri.parse('$baseUrl/api/v1/sessions/$id'),
          headers: {'authorization': 'Bearer $apiKey'},
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 400) {
      throw BrowserBackendException(
        'BrowserUse closeSession gagal: HTTP ${res.statusCode}',
      );
    }
  }
}

/// Error raised by cloud browser backends.
class BrowserBackendException implements Exception {
  BrowserBackendException(this.message);

  final String message;

  @override
  String toString() => 'BrowserBackendException: $message';
}

/// A live browser acquired from [CloudBrowserRouter].
class CloudBrowserHandle {
  CloudBrowserHandle._({
    required this.session,
    required this.router,
    this.backendId,
    this.backendSessionId,
  });

  /// The CDP session. For cloud backends it is attached to the remote
  /// endpoint; for the local fallback it owns a launched Chromium process.
  final CdpSession session;

  /// Router that produced this handle.
  final CloudBrowserRouter router;

  /// Backend id, or null when served by the local fallback.
  final String? backendId;
  final String? backendSessionId;

  bool _released = false;

  /// Releases the handle: closes the CDP session and, when remote, tears the
  /// cloud session down.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await session.close();
    } finally {
      final backendSessionId = this.backendSessionId;
      if (backendId != null && backendSessionId != null) {
        try {
          await router._backend(backendId).closeSession(backendSessionId);
        } catch (_) {}
      }
    }
  }
}

/// Routes browser sessions across cloud backends with a local CDP fallback.
///
/// Backends are tried in priority order; the first that successfully yields a
/// working CDP connection wins. When every cloud backend fails (or the list is
/// empty) the router falls back to launching a local Chromium, mirroring
/// Hermes Agent's local/cloud browser duality.
class CloudBrowserRouter {
  CloudBrowserRouter({
    required List<CloudBrowserBackend> backends,
    this.localFallback = true,
    this.chromePath,
    this.headless = true,
    this.allowPrivateUrls = false,
  }) : _backends = List.of(backends);

  final List<CloudBrowserBackend> _backends;
  final bool localFallback;
  final String? chromePath;
  final bool headless;
  final bool allowPrivateUrls;

  /// Read-only view of the configured backends in priority order.
  List<CloudBrowserBackend> get backends => List.unmodifiable(_backends);

  CloudBrowserBackend _backend(String id) => _backends.firstWhere(
        (b) => b.id == id,
        orElse: () => throw BrowserBackendException(
          'Backend tidak dikenal: $id',
        ),
      );

  /// Acquires a ready CDP session, trying cloud backends first.
  Future<CloudBrowserHandle> acquire() async {
    final errors = <String>[];
    for (final backend in _backends) {
      try {
        final cloud = await backend.createSession();
        final session = CdpSession(
          wsEndpoint: cloud.cdpUrl,
          chromePath: chromePath,
          allowPrivateUrls: allowPrivateUrls,
        );
        try {
          await session.open();
        } catch (e) {
          await session.close();
          try {
            await backend.closeSession(cloud.id);
          } catch (_) {}
          errors.add('${backend.id}: open gagal ($e)');
          continue;
        }
        return CloudBrowserHandle._(
          session: session,
          router: this,
          backendId: backend.id,
          backendSessionId: cloud.id,
        );
      } catch (e) {
        errors.add('${backend.id}: $e');
      }
    }
    if (!localFallback) {
      throw BrowserBackendException(
        'Semua cloud browser backend gagal: ${errors.join('; ')}',
      );
    }
    final local = CdpSession(
      chromePath: chromePath,
      headless: headless,
      allowPrivateUrls: allowPrivateUrls,
    );
    await local.open();
    return CloudBrowserHandle._(session: local, router: this);
  }
}
