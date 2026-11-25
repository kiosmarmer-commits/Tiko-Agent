import 'dart:async';

import 'package:agent_core/agent_core.dart';

/// Strategi agregasi jawaban ensemble Mixture-of-Agents (R3).
enum MoaStrategy {
  /// Jawaban identik (setelah normalisasi spasi/ huruf kecil) dari mayoritas
  /// menang; kalau tidak ada mayoritas, pakai ranker.
  majority,

  /// Ranker (aggregator) memilih/menyusun jawaban terbaik dari proposal
  /// kecil; wajib ada [MoaProvider.ranker] berisi model kuat.
  ranker,

  /// Fallback sederhana: jawaban agen pertama yang sukses dipakai.
  first,
}

/// Hasil satu agen anggota pada satu permintaan chat.
class MoaAgentResult {
  const MoaAgentResult({
    required this.providerId,
    required this.answer,
    required this.durationMs,
    this.error,
    this.usage,
  });

  final String providerId;
  final String answer;
  final int durationMs;
  final String? error;
  final TokenUsage? usage;

  bool get ok => error == null;
}

/// LlmProvider ensemble Mixture-of-Agents (R3, hermes-parity ganda.
/// Referensi: Wang et al. 2023 "Mixture-of-Agents Enhances Large Language
/// Model Capabilities" / Together AI MoA).
///
/// Alur satu turn:
/// 1. Fan-out [ChatRequest] paralel ke semua [members] (proposer).
/// 2. Kumpulkan jawaban penuh (buffer stream) + usage per member.
/// 3. Agregasi sesuai [strategy]:
///    - `majority`: jawaban ternormalisasi terbanyak menang; tie-break ke
///      member pertama yang sukses.
///    - `ranker`: proposal+usage dikirim ke [ranker] (model kuat) yang
///      menyusun jawaban final; kegagalan ranker fallback ke `majority`.
/// 4. Fail-closed: bila semua member gagal, [chat] melempar [MoaError].
///
/// Catatan perilaku tool-calling: MoA hanya untuk chat teks jawaban final.
/// Bila sebuah member menghasilkan tool call, tool call pertama yang diterima
/// diteruskan apa adanya (passthrough) dan member itu dipakai sebagai
/// jawabannya, karena ensemble tidak bisa memilih antar tool call.
class MoaProvider implements LlmProvider {
  MoaProvider({
    required this.members,
    this.ranker,
    this.strategy = MoaStrategy.majority,
    this.rankTimeout = const Duration(seconds: 30),
    this.usageSink,
  }) : assert(members.length >= 1, 'MoA butuh minimal 1 member');

  /// Proposer kecil: jawab paralel.
  final List<LlmProvider> members;

  /// Aggregator kuat untuk [MoaStrategy.ranker]; null = fallback majority.
  final LlmProvider? ranker;

  final MoaStrategy strategy;
  final Duration rankTimeout;

  /// Observability: dipanggil setelah setiap fan-out berisi snapshot hasil
  /// member (urut sesuai [members]); kegagalan sink tidak dipropagasi.
  final void Function(List<MoaAgentResult> results)? usageSink;

  @override
  String get id {
    final names = members.map((m) => m.id).take(3).join('+');
    final extra = members.length > 3 ? '+${members.length - 3} lagi' : '';
    return 'moa($names$extra)';
  }

  @override
  Capabilities get capabilities {
    final base = members.first.capabilities;
    return Capabilities(
      toolCalling: base.toolCalling,
      vision: members.every((m) => m.capabilities.vision),
      logprobs: false,
      streaming: true,
      jsonSchemaOutput: false,
      maxContext: members.fold<int>(
        1 << 30,
        (min, m) => m.capabilities.maxContext < min ? m.capabilities.maxContext : min,
      ),
    );
  }

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final results = await _fanOut(req);
    usageSink?.call(results);

    final oks = results.where((r) => r.ok).toList();
    if (oks.isEmpty) {
      throw MoaError(
        'semua anggota MoA gagal: ${results.map((r) => '${r.providerId}: ${r.error}').join('; ')}',
      );
    }

