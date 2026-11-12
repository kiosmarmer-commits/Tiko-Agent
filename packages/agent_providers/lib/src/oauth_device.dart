import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Generic OAuth2 Device Authorization Grant (RFC 8628) for providers whose
/// login flow is device-code based (Hermes-parity: qwen-oauth, xai-oauth,
/// minimax-oauth, nous portal, …). Tokens are cached on disk and refreshed
/// with the refresh token; the flow itself is only run when no valid token
/// exists.
class OAuthDeviceConfig {
  const OAuthDeviceConfig({
    required this.clientId,
    required this.deviceAuthUrl,
    required this.tokenUrl,
    this.scopes = const [],
    this.tokenCachePath,
  });

  final String clientId;
  final String deviceAuthUrl;
  final String tokenUrl;
  final List<String> scopes;

  /// JSON cache file for the token; when null tokens live in memory only.
  final String? tokenCachePath;
}

class OAuthDeviceFlow {
  OAuthDeviceFlow(this.config, {http.Client? client, DateTime Function()? now})
      : _client = client,
        _now = now ?? _defaultNow;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  final OAuthDeviceConfig config;
  final http.Client? _client;
  final DateTime Function() _now;

  Map<String, dynamic>? _memoryToken;

  /// Returns a valid access token, refreshing or running the device flow
  /// when needed. Throws [OAuthDeviceException] on unrecoverable failures.
  Future<String> getAccessToken() async {
    final cached = await _load();
    if (cached != null) {
      final expiresAt = (cached['expires_at'] as num?)?.toInt() ?? 0;
      final expired = expiresAt <= _now().millisecondsSinceEpoch + 30000;
      if (!expired) return cached['access_token'] as String;
      final refresh = cached['refresh_token'] as String?;
      if (refresh != null) {
        try {
          final refreshed = await _tokenRequest({
            'grant_type': 'refresh_token',
            'refresh_token': refresh,
            'client_id': config.clientId,
          });
          return refreshed['access_token'] as String;
        } on OAuthDeviceException {
          // fall through to a fresh device flow
        }
      }
    }
    final fresh = await _runDeviceFlow();
    return fresh['access_token'] as String;
  }

  Future<Map<String, dynamic>?> _load() async {
    if (_memoryToken != null) return _memoryToken;
    final path = config.tokenCachePath;
    if (path == null) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      _memoryToken = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return _memoryToken;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(Map<String, dynamic> token) async {
    _memoryToken = token;
    final path = config.tokenCachePath;
    if (path == null) return;
    try {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(token));
    } catch (_) {
      // cache is best-effort
    }
  }

  Future<Map<String, dynamic>> _runDeviceFlow() async {
    final client = _client ?? http.Client();
    try {
      final deviceRes = await client.post(
        Uri.parse(config.deviceAuthUrl),
        body: {
          'client_id': config.clientId,
          if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
        },
      );
      if (deviceRes.statusCode >= 400) {
        throw OAuthDeviceException(
          'device authorization gagal: HTTP ${deviceRes.statusCode}',
        );
      }
      final device = jsonDecode(deviceRes.body) as Map<String, dynamic>;
      final deviceCode = device['device_code'] as String?;
      if (deviceCode == null || deviceCode.isEmpty) {
        throw OAuthDeviceException('device_code tidak ada di respons server');
      }
      final interval = ((device['interval'] as num?)?.toInt() ?? 5)
          .clamp(0, 60);
      final expiresAt =
          _now().millisecondsSinceEpoch +
              ((device['expires_in'] as num?)?.toInt() ?? 600) * 1000;

      var slowDownExtra = 0;
      while (_now().millisecondsSinceEpoch < expiresAt) {
        await Future<void>.delayed(Duration(seconds: interval + slowDownExtra));
        try {
          final token = await _tokenRequest({
            'grant_type':
                'urn:ietf:params:oauth:grant-type:device_code',
            'device_code': deviceCode,
            'client_id': config.clientId,
          });
          await _save(_withExpiry(token));
          return _withExpiry(token);
        } on OAuthPendingException {
          continue;
        } on OAuthSlowDownException {
          slowDownExtra += 5;
          continue;
        }
      }
      throw OAuthDeviceException('device flow kedaluwarsa sebelum disetujui');
    } finally {
      if (_client == null) client.close();
    }
  }

  Map<String, dynamic> _withExpiry(Map<String, dynamic> token) => {
        ...token,
        'expires_at': _now().millisecondsSinceEpoch +
            ((token['expires_in'] as num?)?.toInt() ?? 3600) * 1000,
      };

  Future<Map<String, dynamic>> _tokenRequest(
    Map<String, String> form,
  ) async {
    final client = _client ?? http.Client();
    try {
      final res = await client.post(Uri.parse(config.tokenUrl), body: form);
      if (res.statusCode >= 400) {
        throw OAuthDeviceException(
          'token request gagal: HTTP ${res.statusCode}',
        );
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final error = json['error'] as String?;
      if (error != null) {
        if (error == 'authorization_pending') throw OAuthPendingException();
        if (error == 'slow_down') throw OAuthSlowDownException();
        if (error == 'expired_token') {
          throw OAuthDeviceException('device_code kedaluwarsa');
        }
        throw OAuthDeviceException('token request ditolak: $error');
      }
      final access = json['access_token'] as String?;
      if (access == null || access.isEmpty) {
        throw OAuthDeviceException('access_token tidak ada di respons server');
      }
      return json;
    } finally {
      if (_client == null) client.close();
    }
  }
}

class OAuthDeviceException implements Exception {
  OAuthDeviceException(this.message);
  final String message;

  @override
  String toString() => 'OAuthDeviceException: $message';
}

class OAuthPendingException extends OAuthDeviceException {
  OAuthPendingException() : super('authorization_pending');
}

class OAuthSlowDownException extends OAuthDeviceException {
  OAuthSlowDownException() : super('slow_down');
}
