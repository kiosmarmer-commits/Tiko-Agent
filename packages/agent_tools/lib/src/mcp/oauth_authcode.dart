import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'oauth.dart';

/// Exception alur OAuth authorization-code yang gagal dengan sebab jelas.
class McpOAuthFlowException implements Exception {
  const McpOAuthFlowException(this.message, {this.code});

  /// Kode error OAuth (mis. `access_denied`, `invalid_grant`) bila ada.
  final String? code;
  final String message;

  @override
  String toString() =>
      'McpOAuthFlowException(${code ?? 'flow_error'}): $message';
}

/// Konfigurasi alur OAuth 2.0 **authorization code + PKCE** untuk server MCP
/// yang mewajibkan login pengguna lewat browser (GitHub, Notion, Google,
/// Slack, dan penyedia OAuth umum lainnya).
///
/// Kompatibilitas luas dicapai lewat:
/// - Metadata discovery (RFC 9728 -> RFC 8414) ATAU endpoint manual.
/// - Dynamic Client Registration (RFC 7591) bila `client_id` tidak disediakan.
/// - PKCE S256 (RFC 7636) untuk public client; bisa dimatikan.
/// - `auth_method` variatif: `basic`, `post`, `none`, atau `auto`.
/// - Resource Indicator (RFC 8707) dikirim sebagai parameter `resource`.
class McpOAuthAuthorizationCodeConfig {
  McpOAuthAuthorizationCodeConfig({
    required this.serverUrl,
    this.authorizationUrl,
    this.tokenUrl,
    this.registrationUrl,
    this.clientId = '',
    this.clientSecret = '',
    this.scopes = const [],
    this.redirectPort = 0,
    this.authMethod = 'auto',
    this.useDiscovery = true,
    this.usePkce = true,
    this.tokenStorePath,
    this.authorizeTimeout = const Duration(minutes: 5),
  }) {
    _validateUrl(serverUrl, 'serverUrl');
    if (authorizationUrl != null) _validateUrl(authorizationUrl!, 'authorizationUrl');
    if (tokenUrl != null) _validateUrl(tokenUrl!, 'tokenUrl');
    if (registrationUrl != null) _validateUrl(registrationUrl!, 'registrationUrl');
    if (clientId.length > 128) {
      throw ArgumentError.value(clientId, 'clientId', 'Expected 0-128 chars');
    }
    if (clientSecret.length > 2048) {
      throw ArgumentError.value(
          clientSecret, 'clientSecret', 'Expected 0-2048 chars');
    }
    if (scopes.length > 32 ||
        scopes.any((s) =>
            s.isEmpty ||
            s.length > 128 ||
            RegExp(r'[\x00-\x20\x7F]').hasMatch(s))) {
      throw ArgumentError.value(
          scopes, 'scopes', 'Expected at most 32 safe scope strings');
    }
    if (redirectPort < 0 || redirectPort > 65535) {
      throw ArgumentError.value(
          redirectPort, 'redirectPort', 'Expected 0-65535 (0 = ephemeral)');
    }
    if (!const {'auto', 'basic', 'post', 'none'}.contains(authMethod)) {
      throw ArgumentError.value(
          authMethod, 'authMethod', 'Expected auto|basic|post|none');
    }
    if (authorizeTimeout <= Duration.zero) {
      throw ArgumentError.value(
          authorizeTimeout, 'authorizeTimeout', 'Must be positive');
    }
  }

  /// URL dasar server MCP. Dipakai sebagai titik awal discovery (RFC 9728)
  /// dan sebagai Resource Indicator (RFC 8707).
  final String serverUrl;

  /// Endpoint otorisasi manual (melewati discovery bila lengkap).
  final String? authorizationUrl;

  /// Endpoint token manual (melewati discovery bila lengkap).
  final String? tokenUrl;

  /// Endpoint registrasi dinamis manual (RFC 7591), opsional.
  final String? registrationUrl;

  /// Client ID. Kosong berarti coba registrasi dinamis (DCR).
  final String clientId;

  /// Client secret untuk confidential client. Kosong berarti public client.
  final String clientSecret;

  final List<String> scopes;

  /// Port redirect loopback. 0 = pilih port ephemeral (disarankan).
  final int redirectPort;

