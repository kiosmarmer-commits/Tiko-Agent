// Hermes fase-19: background review (`agent/background_review.py`) — review
// latar pasca turn kasar via satu panggilan LLM aux + verdict JSON terbatas.
import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.text);
  final String text;
  @override
  String get id => 'scripted';
  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);
  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (text.isNotEmpty) yield LlmTextDelta(text);
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

BackgroundReviewEngine _engine(
  _ScriptedLlm llm,
  EventBus bus, {
  ReviewConfig config = const ReviewConfig(enabled: true),
  DateTime Function()? clock,
}) =>
    BackgroundReviewEngine(
      config: config,
      events: bus,
      auxiliaryLlm: () => llm,
      transcriptOf: (sid) async => [
        const ChatMessage(role: 'user', content: 'tolong kerjakan tugas A'),
        const ChatMessage(role: 'assistant', content: 'saya sudah gagal tiga kali'),
      ],
      clock: clock,
    );

void main() {
  test('noteTurnEnd: turn sukses & sedikit tool call tidak memicu review',
      () async {
    final bus = EventBus();
    final llm = _ScriptedLlm('{"nothing_to_save": true}');
    final eng = _engine(llm, bus);
    addTearDown(eng.close);
    addTearDown(bus.close);
    eng.noteTurnEnd('s1', success: true, toolCalls: 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bus.recent().where((e) => e['type'] == 'review.completed'), isEmpty);
  });

  test('turn kasar: review terjadwal setelah idle delay', () async {
    final bus = EventBus();
    final llm = _ScriptedLlm(
      '{"nothing_to_save": false, "memory": [{"action": "add", '
      '"content": "user suka jawaban ringkas"}], "skills": []}',
    );
    final eng = _engine(
      llm,
      bus,
      config: const ReviewConfig(idleDelaySec: 0, minMessages: 2),
    );
    addTearDown(eng.close);
    addTearDown(bus.close);
    eng.noteTurnEnd('s1', success: false, toolCalls: 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ev = [
      ...bus.recent().where((e) => e['type'] == 'review.completed'),
    ];
    expect(ev, hasLength(1));
    final outcome = eng.lastOutcome('s1');
    expect(outcome, isNotNull);
    expect(outcome!['nothing_to_save'], isFalse);
    expect((outcome['memory_ops'] as List), hasLength(1));
  });

  test('cooldown: review kedua dalam jendela cooldown diabaikan', () async {
    final bus = EventBus();
    final llm = _ScriptedLlm('{"nothing_to_save": true}');
    var now = DateTime.utc(2026, 1, 1, 12);
    final eng = _engine(
      llm,
      bus,
      config: const ReviewConfig(idleDelaySec: 0, cooldownSec: 300, minMessages: 2),
      clock: () => now,
    );
    addTearDown(eng.close);
    addTearDown(bus.close);
    eng.noteTurnEnd('s1', success: false, toolCalls: 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(eng.lastOutcome('s1'), isNotNull);
    now = now.add(const Duration(seconds: 10));
    eng.noteTurnEnd('s1', success: false, toolCalls: 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      bus.recent().where((e) => e['type'] == 'review.completed'),
      hasLength(1),
    );
  });

  test('jawaban provider error/tak-valid: event review.failed', () async {
    final bus = EventBus();
    final llm = _ScriptedLlm('maaf, saya tidak bisa meninjau apa pun di sini.');
    final eng = _engine(llm, bus, config: const ReviewConfig(idleDelaySec: 0, minMessages: 2));
    addTearDown(eng.close);
    addTearDown(bus.close);
    eng.noteTurnEnd('s1', success: false, toolCalls: 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      bus.recent().where((e) => e['type'] == 'review.failed'),
      hasLength(1),
    );
  });

  test('parseReviewVerdict: JSON di antara prosa diambil, ops dibatasi', () {
    final at = DateTime.utc(2026, 1, 1);
    final text = 'Berikut tinjauannya.\n{"nothing_to_save": false, '
        '"memory": ['
        '{"action": "add", "content": "a"},'
        '{"action": "junk"},'
        '{"action": "remove", "old_text": "b"}'
        '], "skills": ['
        '{"action": "patch", "name": "deploy-web", "content": "x"}'
        ']} Terima kasih.';
    final out = parseReviewVerdict('s1', text, at);
    expect(out, isNotNull);
    expect(out!.nothingToSave, isFalse);
    expect(out.memoryOps, hasLength(2));
    expect(out.skillOps, hasLength(1));
    expect(out.skillOps.single['name'], 'deploy-web');
    expect(parseReviewVerdict('s1', 'bukan json sama sekali', at), isNull);
    expect(parseReviewVerdict('s1', '{"nothing_to_save": true}', at)!
        .nothingToSave, isTrue);
  });

  test('prompt memuat transcript dan bias aktif', () {
    final p = buildBackgroundReviewPrompt(const [
      ChatMessage(role: 'user', content: 'halo dunia'),
      ChatMessage(role: 'assistant', content: 'hai!'),
    ]);
    expect(p, contains('user: halo dunia'));
    expect(p, contains('assistant: hai!'));
    expect(p, contains('nothing_to_save'));
  });
}
