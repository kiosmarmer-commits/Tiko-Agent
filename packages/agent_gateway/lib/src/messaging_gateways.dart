import 'dart:convert';
import 'package:http/http.dart' as http;

/// Antarmuka Gateway Pesan
abstract class MessagingGateway {
  String get name;
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments});
}

/// 1. Telegram Gateway (Bot API)
class TelegramGateway implements MessagingGateway {
  @override
  String get name => 'telegram';
  final String botToken;

  TelegramGateway({required this.botToken});

  @override
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
      final response = await client.post(
        uri,
        body: {'chat_id': chatId, 'text': text, 'parse_mode': 'Markdown'},
      );
      return response.statusCode == 200;
    } finally {
      client.close();
    }
  }
}

/// 2. Discord Gateway (Webhook)
class DiscordGateway implements MessagingGateway {
  @override
  String get name => 'discord';
  final String webhookUrl;

  DiscordGateway({required this.webhookUrl});

  @override
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments}) async {
    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'content': text}),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close();
    }
  }
}

/// 3. Slack Gateway (Incoming Webhook)
class SlackGateway implements MessagingGateway {
  @override
  String get name => 'slack';
  final String webhookUrl;

  SlackGateway({required this.webhookUrl});

  @override
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments}) async {
    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      );
      return response.statusCode == 200;
    } finally {
      client.close();
    }
  }
}

/// 4. WhatsApp Gateway (Meta Cloud API)
class WhatsAppGateway implements MessagingGateway {
  @override
  String get name => 'whatsapp';
  final String phoneNumberId;
  final String accessToken;

  WhatsAppGateway({required this.phoneNumberId, required this.accessToken});

  @override
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://graph.facebook.com/v17.0/$phoneNumberId/messages');
      final response = await client.post(
        uri,
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'messaging_product': 'whatsapp',
          'to': chatId,
          'type': 'text',
          'text': {'body': text},
        }),
      );
      return response.statusCode == 200;
    } finally {
      client.close();
    }
  }
}

/// 5. Email Gateway (SendGrid API - lebih andal daripada SMTP murni di Dart tanpa dependensi berat)
class SendGridEmailGateway implements MessagingGateway {
  @override
  String get name => 'email_sendgrid';
  final String apiKey;
  final String fromEmail;

  SendGridEmailGateway({required this.apiKey, required this.fromEmail});

  @override
  Future<bool> sendMessage(String chatId, String text, {List<String>? attachments}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.sendgrid.com/v3/mail/send');
      final response = await client.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'personalizations': [{'to': [{'email': chatId}]}],
          'from': {'email': fromEmail},
          'subject': 'Tiko Agent Message',
          'content': [{'type': 'text/plain', 'value': text}],
        }),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close();
    }
  }
}