  /// Cara mengirim kredensial klien di token endpoint:
  /// `auto` (basic bila ada secret, selain itu none), `basic`, `post`, `none`.
  final String authMethod;

  /// Coba metadata discovery (RFC 9728 + RFC 8414) untuk melengkapi endpoint.
  final bool useDiscovery;

  /// Gunakan PKCE (RFC 7636). Default aktif; wajib untuk public client.
  final bool usePkce;

  /// Path file JSON (mode 0600) untuk menyimpan token antar proses.
  /// Null berarti token hanya hidup di memori.
  final String? tokenStorePath;

  /// Batas waktu menunggu redirect browser selesai.
  final Duration authorizeTimeout;

  static void _validateUrl(String url, String param) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\x7F]').hasMatch(url)) {
      throw ArgumentError.value(url, param, 'Expected a safe HTTP(S) URL');
    }
  }
}

/// Sumber token OAuth **authorization code + PKCE** (login browser).
///
/// Mengimplementasikan [McpOAuthTokenSource] sehingga bisa dipakai langsung
/// oleh [HttpMcpClient] dan [EnhancedHttpMcpClient] (field `oauth`).
///
/// Urutan resolusi token di [token]:
/// 1. Cache memori yang masih segar.
/// 2. Token tersimpan di [McpOAuthAuthorizationCodeConfig.tokenStorePath].
/// 3. Grant `refresh_token` bila refresh token tersedia.
/// 4. Alur interaktif: discovery -> (DCR) -> loopback redirect -> PKCE ->
///    tukar code -> simpan token.
///
/// Token disimpan sebagai JSON mode 0600 (pola sama dengan SecretStore),
/// ditulis atomik (tmp + rename). Untuk host yang punya penyimpanan secret
/// lebih aman, sediakan [persistOverride]/[loadOverride].
class McpOAuthAuthorizationCode implements McpOAuthTokenSource {
  McpOAuthAuthorizationCode(
    this.config, {
    http.Client? client,
    DateTime Function()? clock,
    Random? random,
    void Function(Uri authorizeUrl)? onAuthorizeUrl,
    bool openBrowser = true,
    Future<void> Function(Map<String, dynamic> tokens)? persistOverride,
    Future<Map<String, dynamic>?> Function()? loadOverride,
  })  : _ownedClient = client,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure(),
        _onAuthorizeUrl = onAuthorizeUrl,
        _openBrowser = openBrowser,
        _persistOverride = persistOverride,
        _loadOverride = loadOverride;

  final McpOAuthAuthorizationCodeConfig config;
  final http.Client? _ownedClient;
  final DateTime Function() _clock;
  final Random _random;
  final void Function(Uri authorizeUrl)? _onAuthorizeUrl;
  final bool _openBrowser;
  final Future<void> Function(Map<String, dynamic> tokens)? _persistOverride;
  final Future<Map<String, dynamic>?> Function()? _loadOverride;

  String? _cachedToken;
  String? _refreshToken;
  String? _tokenEndpoint;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loaded = false;

  /// Hasil DCR (RFC 7591) bila registrasi dinamis dilakukan.
  Map<String, dynamic>? registration;

  /// Diagnostik: jumlah panggilan token endpoint.
  int fetchCount = 0;

  /// URL otorisasi terakhir yang dibangkitkan (untuk diagnostik/test).
  Uri? lastAuthorizeUrl;

  http.Client get _client => _ownedClient ?? http.Client();

  bool get _hasFreshToken =>
      _cachedToken != null && _clock().isBefore(_expiresAt);

  String get _effectiveClientId =>
      config.clientId.isNotEmpty
          ? config.clientId
          : (registration?['client_id'] as String? ?? '');

  String get _effectiveClientSecret =>
      config.clientSecret.isNotEmpty
          ? config.clientSecret
          : (registration?['client_secret'] as String? ?? '');

  // ---------------------------------------------------------------------------
  // PKCE (RFC 7636)
  // ---------------------------------------------------------------------------

