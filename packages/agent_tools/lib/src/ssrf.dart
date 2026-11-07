import 'dart:async';

import 'dart:io';

/// SSRF protection helpers (AGD-04 §7, AGD-07 C-08).
class SsrfGuard {
  SsrfGuard({
    this.maxRedirects = 3,
    this.maxBytes = 2 * 1024 * 1024,
    this.allowedSchemes = const ['http', 'https'],
    this.timeout = const Duration(seconds: 20),
  });

  final int maxRedirects;
  final int maxBytes;
  final List<String> allowedSchemes;
  final Duration timeout;

  /// Returns null if URL is safe to fetch, otherwise an error message.
  Future<String?> checkUrl(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return 'URL tidak valid';
    }
    if (!allowedSchemes.contains(uri.scheme.toLowerCase())) {
      return 'Skema tidak diizinkan: ${uri.scheme}';
    }
    if (uri.host.isEmpty) return 'Host kosong';

    // Block obvious local hostnames before DNS.
    final host = uri.host.toLowerCase();
    if (_blockedHostnames.contains(host)) {
      return 'Host diblokir (loopback/metadata): $host';
    }

    // Resolve DNS and check every address.
    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      return 'Gagal resolve DNS: $e';
    }
    if (addrs.isEmpty) return 'DNS tidak mengembalikan alamat';

    for (final addr in addrs) {
      if (isPrivateOrReserved(addr)) {
        return 'IP privat/reserved diblokir: ${addr.address}';
      }
    }
    return null;
  }

  /// Builds an [HttpClient] that re-resolves DNS at connect time and only
  /// connects to validated public addresses. This closes the TOCTOU gap
  /// between [checkUrl] and the actual TCP connect (DNS rebinding): a
  /// hostname that flips to a private address after validation is refused
  /// before any request bytes are sent.
  HttpClient pinnedHttpClient() {
    final client = HttpClient()..connectionTimeout = timeout;
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      final Future<Socket> socketFuture;
      if (proxyHost == null) {
        socketFuture = _pinnedConnect(url.host, url.port, url);
      } else {
        // Operator-configured proxy may legitimately be local; connect
        // directly to it without pinning.
        final port = proxyPort ?? (url.scheme == 'https' ? 443 : 80);
        socketFuture = _plainConnect(proxyHost, port, url);
      }
      return ConnectionTask.fromSocket(socketFuture, () {
        unawaited(
          socketFuture
              .then<void>((s) => s.destroy())
              .catchError((Object _) {}),
        );
      });
    };
    return client;
  }

  /// Resolves [host] at connect time, validates every address, then
  /// connects to the first validated address (no second DNS lookup).
  Future<Socket> _pinnedConnect(String host, int port, Uri url) async {
    final addresses = await InternetAddress.lookup(host)
        .timeout(const Duration(seconds: 5));
    if (addresses.isEmpty) {
      throw const SocketException('DNS tidak mengembalikan alamat');
    }
    for (final addr in addresses) {
      if (isPrivateOrReserved(addr)) {
        throw SocketException(
          'IP privat/reserved diblokir: ${addr.address}',
        );
      }
    }
    final socket = await Socket.connect(
      addresses.first,
      port,
      timeout: const Duration(seconds: 10),
    );
    if (url.scheme == 'https') {
      return SecureSocket.secure(socket, host: url.host);
    }
    return socket;
  }

  Future<Socket> _plainConnect(String host, int port, Uri url) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    if (url.scheme == 'https') {
      return SecureSocket.secure(socket, host: url.host);
    }
    return socket;
  }

  static const _blockedHostnames = {
    'localhost',
    'localhost.localdomain',
    'metadata.google.internal',
    'metadata',
    '0.0.0.0',
  };

  /// True if the address is private, loopback, link-local, or reserved.
  static bool isPrivateOrReserved(InternetAddress addr) {
    if (addr.isLoopback || addr.isLinkLocal) return true;
    final bytes = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final a = bytes[0], b = bytes[1];
      // 10.0.0.0/8
      if (a == 10) return true;
      // 172.16.0.0/12
      if (a == 172 && b >= 16 && b <= 31) return true;
      // 192.168.0.0/16
      if (a == 192 && b == 168) return true;
      // 169.254.0.0/16 link-local / cloud metadata
      if (a == 169 && b == 254) return true;
      // 127.0.0.0/8
      if (a == 127) return true;
      // 0.0.0.0/8
      if (a == 0) return true;
      // 100.64.0.0/10 CGNAT
      if (a == 100 && b >= 64 && b <= 127) return true;
    }
    if (addr.type == InternetAddressType.IPv6) {
      // ::1 already covered by isLoopback
      // fc00::/7 unique local
      if (bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc) return true;
      // fe80::/10 link-local already isLinkLocal
    }
    return false;
  }
}