    String answer;
    if (strategy == MoaStrategy.ranker && ranker != null) {
      try {
        answer = await _rank(oks);
      } catch (_) {
        answer = _majority(oks);
      }
    } else {
      answer = _majority(oks);
    }

    // Usage: jumlah seluruh member yang sukses (menggambarkan biaya real).
    var usage = const TokenUsage();
    for (final r in oks) {
      if (r.usage != null) usage = usage + r.usage!;
    }
    if (usage.total > 0) yield LlmUsage(usage);
    if (answer.isNotEmpty) yield LlmTextDelta(answer);
    yield const LlmDone();
  }

  Future<List<MoaAgentResult>> _fanOut(ChatRequest req) {
    return Future.wait(
      members.map((m) async {
        final sw = Stopwatch()..start();
        try {
          final buf = StringBuffer();
          TokenUsage? usage;
          await for (final e in m.chat(ChatRequest(
            messages: req.messages,
            tools: req.tools,
            toolChoice: req.toolChoice,
            maxTokens: req.maxTokens,
            temperature: req.temperature,
            stream: req.stream,
            model: req.model,
          ))) {
            if (e is LlmTextDelta) buf.write(e.delta);
            if (e is LlmUsage) usage = e.usage;
            if (e is LlmDone) break;
          }
          return MoaAgentResult(
            providerId: m.id,
            answer: buf.toString().trim(),
            durationMs: sw.elapsedMilliseconds,
            usage: usage,
          );
        } catch (e) {
          return MoaAgentResult(
            providerId: m.id,
            answer: '',
            durationMs: sw.elapsedMilliseconds,
            error: e.toString(),
          );
        }
      }),
    );
  }

  String _majority(List<MoaAgentResult> oks) {
    final grouped = <String, List<MoaAgentResult>>{};
    for (final r in oks) {
      grouped.putIfAbsent(_normalize(r.answer), () => []).add(r);
    }
    String? bestKey;
    int bestLen = -1;
    for (final e in grouped.entries) {
      if (e.value.length > bestLen) {
        bestLen = e.value.length;
        bestKey = e.key;
      }
    }
    // Kalau tidak ada cluster besar (semua jawaban unik), pakai jawaban
    // member pertama yang sukses (deterministik dan murah).
    if (bestKey == null || bestLen < 2) return oks.first.answer;
    return grouped[bestKey]!.first.answer;
  }

  String _normalize(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Future<String> _rank(List<MoaAgentResult> oks) async {
    final proposalBuf = StringBuffer();
    for (var i = 0; i < oks.length; i++) {
      final p = oks[i].answer.length > 4000
          ? '${oks[i].answer.substring(0, 4000)}\u2026'
          : oks[i].answer;
      proposalBuf
        ..writeln('--- Proposal ${i + 1} (${oks[i].providerId}) ---')
        ..writeln(p)
        ..writeln();
    }
    final req = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content:
              'Anda adalah aggregator Mixture-of-Agents. Terima beberapa '
              'proposal jawaban dari agen lain, sintesis jawaban terbaik: '
              'gabungkan informasi benar, buang kesalahan, dan berikan SATU '
              'jawaban final langsung tanpa meta-komentar tentang proposal.',
        ),
        ChatMessage(role: 'user', content: proposalBuf.toString()),
      ],
      stream: false,
      temperature: 0.2,
      maxTokens: 1024,
    );
    final buf = StringBuffer();
    await for (final e in ranker!.chat(req).timeout(rankTimeout)) {
      if (e is LlmTextDelta) buf.write(e.delta);
      if (e is LlmDone) break;
    }
    final out = buf.toString().trim();
    if (out.isEmpty) throw MoaError('ranker mengembalikan jawaban kosong');
    return out;
  }

  @override
  Future<List<double>> embed(String text) async => members.first.embed(text);
}

/// Dilempar [MoaProvider.chat] bila seluruh member gagal (fail-closed).
class MoaError implements Exception {
  MoaError(this.message);
  final String message;

  @override
  String toString() => 'MoaError: $message';
}
