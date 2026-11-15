import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args.first : 'normal';
  final stdinLines =
      stdin.transform(utf8.decoder).transform(const LineSplitter());

  await for (final line in stdinLines) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      stdout.writeln(jsonEncode({'ok': false, 'error': 'bad json'}));
      continue;
    }
    final op = msg['op'] as String?;
    if (op == 'hello') {
      stdout.writeln(jsonEncode({'ok': true}));
    } else if (op == 'hook') {
      final hook = msg['hook'] as String?;
      if (mode == 'crash' && hook == 'afterToolCall') {
        exit(2);
      }
      if (mode == 'hang' && hook == 'beforeToolCall') {
        continue;
      }
      if (hook == 'beforeToolCall') {
        final input = msg['input'] as Map<String, dynamic>?;
        final tool = input?['tool'] as String?;
        if (tool == 'shell') {
          stdout.writeln(jsonEncode({
            'verdict': 'deny',
            'reason': 'shell diblokir plugin contoh',
          }));
        } else {
          stdout.writeln(jsonEncode({'verdict': 'allow'}));
        }
      } else {
        stdout.writeln(jsonEncode({'ok': true}));
      }
    } else {
      stdout.writeln(jsonEncode({'ok': false, 'error': 'unknown op'}));
    }
  }
}
