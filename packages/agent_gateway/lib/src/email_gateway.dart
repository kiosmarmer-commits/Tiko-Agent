import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// SMTP gateway with optional STARTTLS (AGD-05 / email).
class EmailGateway implements Gateway {
  EmailGateway({
    required this.from,
    required this.host,
    this.port = 25,
    this.toAllowlist = const {},
    this.defaultTo,
    this.useStartTls = false,
    this.username,
    this.password,
    this.responseTimeout = const Duration(seconds: 10),
    this.transactionTimeout = const Duration(seconds: 60),
  })  : assert(responseTimeout > Duration.zero),
        assert(transactionTimeout > Duration.zero);

  final String from;
  final String host;
  final int port;
  final Set<String> toAllowlist;
  final String? defaultTo;
  final bool useStartTls;
  final String? username;
  final String? password;

  /// Maximum wait for one server response (greeting, EHLO, AUTH, etc.).
  final Duration responseTimeout;

  /// Hard deadline for the complete SMTP transaction after TCP connect.
  final Duration transactionTimeout;

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
    _validateMailbox(to, 'recipient');
    _validateMailbox(from, 'sender');
    if (subject.contains(RegExp(r'[\x00-\x1F\x7F]')) ||
        utf8.encode(subject).length > 998) {
      throw ArgumentError.value(
        subject,
        'subject',
        'Invalid SMTP header value',
      );
    }
    await _smtpSend(to: to, subject: subject, body: body);
  }

  static void _validateMailbox(String value, String field) {
    final parts = value.split('@');
    if (utf8.encode(value).length > 254 ||
        parts.length != 2 ||
        parts.any((part) => part.isEmpty) ||
        RegExp(r'[\x00-\x20\x7F<>]').hasMatch(value)) {
      throw ArgumentError.value(
        value,
        field,
        'Invalid SMTP mailbox',
      );
    }
  }

  Future<void> _smtpSend({
    required String to,
    required String subject,
    required String body,
  }) async {
    final hasUsername = username != null;
    final hasPassword = password != null;
    if (hasUsername != hasPassword) {
      throw StateError(
        'email: SMTP username and password must be configured together',
      );
    }
    if (hasUsername && !useStartTls) {
      throw StateError('email: SMTP credentials require STARTTLS');
    }

    Socket socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );
    var responseStream = _smtpResponseLines(socket);
    final transactionClock = Stopwatch()..start();

    Duration remaining(String operation) {
      final value = transactionTimeout - transactionClock.elapsed;
      if (value.inMicroseconds <= 0) {
        throw TimeoutException('SMTP transaction timed out during $operation');
      }
      return value;
    }

    Future<T> bounded<T>(
      Future<T> future,
      String operation, {
      bool serverResponse = false,
    }) {
      final totalRemaining = remaining(operation);
      final limit = serverResponse && totalRemaining > responseTimeout
          ? responseTimeout
          : totalRemaining;
      return future.timeout(
        limit,
        onTimeout: () => throw TimeoutException(
          'SMTP $operation timed out after ${limit.inMilliseconds} ms',
        ),
      );
    }

    try {
      Future<String> readLine() async {
        if (!await bounded(
          responseStream.moveNext(),
          'server response',
          serverResponse: true,
        )) {
          throw SocketException('SMTP connection closed unexpectedly');
        }
        return responseStream.current;
      }

      Future<(String, List<String>)> readResponse() async {
        final first = await readLine();
        final firstMatch = RegExp(r'^([0-9]{3})([- ])').firstMatch(first);
        if (firstMatch == null) {
          throw FormatException('Invalid SMTP response: $first');
        }
        final code = firstMatch.group(1)!;
        final lines = <String>[first];
        var continuation = firstMatch.group(2) == '-';
        while (continuation) {
          if (lines.length >= 100) {
            throw FormatException('SMTP response exceeded 100 lines');
          }
          final line = await readLine();
          final match = RegExp('^$code([- ])').firstMatch(line);
          if (match == null) {
            throw FormatException('Invalid SMTP continuation: $line');
          }
          lines.add(line);
          continuation = match.group(1) == '-';
        }
        return (code, lines);
      }

      Future<List<String>> expectResponse(
        String operation,
        Set<String> expectedCodes,
      ) async {
        final (code, lines) = await readResponse();
        if (!expectedCodes.contains(code)) {
          throw StateError(
            'SMTP $operation failed ($code): ${lines.join(' | ')}',
          );
        }
        return lines;
      }

      Future<void> write(String value) async {
        remaining('write');
        socket.add(utf8.encode('$value\r\n'));
        await bounded(socket.flush(), 'socket write');
      }

      await expectResponse('greeting', {'220'});
      await write('EHLO agent-dart');
      final ehlo = await expectResponse('EHLO', {'250'});

      if (useStartTls) {
        final supportsStartTls = ehlo.any((line) {
          final capability = line.length > 4 ? line.substring(4).trim() : '';
          final name = capability.split(RegExp(r'\s+')).first;
          return name.toUpperCase() == 'STARTTLS';
        });
        if (!supportsStartTls) {
          throw StateError(
            'SMTP server does not advertise STARTTLS; '
            'refusing plaintext downgrade',
          );
        }

        await write('STARTTLS');
        await expectResponse('STARTTLS', {'220'});
        // Stop reading the plaintext socket before handing it to TLS. SMTP
        // servers must not send application data before the TLS handshake.
        await bounded(responseStream.cancel(), 'close plaintext response stream');
        socket = await bounded(
          SecureSocket.secure(socket, host: host),
          'STARTTLS handshake',
        );
        responseStream = _smtpResponseLines(socket);

        await write('EHLO agent-dart');
        await expectResponse('EHLO after STARTTLS', {'250'});
      }

      if (username != null && password != null) {
        await write('AUTH LOGIN');
        await expectResponse('AUTH LOGIN', {'334'});
        await write(base64Encode(utf8.encode(username!)));
        await expectResponse('SMTP username', {'334'});
        await write(base64Encode(utf8.encode(password!)));
        await expectResponse('SMTP password', {'235'});
      }

      await write('MAIL FROM:<$from>');
      await expectResponse('MAIL FROM', {'250'});
      await write('RCPT TO:<$to>');
      await expectResponse('RCPT TO', {'250', '251'});
      await write('DATA');
      await expectResponse('DATA', {'354'});
      // SMTP DATA uses CRLF regardless of the host platform. Dot-stuff every
      // body line that begins with '.', including the first line, without
      // relying on replacement-group syntax unsupported by String.replaceAll.
      final normalizedBody = body
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      final stuffedBody = normalizedBody.replaceAllMapped(
        RegExp(r'(^|\n)\.'),
        (match) => '${match.group(1)}..',
      );
      final payload = <String>[
        'From: $from',
        'To: $to',
        'Subject: $subject',
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=utf-8',
        '',
        ...stuffedBody.split('\n'),
        '.',
      ].join('\r\n');
      await write(payload);
      await expectResponse('message body', {'250'});
      await write('QUIT');
    } finally {
      // A failed/stalled relay must not keep a socket or response subscription
      // alive. destroy() is intentional here: QUIT was flushed on success,
      // while waiting for graceful close could otherwise hang indefinitely.
      socket.destroy();
      try {
        await responseStream.cancel().timeout(responseTimeout);
      } catch (_) {}
    }
  }

  StreamIterator<String> _smtpResponseLines(Socket socket) =>
      StreamIterator<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async => _inbound.close();
}
