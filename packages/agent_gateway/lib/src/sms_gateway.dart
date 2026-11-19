import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// SMS gateway using various SMS provider APIs.
///
/// Supports multiple SMS providers:
/// - Twilio (recommended)
/// - AWS SNS
/// - Generic HTTP API
///
/// Configuration depends on the provider:
/// - Twilio: accountSid, authToken, fromNumber
/// - AWS SNS: region, accessKey, secretKey, fromNumber
/// - Generic: endpointUrl, apiKey, fromNumber
class SmsGateway implements Gateway {
  /// Create an SMS gateway with Twilio.
  SmsGateway.twilio({
    required this.fromNumber,
    required String accountSid,
    required String authToken,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  })  : _provider = 'twilio',
        _accountSid = accountSid,
        _authToken = authToken,
        _endpoint = 'https://api.twilio.com/2010-04-01/Accounts/$accountSid/Messages.json',
        _region = '',
        _accessKey = '',
        _secretKey = '',
        _apiKey = '',
        _method = 'POST',
        _bodyFormat = 'form';

  /// Create an SMS gateway with AWS SNS.
  SmsGateway.awsSns({
    required this.fromNumber,
    required String region,
    required String accessKey,
    required String secretKey,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  })  : _provider = 'aws_sns',
        _region = region,
        _accessKey = accessKey,
        _secretKey = secretKey,
        _endpoint = 'https://sns.$region.amazonaws.com',
        _accountSid = '',
        _authToken = '',
        _apiKey = '',
        _method = 'POST',
        _bodyFormat = 'json';

  /// Create an SMS gateway with a generic HTTP API.
  SmsGateway.generic({
    required this.fromNumber,
    required String endpointUrl,
    required String apiKey,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
    String? method,
    String? bodyFormat,
  })  : _provider = 'generic',
        _endpoint = endpointUrl,
        _apiKey = apiKey,
        _method = method ?? 'POST',
        _bodyFormat = bodyFormat ?? 'json',
        _accountSid = '',
        _authToken = '',
        _region = '',
        _accessKey = '',
        _secretKey = '';

  final String fromNumber;
  final http.Client? httpClient;
  final Duration timeout;

  final String _provider;
  final String _endpoint;

  // Twilio
  // Twilio
  // ignore: unused_field
  final String _accountSid;
  // ignore: unused_field
  final String _authToken;

  // AWS SNS
  // ignore: unused_field
  final String _region;
  // ignore: unused_field
  final String _accessKey;
  // ignore: unused_field
  final String _secretKey;

  // Generic
  // ignore: unused_field
  final String _apiKey;
  // ignore: unused_field
  final String _method;
  // ignore: unused_field
  final String _bodyFormat;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'sms';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound SMS message.
  void pushInbound({
    required String fromNumber,
    required String toNumber,
    required String text,
    Map<String, Object?> meta = const {},
  }) {
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: fromNumber,
        sessionKey: 'sms:$fromNumber->$toNumber',
        text: text,
        meta: {
          'from': fromNumber,
          'to': toNumber,
          ...meta,
        },
      ),
    );
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final toNumber = m.meta['to'] as String?;
      if (toNumber == null || toNumber.isEmpty) {
        throw StateError('SMS: meta.to (phone number) required');
      }

      switch (_provider) {
        case 'twilio':
          await _sendTwilio(client, toNumber, m.text);
          break;
        case 'aws_sns':
          await _sendAwsSns(client, toNumber, m.text);
          break;
        case 'generic':
          await _sendGeneric(client, toNumber, m.text);
          break;
        default:
          throw StateError('SMS: Unknown provider: $_provider');
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<void> _sendTwilio(http.Client client, String to, String text) async {
    final uri = _endpoint.replaceAll('\$accountSid', _accountSid);
    
    final response = await client
        .post(
          Uri.parse(uri),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            'From': fromNumber,
            'To': to,
            'Body': text,
          },
        )
        .timeout(timeout);

    if (response.statusCode >= 400) {
      throw StateError('Twilio error: HTTP ${response.statusCode} - ${response.body}');
    }
  }

  Future<void> _sendAwsSns(http.Client client, String to, String text) async {
    // AWS SNS uses JSON format
    final payload = {
      'Message': text,
      'PhoneNumber': to,
    };

    // Note: AWS SNS requires proper AWS signature v4, which is complex.
    // This is a simplified version. In production, use aws_sdk or similar.
    final response = await client
        .post(
          Uri.parse(_endpoint),
          headers: {
            'Content-Type': 'application/x-amz-json-1.0',
            'X-Amz-Target': 'AmazonSNS_20100331.Publish',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    if (response.statusCode >= 400) {
      throw StateError('AWS SNS error: HTTP ${response.statusCode} - ${response.body}');
    }
  }

  Future<void> _sendGeneric(http.Client client, String to, String text) async {
    final payload = {
      'from': fromNumber,
      'to': to,
      'text': text,
    };

    final uri = Uri.parse(_endpoint);
    final response = await client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
          },
          body: _bodyFormat == 'json' ? jsonEncode(payload) : payload,
        )
        .timeout(timeout);

    if (response.statusCode >= 400) {
      throw StateError('Generic SMS error: HTTP ${response.statusCode} - ${response.body}');
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // SMS doesn't have a typing indicator
    // This is a no-op
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
