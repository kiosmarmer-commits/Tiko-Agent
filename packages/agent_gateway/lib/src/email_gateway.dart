import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// SMTP gateway with optional STARTTLS (AGD-05 / email).
class EmailGateway implements Gateway {
  EmailGateway({
    required this.from,
    this.host = '127.0.0.1',
    this.port = 25,
    this.toAllowlist = const {},
    this.defaultTo,
    this.useStartTls = false,
    this.username,
    this.password,
  });

  final String from;
  final String host;
  final int port;
  final Set<String> toAllowlist;
  final String? defaultTo;
  final bool useStartTls;
  final String? username;
  final String? password;
  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'email';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  void pushInbound({
    required String fromAddr,
    required String subject,
    required String body,
  }) {
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: fromAddr,
        sessionKey: 'email:$fromAddr',
        text: 'Subject: $subject\n\n$body',
        meta: {'from': fromAddr, 'subject': subject},
      ),
    );
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final to = (m.meta['to'] as String?) ?? defaultTo;
    if (to == null || to.isEmpty) {
      throw StateError('email: meta.to or defaultTo required');
    }
    if (toAllowlist.isNotEmpty && !toAllowlist.contains(to)) {
      throw StateError('email: recipient not allowed');
    }
    final subject = (m.meta['subject'] as String?) ?? 'agent_dart';
    final body = m.text.length > 100000 ? m.text.substring(0, 100000) : m.text;
    await _smtpSend(to: to, subject: subject, body: body);
  }

  Future<void> _smtpSend({
    required String to,
    required String subject,
    required String body,
  }) async {
    Socket socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );
    try {
      Future<String> readLine() async {
        final data = await socket.timeout(const Duration(seconds: 15)).first;
        return utf8.decode(data);
      }

      Future<void> write(String s) async {
        socket.add(utf8.encode('$s\r\n'));
        await socket.flush();
      }

      await readLine(); // banner
      await write('EHLO agent-dart');
      final ehlo = await readLine();

      if (useStartTls && ehlo.toUpperCase().contains('STARTTLS')) {
        await write('STARTTLS');
        await readLine();
        final secure = await SecureSocket.secure(
          socket,
          onBadCertificate: (_) => true, // local/dev; tighten in prod
        );
        socket = secure;
        await write('EHLO agent-dart');
        await readLine();
      }

      if (username != null && password != null) {
        await write('AUTH LOGIN');
        await readLine();
        await write(base64Encode(utf8.encode(username!)));
        await readLine();
        await write(base64Encode(utf8.encode(password!)));
        await readLine();
      }

      await write('MAIL FROM:<$from>');
      await readLine();
      await write('RCPT TO:<$to>');
      await readLine();
      await write('DATA');
      await readLine();
      final payload = StringBuffer()
        ..writeln('From: $from')
        ..writeln('To: $to')
        ..writeln('Subject: $subject')
        ..writeln('MIME-Version: 1.0')
        ..writeln('Content-Type: text/plain; charset=utf-8')
        ..writeln()
        ..writeln(body.replaceAll(RegExp(r'\n\.'), '\n..'))
        ..writeln('.');
      await write(payload.toString().trimRight());
      await readLine();
      await write('QUIT');
    } finally {
      await socket.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}


  @override

  Future<void> close() async => _inbound.close();
}
