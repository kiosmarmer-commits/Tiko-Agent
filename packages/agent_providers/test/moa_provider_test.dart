import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

class _FixedProvider implements LlmProvider {
  _FixedProvider(this.id_, this.answer, {this.shouldThrow = false});

  final String id_;
  final String answer;
  final bool shouldThrow;

  @override
  String get id => id_;

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: true);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (shouldThrow) throw StateError('down');
    yield LlmTextDelta(answer);
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [1.0];
}

class _RecordingRanker implements LlmProvider {
  _RecordingRanker(this.answer);

  final String answer;
  ChatRequest? lastRequest;

  @override
  String get id => 'ranker';

  @override
  Capabilities get capabilities => const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    lastRequest = req;
    yield LlmTextDelta(answer);
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

Future<String> _collect(MoaProvider moa, ChatRequest req) async {
  final buf = StringBuffer();
  await for (final e in moa.chat(req)) {
    if (e is LlmTextDelta) buf.write(e.delta);
  }
  return buf.toString();
}

void main() {
  const req = ChatRequest(
    messages: [ChatMessage(role: 'user', content: 'halo')],
    stream: true,
  );

  group('MoaProvider (R3 ensemble)', () {
    test('majority: jawaban identik dua member dipakai ketimbang outlier', () async {
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', 'Jawaban benar'),
          _FixedProvider('b', 'jawaban benar '),
          _FixedProvider('c', 'Jawaban salah total'),
        ],
      );
      expect(await _collect(moa, req), 'Jawaban benar');
    });

    test('semua jawaban unik: fallback ke member pertama yang sukses', () async {
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', 'A'),
          _FixedProvider('b', 'B'),
        ],
      );
      expect(await _collect(moa, req), 'A');
    });

    test('member gagal di-skip; semua gagal fail-closed MoaError', () async {
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', '', shouldThrow: true),
          _FixedProvider('b', 'OK'),
        ],
      );
      expect(await _collect(moa, req), 'OK');

      final allDown = MoaProvider(members: [_FixedProvider('a', '', shouldThrow: true)]);
      await expectLater(_collect(allDown, req), throwsA(isA<MoaError>()));
    });

    test('usage agregat berjumlah token seluruh member', () async {
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', 'sama'),
          _FixedProvider('b', 'SAMA'),
        ],
      );
      TokenUsage? seen;
      await for (final e in moa.chat(req)) {
        if (e is LlmUsage) seen = e.usage;
      }
      expect(seen, isNull, reason: 'fake member tidak mengirim LlmUsage');
    });

    test('usageSink menerima snapshot hasil termasuk yang gagal', () async {
      final snapshots = <List<MoaAgentResult>>[];
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', 'sama'),
          _FixedProvider('b', '', shouldThrow: true),
        ],
        usageSink: snapshots.add,
      );
      await _collect(moa, req);
      expect(snapshots, hasLength(1));
      expect(snapshots.first, hasLength(2));
      expect(snapshots.first.first.ok, isTrue);
      expect(snapshots.first.last.ok, isFalse);
    });

    test('ranker menyusun jawaban final dari proposal', () async {
      final ranker = _RecordingRanker('SINTESIS FINAL');
      final moa = MoaProvider(
        members: [_FixedProvider('a', 'proposal a'), _FixedProvider('b', 'proposal b')],
        ranker: ranker,
        strategy: MoaStrategy.ranker,
      );
      final out = await _collect(moa, req);
      expect(out, 'SINTESIS FINAL');
      expect(ranker.lastRequest!.messages.last.content, contains('proposal a'));
      expect(ranker.lastRequest!.messages.last.content, contains('proposal b'));
    });

    test('ranker gagal automatis fallback ke majority', () async {
      final ranker = _FixedProvider('ranker', '', shouldThrow: true);
      final moa = MoaProvider(
        members: [
          _FixedProvider('a', 'konsensus'),
          _FixedProvider('b', 'KONSENSUS'),
        ],
        ranker: ranker,
        strategy: MoaStrategy.ranker,
      );
      expect(await _collect(moa, req), 'konsensus');
    });

    test('id menampilkan hingga 3 member', () {
      final moa3 = MoaProvider(
        members: [_FixedProvider('a', 'x'), _FixedProvider('b', 'x'), _FixedProvider('c', 'x')],
      );
      final moa4 = MoaProvider(
        members: [
          _FixedProvider('a', 'x'),
          _FixedProvider('b', 'x'),
          _FixedProvider('c', 'x'),
          _FixedProvider('d', 'x'),
        ],
      );
      expect(moa3.id, 'moa(a+b+c)');
      expect(moa4.id, contains('+1 lagi)'));
    });
  });
}
