import 'dart:convert';

import 'package:http/http.dart' as http;

/// Sumber token OAuth untuk klien MCP HTTP.
///
/// Kontrak minimal yang dipakai [HttpMcpClient]: minta bearer token dan
/// invalidasi setelah 401. Implementasi yang tersedia:
/// - [McpOAuthClientCredentials]: grant `client_credentials` (machine-to-machine).
/// - [McpOAuthAuthorizationCode]: grant `authorization_code` + PKCE (login
///   browser, kompatibel dengan penyedia OAuth umum seperti GitHub/Notion/Google).
abstract class McpOAuthTokenSource {
  /// Returns a valid bearer token, fetching/refreshing when needed.
  Future<String> token();

  /// Drops the cached token so the next [token] call refreshes it.
  void invalidate();
}

/// OAuth 2.0 client-credentials configuration for an MCP HTTP server.
///
/// Only the `client_credentials` grant is supported here: this mode is for
/// machine-to-machine endpoints. For OAuth providers that require an end-user
/// browser login (GitHub, Notion, Google, dan lainnya), gunakan
/// [McpOAuthAuthorizationCode]. The client secret must come from a
/// SecretRef (`env:VAR`) resolved by the runtime — never hard-coded.
class McpOAuthConfig {
  McpOAuthConfig({
    required this.tokenUrl,
    required this.clientId,
    required this.clientSecret,
    this.scopes = const [],
  }) {
    final uri = Uri.tryParse(tokenUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\x7F]').hasMatch(tokenUrl)) {
      throw ArgumentError.value(
        tokenUrl,
        'tokenUrl',
        'Expected a safe HTTP(S) token URL',
      );
    }
    if (clientId.isEmpty || clientId.length > 128) {
      throw ArgumentError.value(clientId, 'clientId', 'Expected 1-128 chars');
    }
    if (clientSecret.isEmpty || clientSecret.length > 2048) {
      throw ArgumentError.value(
        clientSecret,
        'clientSecret',
        'Expected 1-2048 chars',
      );
    }
    if (scopes.length > 32 ||
        scopes.any(
          (s) =>
              s.isEmpty ||
              s.length > 128 ||
              RegExp(r'[\x00-\x20\x7F]').hasMatch(s),
        )) {
      throw ArgumentError.value(
        scopes,
        'scopes',
        'Expected at most 32 safe scope strings',
      );
    }
  }

  final String tokenUrl;
  final String clientId;
  final String clientSecret;
  final List<String> scopes;
}

/// Fetches and caches client-credentials bearer tokens for [McpOAuthConfig].
///
/// Tokens are cached until [expiresAt] (minus a 60s safety margin) and can be
/// force-invalidated after a 401 so the next [token] call refreshes them.
class McpOAuthClientCredentials implements McpOAuthTokenSource {
  McpOAuthClientCredentials(
    this.config, {
    http.Client? client,
    DateTime Function()? clock,
  }) : _ownedClient = client,
       _clock = clock ?? DateTime.now;

  final McpOAuthConfig config;
  final http.Client? _ownedClient;
  final DateTime Function() _clock;

  String? _cachedToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String>? _fetchingToken;

  /// Diagnostics: how many token endpoint fetches were performed.
  int fetchCount = 0;

  bool get _hasFreshToken =>
      _cachedToken != null && _clock().isBefore(_expiresAt);

  @override
  Future<String> token() async {
    if (_hasFreshToken) return _cachedToken!;
    final pending = _fetchingToken;
    if (pending != null) return pending;
    final fetch = _fetchToken();
    _fetchingToken = fetch;
    try {
      return await fetch;
    } finally {
      if (identical(_fetchingToken, fetch)) _fetchingToken = null;
    }
  }

  Future<String> _fetchToken() async {
    fetchCount += 1;
    final form = <String, String>{
      'grant_type': 'client_credentials',
      if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
    };
    final basic = base64Encode(
      utf8.encode('${config.clientId}:${config.clientSecret}'),
    );
    final client = _ownedClient ?? http.Client();
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse(config.tokenUrl),
            headers: {
              'Authorization': 'Basic $basic',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: form,
          )
          .timeout(const Duration(seconds: 15));
    } finally {
      if (_ownedClient == null) client.close();
    }
    if (res.statusCode != 200) {
      throw StateError('MCP OAuth token endpoint HTTP ${res.statusCode}');
    }
    final map = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (map is! Map<String, dynamic> ||
        map['access_token'] is! String ||
        (map['access_token'] as String).isEmpty) {
      throw const FormatException(
        'MCP OAuth: token response missing access_token',
      );
    }
    _cachedToken = map['access_token'] as String;
    final expiresIn = map['expires_in'];
    final seconds = expiresIn is int && expiresIn > 60 ? expiresIn : 300;
    _expiresAt = _clock().add(Duration(seconds: seconds - 60));
    return _cachedToken!;
  }

  @override
  void invalidate() {
    _cachedToken = null;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
