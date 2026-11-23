import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String path;

  setUp(() async {
    temp =
        await Directory.systemTemp.createTemp('tiko_approval_rules_');
    path = '${temp.path}/approval_rules.json';
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });



  test('remember workspace persist + matches saat load ulang', () async {
    var rules = ApprovalRules(persistPath: path);
    await rules.remember(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'flutter test'}),
      scope: 'workspace',
    );
    expect(await File(path).exists(), isTrue);

    rules = ApprovalRules(persistPath: path);
    await rules.load();
    expect(
      rules.matches(
        const ToolCall(
          id: '2',
          name: 'shell',
          args: {'cmd': 'flutter test packages/foo'},
        ),
        sessionId: 's9',
      ),
      isTrue,
    );
  });

  test('prefix shell spesifik: perintah berbeda tidak cocok', () async {
    final rules = ApprovalRules(persistPath: path);
    await rules.remember(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'flutter test'}),
      scope: 'workspace',
    );
    expect(
      rules.matches(
        const ToolCall(id: '2', name: 'shell', args: {'cmd': 'flutter clean'}),
      ),
      isFalse,
    );
  });

  test('rule session hanya cocok di session yang sama', () async {
    final rules = ApprovalRules(persistPath: path);
    await rules.remember(
      const ToolCall(id: '1', name: 'http_request', args: {}),
      scope: 'session',
      sessionId: 's1',
    );
    expect(
      rules.matches(
        const ToolCall(id: '2', name: 'http_request', args: {}),
        sessionId: 's1',
      ),
      isTrue,
    );
    expect(
      rules.matches(
        const ToolCall(id: '3', name: 'http_request', args: {}),
        sessionId: 's2',
      ),
      isFalse,
    );
  });

  test('rule session TIDAK dipersist ke disk', () async {
    final rules = ApprovalRules(persistPath: path);
    await rules.remember(
      const ToolCall(id: '1', name: 'http_request', args: {}),
      scope: 'session',
      sessionId: 's1',
    );
    final raw = await File(path).exists()
        ? await File(path).readAsString()
        : '[]';
    final decoded = jsonDecode(raw) as List<dynamic>;
    expect(decoded, isEmpty);
  });

  test('file korup -> mulai kosong (fail-soft)', () async {
    await File(path).writeAsString('{not json');
    final rules = ApprovalRules(persistPath: path);
    await rules.load();
    expect(rules.matches(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'ls'}),
    ), isFalse);
  });

  test('entri korup dilompati, entri valid tetap dimuat', () async {
    await File(path).writeAsString('''
[
  {"tool": "shell", "scope": "workspace", "cmd_prefix": "dart test", "created_at": "2025-01-01T00:00:00.000Z"},
  {"tool": "shell", "scope": "nonsense", "created_at": "2025-01-01T00:00:00.000Z"},
  {"tool": "kill", "scope": "workspace", "cmd_prefix": "kill", "created_at": "2025-01-01T00:00:00.000Z"}
]
''');
    final rules = ApprovalRules(persistPath: path);
    await rules.load();
    expect(rules.matches(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'dart test x'}),
    ), isTrue);
    expect(rules.list().length, 2);
  });
}
