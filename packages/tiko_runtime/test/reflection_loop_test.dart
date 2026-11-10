import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

ConversationTurn turn(
  String user, {
  bool success = true,
  List<String> tools = const [],
}) =>
    ConversationTurn(
      userMessage: user,
      assistantMessage: 'ok',
      isSuccessful: success,
      toolCalls: [
        for (var i = 0; i < tools.length; i++)
          ToolCall(id: 'c$i', name: tools[i], args: const {}),
      ],
    );

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);

  group('ReflectionEngine', () {
    ReflectionEngine engine(String path) =>
        ReflectionEngine(storePath: path);

    test('failed turn produces a corrective lesson', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      final result = e.reflect(
        turns: [
          turn('deploy ke server gagal', success: false, tools: ['shell']),
          turn('coba lagi', tools: ['shell']),
        ],
        sessionId: 's1',
        now: now,
      );
      expect(result.newLessons, hasLength(1));
      final lesson = result.newLessons.single;
      expect(lesson.isSuccessful, isFalse);
      expect(lesson.insight, contains('shell'));
      expect(lesson.action, contains('verifikasi argumen tool'));
      await dir.delete(recursive: true);
    });

    test('successful multi-tool trajectory produces positive lesson',
        () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      final result = e.reflect(
        turns: [
          turn('ringkas artikel', tools: ['web_fetch']),
          turn('simpan ringkasan', tools: ['memory_write']),
        ],
        sessionId: 's2',
        now: now,
      );
      expect(result.newLessons, hasLength(1));
      expect(result.newLessons.single.isSuccessful, isTrue);
      expect(result.newLessons.single.insight, contains('web_fetch'));
      await dir.delete(recursive: true);
    });

    test('similar triggers reinforce instead of duplicating', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      e.reflect(
        turns: [turn('deploy gagal lagi', success: false),
            turn('retry', tools: ['shell'])],
        sessionId: 's1',
        now: now,
      );
      final before = e.length;
      final result = e.reflect(
        turns: [turn('deploy gagal lagi', success: false),
            turn('retry', tools: ['shell'])],
        sessionId: 's2',
        now: now,
      );
      expect(result.newLessons, isEmpty);
      expect(result.reinforcedIds, hasLength(1));
      expect(e.length, before);
      expect(e.all.first.timesReinforced, 1);
      await dir.delete(recursive: true);
    });

    test('too few turns yields no lessons', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      final result = e.reflect(
        turns: [turn('halo')],
        sessionId: 's3',
        now: now,
      );
      expect(result.isEmpty, isTrue);
      expect(e.length, 0);
      await dir.delete(recursive: true);
    });

    test('relevantLessons ranks matching lessons first', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      e.reflect(
        turns: [turn('deploy ke server gagal', success: false),
            turn('retry', tools: ['shell'])],
        sessionId: 's1',
        now: now,
      );
      e.reflect(
        turns: [turn('resep masakan error', success: false),
            turn('coba', tools: ['web_search'])],
        sessionId: 's2',
        now: now,
      );
      final hits = e.relevantLessons('deploy server', k: 1);
      expect(hits, hasLength(1));
      expect(hits.single.trigger, contains('deploy'));
      await dir.delete(recursive: true);
    });

    test('buildContextPrompt injects matching lessons', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final e = engine('${dir.path}/lessons.json');
      await e.load();
      e.reflect(
        turns: [turn('deploy ke server gagal', success: false),
            turn('retry', tools: ['shell'])],
        sessionId: 's1',
        now: now,
      );
      final prompt = e.buildContextPrompt('deploy server');
      expect(prompt, contains('Pelajaran dari pengalaman sebelumnya'));
      expect(prompt, contains('deploy'));
      expect(e.buildContextPrompt('topik tak terkait xyz'), isEmpty);
      await dir.delete(recursive: true);
    });

    test('save and load round trip', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_reflect');
      final path = '${dir.path}/lessons.json';
      final e = engine(path);
      await e.load();
      e.reflect(
        turns: [turn('build gagal', success: false), turn('retry')],
        sessionId: 's1',
        now: now,
      );
      await e.save();

      final restored = engine(path);
      await restored.load();
      expect(restored.length, 1);
      expect(restored.all.first.trigger, contains('build gagal'));
      await dir.delete(recursive: true);
    });
  });
}
