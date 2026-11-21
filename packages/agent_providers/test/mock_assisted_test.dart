import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

Future<List<LlmEvent>> _collect(Stream<LlmEvent> stream) async =>
    stream.toList();

ChatRequest _req(List<ChatMessage> messages, {List<String> tools = const []}) =>
    ChatRequest(
      messages: messages,
      tools: [
        for (final name in tools)
          ToolSpec(name: name, description: name, inputSchema: const {}),
      ],
    );

LlmToolCall _toolCallOf(List<LlmEvent> events) =>
    events.whereType<LlmToolCall>().single;

String? _finishReasonOf(List<LlmEvent> events) =>
    events.whereType<LlmDone>().first.finishReason;

void main() {
  group('MockScenario.assisted (default runtime mock)', () {
    test('sapaan mendapat balasan bantuan kontekstual', () async {
      final events = await _collect(MockLlmProvider(scenario: MockScenario.assisted)
          .chat(_req([const ChatMessage(role: 'user', content: 'halo')])));
      final text = events
          .whereType<LlmTextDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, contains('Halo! Saya mock agent'));
      expect(text, contains('hitung 25*4'));
      expect(_finishReasonOf(events), 'stop');
    });

    test('pertanyaan identitas menjelaskan status mock', () async {
      final events = await _collect(MockLlmProvider(scenario: MockScenario.assisted)
          .chat(_req(
              [const ChatMessage(role: 'user', content: 'kamu siapa?')])));
      final text = events
          .whereType<LlmTextDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, contains('mock'));
      expect(text, contains('deterministik'));
    });

    test('pertanyaan hitung memanggil tool calc', () async {
      final events = await _collect(MockLlmProvider(scenario: MockScenario.assisted)
          .chat(_req(
        [const ChatMessage(role: 'user', content: 'hitung 25*4')],
        tools: ['calc', 'datetime'],
      )));
      final call = _toolCallOf(events);
      expect(call.call.name, 'calc');
      expect(call.call.args['expression'], '25*4');
      expect(_finishReasonOf(events), 'tool_calls');
    });

    test('setelah tool calc, hasil dirangkum balasan final', () async {
      final provider = MockLlmProvider(scenario: MockScenario.assisted);
      await _collect(provider.chat(_req(
        [const ChatMessage(role: 'user', content: 'hitung 25*4')],
        tools: ['calc'],
      )));
      final events = await _collect(provider.chat(_req([
        const ChatMessage(role: 'user', content: 'hitung 25*4'),
        const ChatMessage(role: 'tool', content: '100', toolCallId: 'call_mock_calc_1'),
      ], tools: ['calc'])));
      final text = events
          .whereType<LlmTextDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, contains('100'));
      expect(_finishReasonOf(events), 'stop');
    });

    test('pertanyaan waktu memanggil tool datetime bila tersedia', () async {
      final events = await _collect(MockLlmProvider(scenario: MockScenario.assisted)
          .chat(_req(
        [const ChatMessage(role: 'user', content: 'jam berapa sekarang?')],
        tools: ['datetime'],
      )));
      expect(_toolCallOf(events).call.name, 'datetime');
    });

    test('tanpa tool, pertanyaan umum tetap dijawab kontekstual', () async {
      final events = await _collect(MockLlmProvider(scenario: MockScenario.assisted)
          .chat(_req(
        [const ChatMessage(role: 'user', content: 'jelaskan arsitektur tiko')],
        tools: const [],
      )));
      final text = events
          .whereType<LlmTextDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, contains('mock agent'));
      expect(text, contains('jelaskan arsitektur tiko'));
    });
  });

  group('MockScenario.plain (balasan lama tetap)', () {
    test('plain tidak berubah', () async {
      final events = await _collect(
          MockLlmProvider().chat(_req([const ChatMessage(role: 'user', content: 'x')])));
      final text = events
          .whereType<LlmTextDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, 'Halo! Saya mock agent. Siap membantu.');
    });
  });
}