  /// Menghitung challenge S256 dari verifier (base64url tanpa padding).
  static String pkceChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier)).bytes;
    return base64Url.encode(digest).replaceAll('=', '');
  }

  /// Menghasilkan verifier acak 32 byte (43 karakter base64url, memenuhi
  /// syarat panjang RFC 7636 43-128 karakter).
  static String generateVerifier(Random random) {
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _randomState() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ---------------------------------------------------------------------------
  // McpOAuthTokenSource
  // ---------------------------------------------------------------------------

  @override
  Future<String> token() async {
    if (_hasFreshToken) return _cachedToken!;
    await _ensureLoaded();
    if (_hasFreshToken) return _cachedToken!;
    if (_refreshToken != null && _refreshToken!.isNotEmpty) {
      try {
        return await _refreshTokens();
      } on McpOAuthFlowException {
        // Refresh token ditolak (kedaluwarsa/dicabut) -> jatuh ke alur
        // interaktif berikutnya.
        _refreshToken = null;
      }
    }
    return _interactiveAuthorization();
  }

  @override
  void invalidate() {
    // Hanya buang access token; refresh token dipertahankan agar sesi
    // pengguna tidak hilang setelah satu 401.
    _cachedToken = null;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Menyuntikkan redirect otorisasi dari luar (dipakai test atau host yang
  /// punya browser/WebView sendiri). Harus dipanggil saat alur interaktif
  /// sedang menunggu; state tetap divalidasi fail-closed.
  Future<void> completeCallback(Uri redirectUri) async {
    final pending = _pendingRedirect;
    if (pending == null) {
      throw StateError('Tidak ada alur otorisasi yang menunggu redirect');
    }
    pending.complete(redirectUri);
  }

  Completer<Uri>? _pendingRedirect;

  // ---------------------------------------------------------------------------
  // Persistensi token (JSON 0600, atomik)
  // ---------------------------------------------------------------------------

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final Map<String, dynamic>? raw;
      if (_loadOverride != null) {
        raw = await _loadOverride();
      } else {
        final path = config.tokenStorePath;
        if (path == null) return;
        final file = File(path);
        if (!await file.exists()) return;
        final decoded = jsonDecode(await file.readAsString());
        raw = decoded is Map<String, dynamic> ? decoded : null;
      }
      if (raw == null) return;
      if (raw['server_url'] is String && raw['server_url'] != config.serverUrl) {
        // Token milik server lain; abaikan (fail-closed).
        return;
      }
      final access = raw['access_token'];
      if (access is String && access.isNotEmpty) {
        _cachedToken = access;
        final expiresAt = raw['expires_at'];
        _expiresAt = expiresAt is int
            ? DateTime.fromMillisecondsSinceEpoch(expiresAt)
            : DateTime.fromMillisecondsSinceEpoch(0);
      }
      final refresh = raw['refresh_token'];
      if (refresh is String && refresh.isNotEmpty) _refreshToken = refresh;
      final storedEndpoint = raw['token_endpoint'];
      if (storedEndpoint is String && storedEndpoint.isNotEmpty) {
        _tokenEndpoint = storedEndpoint;
      }
      final reg = raw['registration'];
      if (reg is Map<String, dynamic>) registration = reg;
    } catch (_) {
      // best-effort: token store korup tidak boleh mematikan koneksi MCP;
      // alur interaktif akan dijalankan ulang.
    }
  }

  Future<void> _persist() async {
    final tokens = <String, dynamic>{
      'server_url': config.serverUrl,
      'access_token': _cachedToken,
      'refresh_token': _refreshToken,
      'expires_at': _expiresAt.millisecondsSinceEpoch,
      'client_id': _effectiveClientId,
      if (_tokenEndpoint != null) 'token_endpoint': _tokenEndpoint,
      if (registration != null) 'registration': registration,
    };
    if (_persistOverride != null) {
      await _persistOverride(tokens);
      return;
    }
    final path = config.tokenStorePath;
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(tokens), flush: true);
    try {
      final chmod = await Process.run('chmod', ['600', tmp.path]);
      // best-effort: bila chmod gagal (mis. platform tanpa POSIX), lanjut.
      if (chmod.exitCode != 0) {
        // diabaikan; file tmp tetap di-rename
      }
    } catch (_) {
      // best-effort
    }
    await tmp.rename(file.path);
  }

  // ---------------------------------------------------------------------------
  // Discovery (RFC 9728 -> RFC 8414)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> _fetchWellKnown(Uri url) async {
    try {
      final res = await _client
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final decoded =
          jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null; // discovery bersifat best-effort; endpoint manual tetap jalan
    }
  }

  /// Kandidat well-known sesuai RFC 8414/9728: sisipkan path antara host dan
  /// path asli, lalu fallback root.
  List<Uri> _wellKnownCandidates(Uri base, String suffix) {
    final candidates = <Uri>[];
    final path = base.path;
    if (path.isNotEmpty && path != '/') {
      final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
      candidates.add(base.replace(path: '/.well-known/$suffix$trimmed'));
    }
    candidates.add(base.replace(path: '/.well-known/$suffix'));
    return candidates;
  }

  Future<({String authorization, String token, String? registration,
          List<String> challengeMethods})?> _discover() async {
    final server = Uri.parse(config.serverUrl);
    Map<String, dynamic>? authServerMeta;
    // 1. RFC 9728: metadata protected resource -> authorization_servers.
    for (final candidate in _wellKnownCandidates(server, 'oauth-protected-resource')) {
      final meta = await _fetchWellKnown(candidate);
      final servers = meta?['authorization_servers'];
      if (servers is List && servers.isNotEmpty && servers.first is String) {
        final authServer = Uri.parse(servers.first as String);
        for (final c
            in _wellKnownCandidates(authServer, 'oauth-authorization-server')) {
          authServerMeta = await _fetchWellKnown(c);
          if (authServerMeta != null) break;
        }
        break;
      }
    }
    // 2. Fallback langsung: server MCP juga bisa jadi authorization server.
    if (authServerMeta == null) {
      for (final c
          in _wellKnownCandidates(server, 'oauth-authorization-server')) {
        authServerMeta = await _fetchWellKnown(c);
        if (authServerMeta != null) break;
      }
    }
    if (authServerMeta == null) return null;
    final authorization = authServerMeta['authorization_endpoint'];
    final token = authServerMeta['token_endpoint'];
    if (authorization is! String || token is! String) return null;
    final registrationEndpoint = authServerMeta['registration_endpoint'];
    final challenges = authServerMeta['code_challenge_methods_supported'];
    return (
      authorization: authorization,
      token: token,
      registration:
          registrationEndpoint is String ? registrationEndpoint : null,
      challengeMethods: challenges is List
          ? challenges.whereType<String>().toList()
          : const <String>[],
    );
  }

  // ---------------------------------------------------------------------------
  // Dynamic Client Registration (RFC 7591)
  // ---------------------------------------------------------------------------

  Future<void> _registerClient(
    String registrationEndpoint,
    String redirectUri,
  ) async {
    fetchCount += 1;
    final res = await _client
        .post(
          Uri.parse(registrationEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'client_name': 'Tiko-Agent MCP',
            'redirect_uris': [redirectUri],
            'grant_types': ['authorization_code', 'refresh_token'],
            'response_types': ['code'],
            'token_endpoint_auth_method': 'none',
            if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw McpOAuthFlowException(
        'Dynamic client registration gagal (HTTP ${res.statusCode})',
        code: 'dcr_failed',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic> ||
        decoded['client_id'] is! String ||
        (decoded['client_id'] as String).isEmpty) {
      throw const McpOAuthFlowException(
        'Respons DCR tidak memuat client_id',
        code: 'dcr_failed',
      );
    }
    registration = decoded;
  }

  // ---------------------------------------------------------------------------
  // Alur interaktif
  // ---------------------------------------------------------------------------

  Future<String> _interactiveAuthorization() async {
    // 1. Resolusi endpoint: manual menang, discovery melengkapi sisanya.
    var authorizationEndpoint = config.authorizationUrl;
    var tokenEndpoint = config.tokenUrl ?? _tokenEndpoint;
    var registrationEndpoint = config.registrationUrl;
    var challengeMethods = const <String>[];
    final needDiscovery = config.useDiscovery &&
        (authorizationEndpoint == null || tokenEndpoint == null);
    if (needDiscovery) {
      final meta = await _discover();
      if (meta != null) {
        authorizationEndpoint ??= meta.authorization;
        tokenEndpoint ??= meta.token;
        registrationEndpoint ??= meta.registration;
        challengeMethods = meta.challengeMethods;
      }
    }
    if (authorizationEndpoint == null || tokenEndpoint == null) {
      throw const McpOAuthFlowException(
        'Endpoint otorisasi/token tidak ditemukan: isi authorization_url + '
        'token_url atau aktifkan discovery yang valid',
        code: 'no_endpoints',
      );
    }
    _tokenEndpoint = tokenEndpoint;

    // 2. Redirect loopback. Mode injected (host/test menyuntik redirect lewat
    // [completeCallback]) dipakai bila callback otorisasi disediakan atau
    // browser nonaktif; tanpa itu, server loopback dipakai.
    final useInjectedCallback = _onAuthorizeUrl != null || !_openBrowser;
    HttpServer? redirectServer;
    Completer<Uri>? redirectCompleter;
    String redirectUri;
    if (useInjectedCallback) {
      redirectUri =
          'http://127.0.0.1:${config.redirectPort}/callback';
      redirectCompleter = Completer<Uri>();
    } else {
      redirectServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        config.redirectPort,
      );
      redirectUri = 'http://127.0.0.1:${redirectServer.port}/callback';
      redirectCompleter = Completer<Uri>();
      final completer = redirectCompleter;
      redirectServer.listen((req) async {
        try {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><body><h2>Otorisasi Tiko selesai.</h2>'
            '<p>Silakan kembali ke aplikasi.</p></body></html>',
          );
          // Respons di-flush dulu agar browser menerima halaman selesai
          // sebelum alur dilanjutkan dan server ditutup.
          await req.response.close();
          if (!completer.isCompleted) completer.complete(req.uri);
        } catch (_) {
          // best-effort: browser sudah menutup koneksi
        }
      });
    }
    _pendingRedirect = redirectCompleter;

    try {
      // 3. Client ID: konfigurasi -> DCR.
      if (_effectiveClientId.isEmpty) {
        if (registrationEndpoint == null) {
          throw const McpOAuthFlowException(
            'client_id tidak tersedia dan registration_endpoint tidak ditemukan '
            '(isi client_id atau aktifkan discovery dengan DCR)',
            code: 'no_client_id',
          );
        }
        await _registerClient(registrationEndpoint, redirectUri);
      }
      final clientId = _effectiveClientId;
      final clientSecret = _effectiveClientSecret;

      // 4. PKCE.
      final useS256 = config.usePkce &&
          (challengeMethods.isEmpty || challengeMethods.contains('S256'));
      final usePlain = config.usePkce && !useS256;
      final verifier = config.usePkce ? generateVerifier(_random) : null;

      // 5. Bangun URL otorisasi.
      final state = _randomState();
      final authorize = Uri.parse(authorizationEndpoint).replace(queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'state': state,
        if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
        'resource': config.serverUrl,
        if (useS256 && verifier != null)
          'code_challenge': pkceChallenge(verifier),
        if (useS256) 'code_challenge_method': 'S256',
        if (usePlain && verifier != null) 'code_challenge': verifier,
        if (usePlain) 'code_challenge_method': 'plain',
      });
      lastAuthorizeUrl = authorize;

      // 6. Buka browser / beri tahu host.
      if (_onAuthorizeUrl != null) {
        _onAuthorizeUrl(authorize);
      } else if (_openBrowser) {
        await _openBrowserBestEffort(authorize);
      }

      // 7. Tunggu redirect (loopback atau completeCallback) dengan batas waktu.
      final redirect =
          await redirectCompleter.future.timeout(config.authorizeTimeout);

      // 8. Validasi fail-closed.
      final error = redirect.queryParameters['error'];
      if (error != null) {
        throw McpOAuthFlowException(
          'Server otorisasi menolak: $error'
          '${redirect.queryParameters['error_description'] != null ? ' (${redirect.queryParameters['error_description']})' : ''}',
          code: error,
        );
      }
      if (redirect.queryParameters['state'] != state) {
        throw const McpOAuthFlowException(
          'State otorisasi tidak cocok (kemungkinan CSRF); alur dibatalkan',
          code: 'state_mismatch',
        );
      }
      final code = redirect.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const McpOAuthFlowException(
          'Redirect tidak memuat authorization code',
          code: 'no_code',
        );
      }

      // 9. Tukar code menjadi token.
      final tokens = await _exchangeCode(
        tokenEndpoint: tokenEndpoint,
        code: code,
        redirectUri: redirectUri,
        verifier: verifier,
        clientId: clientId,
        clientSecret: clientSecret,
      );
      return tokens;
    } finally {
      _pendingRedirect = null;
      try {
        await redirectServer?.close(force: true);
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<void> _openBrowserBestEffort(Uri url) async {
    const candidates = ['xdg-open', 'open'];
    for (final cmd in candidates) {
      try {
        final res = await Process.run(cmd, [url.toString()]);
        if (res.exitCode == 0) return;
      } catch (_) {
        // best-effort: coba kandidat berikutnya
      }
    }
    // Tidak ada browser tersedia -> pengguna tetap bisa membuka URL manual;
    // alur akan timeout bila redirect tak pernah datang.
  }

  Map<String, String> _clientAuth({
    required String clientId,
    required String clientSecret,
  }) {
    var method = config.authMethod;
    if (method == 'auto') {
      method = clientSecret.isNotEmpty ? 'basic' : 'none';
    }
    switch (method) {
      case 'basic':
        final basic =
            base64Encode(utf8.encode('$clientId:$clientSecret'));
        return {'authorization': 'Basic $basic'};
      case 'post':
      case 'none':
      default:
        return const {};
    }
  }

  Map<String, String> _clientAuthBody({
    required String clientId,
    required String clientSecret,
  }) {
    var method = config.authMethod;
    if (method == 'auto') {
      method = clientSecret.isNotEmpty ? 'basic' : 'none';
    }
    switch (method) {
      case 'post':
        return {'client_id': clientId, 'client_secret': clientSecret};
      case 'none':
        return {'client_id': clientId};
      case 'basic':
      default:
        return const {};
    }
  }

  Future<String> _exchangeCode({
    required String tokenEndpoint,
    required String code,
    required String redirectUri,
    required String? verifier,
    required String clientId,
    required String clientSecret,
  }) async {
    fetchCount += 1;
    final form = <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'resource': config.serverUrl,
      ..._clientAuthBody(clientId: clientId, clientSecret: clientSecret),
      if (verifier != null) 'code_verifier': verifier,
    };
    final res = await _client
        .post(
          Uri.parse(tokenEndpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            ..._clientAuth(clientId: clientId, clientSecret: clientSecret),
          },
          body: form,
        )
        .timeout(const Duration(seconds: 15));
    return _parseTokenResponse(res, 'authorization_code');
  }

  Future<String> _refreshTokens() async {
    final endpoint = config.tokenUrl ?? _tokenEndpoint;
    if (endpoint == null) {
      throw const McpOAuthFlowException(
        'token endpoint tidak diketahui; jalankan otorisasi ulang',
        code: 'no_token_endpoint',
      );
    }
    final clientId = _effectiveClientId;
    final clientSecret = _effectiveClientSecret;
    fetchCount += 1;
    final form = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': _refreshToken!,
      if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
      ..._clientAuthBody(clientId: clientId, clientSecret: clientSecret),
    };
    final res = await _client
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            ..._clientAuth(clientId: clientId, clientSecret: clientSecret),
          },
          body: form,
        )
        .timeout(const Duration(seconds: 15));
    return _parseTokenResponse(res, 'refresh_token');
  }

  Future<String> _parseTokenResponse(http.Response res, String grant) async {
    if (res.statusCode != 200) {
      String? oauthError;
      try {
        final decoded =
            jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
        if (decoded is Map<String, dynamic> && decoded['error'] is String) {
          oauthError = decoded['error'] as String;
        }
      } catch (_) {
        // best-effort: respons bukan JSON
      }
      throw McpOAuthFlowException(
        'Token endpoint HTTP ${res.statusCode} (grant $grant)',
        code: oauthError ?? 'http_${res.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic> ||
        decoded['access_token'] is! String ||
        (decoded['access_token'] as String).isEmpty) {
      throw McpOAuthFlowException(
        'Respons token tidak memuat access_token (grant $grant)',
        code: 'no_access_token',
      );
    }
    _cachedToken = decoded['access_token'] as String;
    final refresh = decoded['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) _refreshToken = refresh;
    final expiresIn = decoded['expires_in'];
    final seconds = expiresIn is int && expiresIn > 60 ? expiresIn : 300;
    _expiresAt = _clock().add(Duration(seconds: seconds - 60));
    await _persist();
    return _cachedToken!;
  }
}
