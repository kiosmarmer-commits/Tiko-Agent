import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

class _FakeSmtpServer {
  _FakeSmtpServer._(
    this.server,
    this.advertiseStartTls,
    this.stallGreeting,
    this.stallOnCommand,
  ) {
    _subscription = server.listen(_accept);
  }

  final ServerSocket server;
  final bool advertiseStartTls;
  final bool stallGreeting;
  final String? stallOnCommand;
  final commands = <String>[];
  final dataLines = <String>[];
  final wire = StringBuffer();
  final _sockets = <Socket>{};
  final _clientSubscriptions = <StreamSubscription<Uint8List>>[];
  final dataReceived = Completer<void>();
  late final StreamSubscription<Socket> _subscription;

  int get port => server.port;

  static Future<_FakeSmtpServer> start({
    required bool advertiseStartTls,
    bool stallGreeting = false,
    String? stallOnCommand,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeSmtpServer._(
      server,
      advertiseStartTls,
      stallGreeting,
      stallOnCommand,
    );
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    if (!stallGreeting) socket.write('220 fake-smtp ESMTP\r\n');
    var inData = false;
    var buffer = '';

    void handleLine(String line) {
      if (inData) {
        dataLines.add(line);
        if (line == '.') {
          inData = false;
          if (!dataReceived.isCompleted) dataReceived.complete();
          socket.write('250 2.0.0 queued\r\n');
        }
        return;
      }

      commands.add(line);
      if (line == stallOnCommand) return;
      if (line.startsWith('EHLO ')) {
        if (advertiseStartTls) {
          socket.write('250-fake-smtp\r\n250-STARTTLS\r\n250 AUTH LOGIN\r\n');
        } else {
          socket.write('250-fake-smtp\r\n250 AUTH LOGIN\r\n');
        }
      } else if (line == 'DATA') {
        inData = true;
        socket.write('354 end with dot\r\n');
      } else if (line == 'QUIT') {
        socket.write('221 2.0.0 bye\r\n');
      } else if (line.startsWith('MAIL FROM:')) {
        socket.write('250 sender ok\r\n');
      } else if (line.startsWith('RCPT TO:')) {
        socket.write('250 recipient ok\r\n');
      }
    }

    _clientSubscriptions.add(socket.listen((bytes) {
      final chunk = utf8.decode(bytes);
      wire.write(chunk);
      buffer += chunk;
      var boundary = buffer.indexOf('\r\n');
      while (boundary >= 0) {
        final line = buffer.substring(0, boundary);
        buffer = buffer.substring(boundary + 2);
        handleLine(line);
        boundary = buffer.indexOf('\r\n');
      }
    }));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await server.close();
    for (final subscription in _clientSubscriptions) {
      await subscription.cancel();
    }
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}

void main() {
  test('refuses STARTTLS downgrade before sending envelope commands', () async {
    final smtp = await _FakeSmtpServer.start(advertiseStartTls: false);
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      port: smtp.port,
      defaultTo: 'user@example.com',
      useStartTls: true,
    );

    try {
      await expectLater(
        gateway.send(
          const OutboundMessage(sessionKey: 'email:test', text: 'hi'),
        ).timeout(const Duration(seconds: 3)),
        throwsA(isA<StateError>()),
      );
      expect(smtp.commands, contains('EHLO agent-dart'));
      expect(
        smtp.commands.where((line) => line.startsWith('MAIL FROM:')),
        isEmpty,
      );
      expect(smtp.commands, isNot(contains('DATA')));
    } finally {
      await gateway.close();
      await smtp.close();
    }
  });

  test('writes SMTP DATA with CRLF and dot-stuffs all body lines', () async {
    final smtp = await _FakeSmtpServer.start(advertiseStartTls: false);
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      port: smtp.port,
      defaultTo: 'user@example.com',
    );

    try {
      await gateway.send(const OutboundMessage(
        sessionKey: 'email:test',
        text: '.first\nnormal\r\n.second',
        meta: {'subject': 'safe subject'},
      )).timeout(const Duration(seconds: 3));
      await smtp.dataReceived.future.timeout(const Duration(seconds: 2));
      expect(smtp.dataLines, contains('..first'));
      expect(smtp.dataLines, contains('..second'));
      expect(smtp.dataLines, contains('normal'));
      expect(smtp.dataLines.last, '.');
      expect(
        smtp.wire.toString(),
        contains('\r\n..first\r\nnormal\r\n..second\r\n.\r\n'),
      );
      expect(smtp.commands, contains('MAIL FROM:<agent@example.com>'));
      expect(smtp.commands, contains('RCPT TO:<user@example.com>'));
    } finally {
      await gateway.close();
      await smtp.close();
    }
  });

