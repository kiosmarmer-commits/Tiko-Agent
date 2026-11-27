part of 'tiko_runtime.dart';

/// Hermes webhook outbound (`agent/webhook_outbound.py`): registry endpoint
/// HTTP keluar yang menerima POST JSON untuk setiap event runtime yang
/// cocok. Deviasi sadar dari Hermes:
/// - Hermes mengantre antar-proses dengan worker thread; Tiko memakai
///   unawaited future per event dengan batas in-flight (bounded), karena
///   runtime Tiko single-isolate dan event bus sudah broadcast.
/// - Tanda tangan HMAC-SHA256 hex di header `x-tiko-signature`
///   (`sha256=<hex>` atas body) dengan secret per endpoint.
/// - Never-raises: kegagalan jaringan/encode/parse tidak pernah menggagalkan
///   turn agent; hanya counter internal yang berubah.
class OutboundWebhookRegistry {
  OutboundWebhookRegistry(this.hooks, {HttpClient? client})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  final List<OutboundWebhookConfig> hooks;
  final HttpClient _client;
  StreamSubscription<TikoEvent>? _sub;
  int _inFlight = 0;
  int delivered = 0;
  int failed = 0;

  /// Batas in-flight agar badai event tidak menumpuk request; kelebihan
  /// dilewati (fail-open, tidak menahan emit).
  static const maxInFlight = 32;

  /// Timeout per POST (Hermes default 10 detik).
  static const postTimeoutSec = 10;

  /// Berlangganan event bus. Aman dipanggil dua kali (idempoten).
  void start(EventBus events) {
    if (_sub != null) return;
    if (hooks.isEmpty) return;
    _sub = events.stream.listen(_dispatch);
  }

  bool _matches(OutboundWebhookConfig hook, String type) {
    if (hook.events.isEmpty) return true;
    for (final pattern in hook.events) {
      if (pattern == '*' || pattern == type) return true;
      if (pattern.endsWith('*') &&
          type.startsWith(pattern.substring(0, pattern.length - 1))) {
        return true;
      }
    }
    return false;
  }

  void _dispatch(TikoEvent event) {
    for (final hook in hooks) {
      if (!_matches(hook, event.type)) continue;
      if (_inFlight >= maxInFlight) {
        failed++;
        continue;
      }
      _inFlight++;
      unawaited(_post(hook, event));
    }
  }

  Future<void> _post(OutboundWebhookConfig hook, TikoEvent event) async {
    try {
      final body = jsonEncode({
        'type': event.type,
        'data': event.data,
        'at': event.at.toIso8601String(),
      });
      final req = await _client
          .postUrl(Uri.tryParse(hook.url) ?? (throw const FormatException('url')))
          .timeout(const Duration(seconds: postTimeoutSec));
      req.headers.contentType = ContentType.json;
      final secret = hook.secret;
      if (secret != null) {
        final sig = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body));
        req.headers.set('x-tiko-signature', 'sha256=$sig');
      }
      req.write(body);
      final resp = await req.close().timeout(
            const Duration(seconds: postTimeoutSec),
          );
      await resp.drain<void>().timeout(
            const Duration(seconds: postTimeoutSec),
          );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        delivered++;
      } else {
        failed++;
      }
    } catch (_) {
      failed++;
    } finally {
      _inFlight--;
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _client.close(force: true);
  }
}
