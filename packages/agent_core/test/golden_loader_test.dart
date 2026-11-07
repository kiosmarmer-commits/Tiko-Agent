import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('loads strict golden task YAML including tool and regex assertions', () {
    final dir = Directory.systemTemp.createTempSync('tiko-golden-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/tasks.yaml')..writeAsStringSync(r'''
- id: calc-1
  input: "hitung 2 + 3"
  category: tools
  weight: 2
  must_call: [calc]
  allowed_tools: [calc, datetime]
  answer_contains: ["5"]
  answer_regex: "5"
''');
    final tasks = loadGoldenYaml(file.path);
    expect(tasks, hasLength(1));
    expect(tasks.single.mustCallTools, ['calc']);
    expect(tasks.single.allowedTools, ['calc', 'datetime']);
    expect(tasks.single.answerRegex, '5');
    expect(tasks.single.weight, 2);
  });

  test('rejects duplicate or malformed golden fixtures instead of dropping them', () {
    final dir = Directory.systemTemp.createTempSync('tiko-golden-invalid-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/tasks.yaml')..writeAsStringSync(r'''
- id: duplicate
  input: one
- id: duplicate
  input: two
''');
    expect(() => loadGoldenYaml(file.path), throwsFormatException);
  });
}