  test('rejects SMTP header and command injection before connecting', () async {
    final smtp = await _FakeSmtpServer.start(advertiseStartTls: false);
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      port: smtp.port,
      defaultTo: 'user@example.com\r\nDATA',
    );

    try {
      await expectLater(
        gateway.send(
          const OutboundMessage(sessionKey: 'email:test', text: 'hi'),
        ).timeout(const Duration(seconds: 3)),
        throwsA(isA<ArgumentError>()),
      );
      expect(smtp.commands, isEmpty);

      final subjectGateway = EmailGateway(
        from: 'agent@example.com',
        host: '127.0.0.1',
        port: smtp.port,
        defaultTo: 'user@example.com',
      );
      await expectLater(
        subjectGateway.send(const OutboundMessage(
          sessionKey: 'email:test',
          text: 'hi',
          meta: {'subject': 'hello\r\nBcc: attacker@example.net'},
        )).timeout(const Duration(seconds: 3)),
        throwsA(isA<ArgumentError>()),
      );
      expect(smtp.commands, isEmpty);
      await subjectGateway.close();
    } finally {
      await gateway.close();
      await smtp.close();
    }
  });


  test('SMTP response timeout aborts a relay that stalls on greeting', () async {
    final smtp = await _FakeSmtpServer.start(
      advertiseStartTls: false,
      stallGreeting: true,
    );
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      port: smtp.port,
      defaultTo: 'user@example.com',
      responseTimeout: const Duration(milliseconds: 120),
      transactionTimeout: const Duration(seconds: 2),
    );
    try {
      await expectLater(
        gateway.send(
          const OutboundMessage(sessionKey: 'email:test', text: 'hi'),
        ),
        throwsA(isA<TimeoutException>()),
      ).timeout(const Duration(seconds: 2));
    } finally {
      await gateway.close();
      await smtp.close();
    }
  });

  test('SMTP response timeout applies after a command, not only greeting', () async {
    final smtp = await _FakeSmtpServer.start(
      advertiseStartTls: false,
      stallOnCommand: 'MAIL FROM:<agent@example.com>',
    );
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      port: smtp.port,
      defaultTo: 'user@example.com',
      responseTimeout: const Duration(milliseconds: 120),
      transactionTimeout: const Duration(seconds: 2),
    );
    try {
      await expectLater(
        gateway.send(
          const OutboundMessage(sessionKey: 'email:test', text: 'hi'),
        ),
        throwsA(isA<TimeoutException>()),
      ).timeout(const Duration(seconds: 2));
      expect(smtp.commands, contains('MAIL FROM:<agent@example.com>'));
      expect(smtp.commands, isNot(contains('RCPT TO:<user@example.com>')));
    } finally {
      await gateway.close();
      await smtp.close();
    }
  });

  test('SMTP authentication is not allowed without STARTTLS', () async {
    final gateway = EmailGateway(
      from: 'agent@example.com',
      host: '127.0.0.1',
      defaultTo: 'user@example.com',
      username: 'relay-user',
      password: 'secret',
    );
    try {
      await expectLater(
        gateway.send(
          const OutboundMessage(sessionKey: 'email:test', text: 'hi'),
        ).timeout(const Duration(seconds: 3)),
        throwsA(isA<StateError>()),
      );
    } finally {
      await gateway.close();
    }
  });
}
