import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'slack_gateway.dart';
import 'webhook_signature.dart';
import 'whatsapp_gateway.dart';
import 'line_gateway.dart';
import 'teams_gateway.dart';

/// Inbound webhook routes for the WhatsApp Cloud API and the Slack Events
/// API, mounted on [HttpApiServer]. These requests come from external
/// platforms, so they authenticate with HMAC-SHA256 signatures instead
/// of the local bearer token — verification fails closed.
class WebhookEndpoint {
  WebhookEndpoint({
    required this.onMessage,
    this.whatsapp,
    this.whatsappAppSecret,
    this.slack,
    this.slackSigningSecret,
    this.line,
    this.lineChannelSecret,
    this.teams,
    this.teamsBotAuthToken,
  });

  final WhatsAppGateway? whatsapp;
  final String? whatsappAppSecret;
  final SlackGateway? slack;
  final String? slackSigningSecret;
  final LineGateway? line;
  final String? lineChannelSecret;
  final TeamsGateway? teams;
  final String? teamsBotAuthToken;
  final Future<void> Function(InboundMessage message) onMessage;

  Future<void> handle(HttpRequest req, String path) async {
    if (path == '/webhooks/whatsapp') {
      if (req.method == 'GET') {
        await _whatsappHandshake(req);
      } else if (req.method == 'POST') {
        await _whatsappMessages(req);
      } else {
        req.response.statusCode = 405;
        req.response.close();
      }
      return;
    }
    if (path == '/webhooks/slack') {
      if (req.method == 'POST') {
        await _slackEvents(req);
      } else {
        req.response.statusCode = 405;
        req.response.close();
      }
      return;
    }
    if (path == '/webhooks/line') {
      if (req.method == 'POST') {
        await _lineMessages(req);
      } else {
        req.response.statusCode = 405;
        await req.response.close();
      }
      return;
    }
    if (path == '/webhooks/teams') {
      if (req.method == 'POST') {
        await _teamsMessages(req);
      } else {
        req.response.statusCode = 405;
        await req.response.close();
      }
      return;
    }
    req.response.statusCode = 404;
    req.response.close();
  }

  Future<void> _lineMessages(HttpRequest req) async {
    final gateway = line;
    final secret = lineChannelSecret;
    if (gateway == null || secret == null || secret.isEmpty) {
      _deny(req, 403, 'line webhook not configured');
      return;
    }
    final raw = await utf8.decoder.bind(req).join();
    final signature = req.headers.value('x-line-signature') ?? '';
    if (!LineGateway.verifySignature(secret, raw, signature)) {
      _deny(req, 401, 'invalid signature');
      return;
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _deny(req, 400, 'invalid json');
      return;
    }
    var accepted = 0;
    final subscription = gateway.inbound.listen((message) async {
      accepted++;
      await onMessage(message);
    });
    try {
      gateway.pushInbound(webhookData: payload);
      await Future<void>.delayed(Duration.zero);
    } finally {
      await subscription.cancel();
    }
    _json(req, {'ok': true, 'accepted': accepted});
  }

  Future<void> _teamsMessages(HttpRequest req) async {
    final gateway = teams;
    final expected = teamsBotAuthToken;
    if (gateway == null || expected == null || expected.isEmpty) {
      _deny(req, 403, 'teams webhook not configured');
      return;
    }
    final authorization = req.headers.value(HttpHeaders.authorizationHeader);
    if (authorization != 'Bearer $expected') {
      _deny(req, 401, 'invalid bearer token');
      return;
    }
    final raw = await utf8.decoder.bind(req).join();
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _deny(req, 400, 'invalid json');
      return;
    }
    var accepted = 0;
    final subscription = gateway.inbound.listen((message) async {
      accepted++;
      await onMessage(message);
    });
    try {
      gateway.pushBotFrameworkActivity(payload);
      await Future<void>.delayed(Duration.zero);
    } finally {
      await subscription.cancel();
    }
    _json(req, {'ok': true, 'accepted': accepted});
  }

  Future<void> _whatsappHandshake(HttpRequest req) async {
    final gateway = whatsapp;
    if (gateway == null) {
      _deny(req, 403, 'whatsapp webhook not configured');
      return;
    }
    final challenge = gateway.verifyWebhook(req.uri.queryParameters);
    if (challenge == null) {
      _deny(req, 403, 'verify token mismatch');
      return;
    }
    req.response.headers.contentType = ContentType.text;
    req.response.write(challenge);
    await req.response.close();
  }

  Future<void> _whatsappMessages(HttpRequest req) async {
    final gateway = whatsapp;
    final secret = whatsappAppSecret;
    if (gateway == null || secret == null || secret.isEmpty) {
      _deny(req, 403, 'whatsapp webhook not configured');
      return;
    }
    final raw = await utf8.decoder.bind(req).join();
    final header = req.headers.value('x-hub-signature-256') ?? '';
    final ok = WebhookSignature.verifyMeta(
      rawBody: raw,
      headerValue: header,
      appSecret: secret,
    );
    if (!ok) {
      _deny(req, 401, 'invalid signature');
      return;
    }
    var accepted = 0;
    for (final m in gateway.parseWebhook(raw)) {
      await onMessage(
        InboundMessage(
          channel: 'whatsapp',
          userKey: 'wa:${m['from']}',
          sessionKey: 'wa:${m['from']}',
          text: m['text'] ?? '',
        ),
      );
      accepted++;
    }
    _json(req, {'ok': true, 'accepted': accepted});
  }

  Future<void> _slackEvents(HttpRequest req) async {
    final gateway = slack;
    final secret = slackSigningSecret;
    if (gateway == null || secret == null || secret.isEmpty) {
      _deny(req, 403, 'slack webhook not configured');
      return;
    }
    final raw = await utf8.decoder.bind(req).join();
    final sig = req.headers.value('x-slack-signature') ?? '';
    final ts = req.headers.value('x-slack-request-timestamp') ?? '';
    final ok = WebhookSignature.verifySlack(
      rawBody: raw,
      timestampSeconds: ts,
      headerValue: sig,
      signingSecret: secret,
    );
    if (!ok) {
      _deny(req, 401, 'invalid signature');
      return;
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _deny(req, 400, 'invalid json');
      return;
    }
    if (payload['type'] == 'url_verification') {
      _json(req, {'challenge': payload['challenge'] ?? ''});
      return;
    }
    final msg = gateway.parseEventMessage(payload);
    if (msg != null) {
      await onMessage(
        InboundMessage(
          channel: 'slack',
          userKey: 'slack:${msg['userId']}',
          sessionKey: 'slack:${msg['channelId']}',
          text: msg['text'] ?? '',
        ),
      );
    }
    _json(req, {'ok': true});
  }

  void _deny(HttpRequest req, int status, String message) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({'error': message}));
    req.response.close();
  }

  void _json(HttpRequest req, Object data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }
}
