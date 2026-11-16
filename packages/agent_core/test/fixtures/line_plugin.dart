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
    } else if (op == 'listTools') {
      if (mode == 'tools') {
        stdout.writeln(jsonEncode({
          'ok': true,
          'tools': [
            {
              'name': 'echo_tool',
              'description': 'tool contoh dari plugin',
              'input_schema': {
                'type': 'object',
                'properties': {'input': {'type': 'string'}},
              },
              'risk': 'medium',
            },
            {'name': 'Invalid-Name'},
          ],
        }));
      } else {
        stdout.writeln(jsonEncode({'ok': true, 'tools': []}));
      }
    } else if (op == 'toolCall') {
      final tool = msg['tool'] as String?;
      final args = msg['args'] as Map<String, dynamic>? ?? {};
      if (tool == 'echo_tool') {
        stdout.writeln(jsonEncode({
          'ok': true,
          'result': 'echo: ${args['input']}',
          'is_error': false,
        }));
      } else {
        stdout.writeln(jsonEncode({'ok': false, 'error': 'tool tidak dikenal'}));
      }
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
