import 'dart:convert';

import 'package:http/http.dart' as http;

/// FR-07 (Multi-Platform Gateway): WhatsApp Business Cloud API (Meta).
///
/// Two halves:
/// - outbound: [WhatsAppGateway.sendText]
/// - inbound:  [WhatsAppGateway.verifyWebhook] (GET handshake) and
///   [WhatsAppGateway.parseWebhook] (POST message extraction)
///
/// SECURITY NOTE: full payload authentication uses the `X-Hub-Signature-256`
/// HMAC-SHA256 header. HMAC verification requires `package:crypto` to be
/// added to agent_gateway's pubspec; until then callers can inject their
/// own verifier via [signatureVerifier] (implementations that already
/// depend on crypto can pass one). Without a verifier the webhook handler
/// MUST be treated as untrusted input.
class WhatsAppGateway {
  WhatsAppGateway({
    required this.phoneNumberId,
    required this.accessToken,
    required this.verifyToken,
    this.apiVersion = 'v20.0',
    this.client,
    this.signatureVerifier,
  });

  final String phoneNumberId;
  final String accessToken;
  final String verifyToken;
  final String apiVersion;
  final http.Client? client;

  /// `f(rawBody, headerValue) -> bool`; validates X-Hub-Signature-256.
  final bool Function(String rawBody, String headerValue)? signatureVerifier;

  http.Client get _client => client ?? http.Client();

  Uri get _messagesUri =>
      Uri.parse('https://graph.facebook.com/$apiVersion/$phoneNumberId/messages');

  /// Sends a plain text message. Returns the message id from Meta.
  Future<String> sendText(String to, String body) async {
    if (to.trim().isEmpty || body.trim().isEmpty) {
      throw ArgumentError('to dan body wajib');
    }
    if (body.length > 4096) {
      throw ArgumentError('body terlalu panjang (maks 4096 karakter)');
    }
    final resp = await _client.post(
      _messagesUri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'messaging_product': 'whatsapp',
        'recipient_type': 'individual',
        'to': to,
        'type': 'text',
        'text': {'body': body},
      }),
    ).timeout(const Duration(seconds: 30));
    final map = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (resp.statusCode >= 400) {
      final err = map is Map && map['error'] is Map
          ? map['error']['message']
          : map;
      throw StateError('WhatsApp send gagal (HTTP ${resp.statusCode}): $err');
    }
    return (map is Map && map['messages'] is List && (map['messages'] as List).isNotEmpty)
        ? (((map['messages'] as List).first as Map)['id'] ?? '').toString()
        : '';
  }

  /// GET webhook handshake: Meta echoes [hub.challenge] when the verify
  /// token matches. Returns null when verification fails.
  String? verifyWebhook(Map<String, String> query) {
    final mode = query['hub.mode'] ?? '';
    final token = query['hub.verify_token'] ?? '';
    final challenge = query['hub.challenge'] ?? '';
    if (mode != 'subscribe' || token != verifyToken || challenge.isEmpty) {
      return null;
    }
    return challenge;
  }

  /// Validates the X-Hub-Signature-256 header against the raw body using
  /// the injected [signatureVerifier]. Without a verifier this returns
  /// false — fail-closed.
  bool verifySignature(String rawBody, String headerValue) {
    final v = signatureVerifier;
    if (v == null) return false;
    try {
      return v(rawBody, headerValue);
    } catch (_) {
      return false;
    }
  }

  /// Extracts inbound text messages from a webhook payload.
  /// Returns records: {from, text, messageId, timestamp}.
  List<Map<String, String>> parseWebhook(String rawJson) {
    final out = <Map<String, String>>[];
    dynamic map;
    try {
      map = jsonDecode(rawJson);
    } catch (_) {
      return out;
    }
    if (map is! Map) return out;
    final entries = map['entry'];
    if (entries is! List) return out;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final changes = entry['changes'];
      if (changes is! List) continue;
      for (final change in changes) {
        if (change is! Map) continue;
        final value = change['value'];
        if (value is! Map) continue;
        final messages = value['messages'];
        if (messages is! List) continue;
        for (final m in messages) {
          if (m is! Map) continue;
          if (m['type'] != 'text') continue;
          final from = m['from']?.toString() ?? '';
          final id = m['id']?.toString() ?? '';
          final ts = m['timestamp']?.toString() ?? '';
          final text = m['text'] is Map
              ? (m['text']['body']?.toString() ?? '')
              : '';
          if (from.isEmpty || text.isEmpty) continue;
          out.add({
            'from': from,
            'text': text,
            'messageId': id,
            'timestamp': ts,
          });
        }
      }
    }
    return out;
  }
}
