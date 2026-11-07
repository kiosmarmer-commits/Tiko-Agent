import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Simple CLI gateway (TASK-05-01 complete path).
class CliGateway implements Gateway {
  CliGateway({this.userKey = 'local'});

  final String userKey;
  final _controller = StreamController<InboundMessage>.broadcast();
  bool _running = false;

  @override
  String get channel => 'cli';

  @override
  Stream<InboundMessage> get inbound => _controller.stream;

  @override
  Future<void> send(OutboundMessage m) async {
    stdout.writeln('\nassistant> ${m.text}');
    if (m.buttons.isNotEmpty) {
      for (final b in m.buttons) {
        stdout.writeln('  [${b.id}] ${b.label}');
      }
    }
    stdout.writeln('');
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // no-op on CLI
  }

  /// Blocking read loop — call from main.
  Future<void> runRepl({void Function(String cmd)? onCommand}) async {
    _running = true;
    stdout.writeln('CLI gateway ready. /quit to exit.');
    while (_running) {
      stdout.write('you> ');
      final line = stdin.readLineSync();
      if (line == null) break;
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text == '/quit' || text == '/exit') {
        _running = false;
        break;
      }
      if (text.startsWith('/') && onCommand != null) {
        onCommand(text);
        continue;
      }
      _controller.add(
        InboundMessage(
          channel: channel,
          userKey: userKey,
          sessionKey: 'cli:$userKey',
          text: text,
        ),
      );
    }
  }


  @override

  Future<void> close() async {
    _running = false;
    await _controller.close();
  }
}
