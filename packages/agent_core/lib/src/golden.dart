import 'dart:io';

import 'package:yaml/yaml.dart';

import 'models.dart';
import 'agent_loop.dart';

class GoldenTask {
  GoldenTask({
    required this.id,
    required this.input,
    this.allowedTools = const [],
    this.mustCallTools = const [],
    this.answerContains = const [],
    this.answerRegex,
    this.weight = 1.0,
    this.category = 'general',
  });

  final String id;
  final String input;
  final List<String> allowedTools;
  final List<String> mustCallTools;
  final List<String> answerContains;
  final String? answerRegex;
  final double weight;
  final String category;
}

class GoldenResult {
  GoldenResult({
    required this.taskId,
    required this.passed,
    required this.score,
    this.detail = '',
    this.answer = '',
    this.toolsCalled = const [],
  });

  final String taskId;
  final bool passed;
  final double score;
  final String detail;
  final String answer;
  final List<String> toolsCalled;
}

/// Strict YAML loader for golden task files.
///
/// Accepts either a top-level list or `{tasks: [...]}`. Invalid or ambiguous
/// fixtures throw instead of silently dropping assertions.
List<GoldenTask> loadGoldenYaml(String path) {
  final source = File(path).readAsStringSync();
  final decoded = loadYaml(source, sourceUrl: Uri.file(path));
  final Object? rawTasks;
  if (decoded is YamlList || decoded is List) {
    rawTasks = decoded;
  } else if (decoded is YamlMap || decoded is Map) {
    final map = Map<Object?, Object?>.from(decoded as Map);
    rawTasks = map['tasks'];
  } else {
    throw const FormatException('golden YAML must be a list or contain tasks: [...]');
  }
  if (rawTasks is! List || rawTasks.isEmpty || rawTasks.length > 500) {
    throw const FormatException('golden tasks must contain 1..500 items');
  }

  final ids = <String>{};
  final tasks = <GoldenTask>[];
  for (var index = 0; index < rawTasks.length; index++) {
    final value = rawTasks[index];
    if (value is! Map) {
      throw FormatException('golden task #${index + 1} must be a mapping');
    }
    final row = Map<Object?, Object?>.from(value);
    final id = row['id'];
    final input = row['input'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$').hasMatch(id)) {
      throw FormatException('golden task #${index + 1} has an invalid id');
    }
    if (!ids.add(id)) throw FormatException('duplicate golden task id: $id');
    if (input is! String || input.trim().isEmpty || input.length > 10000) {
      throw FormatException('golden task $id has invalid input');
    }
    final category = row['category'] ?? 'general';
    if (category is! String || category.trim().isEmpty || category.length > 64) {
      throw FormatException('golden task $id has invalid category');
    }
    final weightValue = row['weight'] ?? 1;
    if (weightValue is! num || !weightValue.isFinite || weightValue <= 0 || weightValue > 100) {
      throw FormatException('golden task $id weight must be > 0 and <= 100');
    }
    final answerRegex = row['answer_regex'];
    if (answerRegex != null &&
        (answerRegex is! String || answerRegex.isEmpty || answerRegex.length > 512)) {
      throw FormatException('golden task $id answer_regex is invalid');
    }

    tasks.add(GoldenTask(
      id: id,
      input: input,
      category: category,
      weight: weightValue.toDouble(),
      mustCallTools: _stringList(row['must_call'], 'must_call', id),
      answerContains: _stringList(row['answer_contains'], 'answer_contains', id),
      allowedTools: _stringList(row['allowed_tools'], 'allowed_tools', id),
      answerRegex: answerRegex as String?,
    ));
  }
  return List.unmodifiable(tasks);
}

List<String> _stringList(Object? value, String field, String id) {
  if (value == null) return const [];
  if (value is! List || value.length > 128) {
    throw FormatException('golden task $id $field must be a list of at most 128 strings');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String || item.trim().isEmpty || item.length > 256) {
      throw FormatException('golden task $id $field contains an invalid value');
    }
    result.add(item.trim());
  }
  if (result.toSet().length != result.length) {
    throw FormatException('golden task $id $field contains duplicates');
  }
  return List.unmodifiable(result);
}

class GoldenHarness {
  GoldenHarness({required this.loopFactory});

  final Future<
    ({
      AgentLoop loop,
      Session session,
      List<String> replies,
      List<String> tools,
    })
  >
  Function()
  loopFactory;

  Future<List<GoldenResult>> run(List<GoldenTask> tasks) async {
    final results = <GoldenResult>[];
    for (final task in tasks) {
      final pack = await loopFactory();
      await pack.loop.handle(
        InboundMessage(
          channel: 'eval',
          userKey: 'eval',
          sessionKey: 'eval:${task.id}',
          text: task.input,
        ),
        pack.session,
      );
      final answer = pack.replies.isEmpty ? '' : pack.replies.last;
      final toolsCalled = List<String>.from(pack.loop.executedToolNames);
      var ok = true;
      final details = <String>[];
      for (final c in task.answerContains) {
        if (!answer.toLowerCase().contains(c.toLowerCase())) {
          ok = false;
          details.add('missing: $c');
        }
      }
      for (final t in task.mustCallTools) {
        if (!toolsCalled.contains(t)) {
          ok = false;
          details.add('required tool not executed: $t');
        }
      }
      if (task.allowedTools.isNotEmpty) {
        final unexpected = toolsCalled.where((t) => !task.allowedTools.contains(t)).toList();
        if (unexpected.isNotEmpty) {
          ok = false;
          details.add('unexpected tools executed: ${unexpected.join(', ')}');
        }
      }
      final pattern = task.answerRegex;
      if (pattern != null && pattern.isNotEmpty) {
        try {
          if (!RegExp(pattern, caseSensitive: false).hasMatch(answer)) {
            ok = false;
            details.add('answer regex did not match: $pattern');
          }
        } catch (_) {
          ok = false;
          details.add('invalid answer regex: $pattern');
        }
      }
      results.add(
        GoldenResult(
          taskId: task.id,
          passed: ok,
          score: ok ? task.weight : 0,
          detail: details.join('; '),
          answer: answer,
          toolsCalled: toolsCalled,
        ),
      );
    }
    return results;
  }

  static double totalScore(List<GoldenResult> results) =>
      results.fold<double>(0, (s, r) => s + r.score);

  /// Regression rule: reject if total drops > 2 points or any security task fails.
  static bool regressionOk(
    List<GoldenResult> baseline,
    List<GoldenResult> current,
  ) {
    final base = totalScore(baseline);
    final cur = totalScore(current);
    if (cur < base - 2) return false;
    for (final r in current) {
      if (r.taskId.startsWith('sec-') && !r.passed) return false;
    }
    return true;
  }
}
