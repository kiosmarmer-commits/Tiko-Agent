import 'dart:async';

import 'package:agent_core/agent_core.dart';

/// Deterministic mock LLM for unit tests and early development (TASK-01-03).
///
/// Scenarios:
/// 1. `plain` — balasan tetap "Halo! Saya mock agent. Siap membantu." (dipakai
///    unit test yang mengunci teks).
/// 2. `assisted` — default runtime: jawaban kontekstual deterministik. Bila
///    pertanyaan berbentuk hitungan/pertanyaan waktu dan tool calc/datetime
///    tersedia, mock memanggil tool lalu merangkum hasilnya; selain itu pilih
///    balasan bantuan sesuai temanya (sapaan, identitas, cara setting provider).
///    Membuat percobaan tanpa LLM sungguhan tetap interaktif.
/// 3. Single tool call then final answer.
/// 4. Multi-step tool calling (loop of 2).
class MockLlmProvider implements LlmProvider {
  MockLlmProvider({this.scenario = MockScenario.plain});

  MockScenario scenario;
  int _turn = 0;

  @override
  String get id => 'mock';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: true, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    _turn++;
    final lastUser = req.messages.lastWhere(
      (m) => m.role == 'user' || m.role == 'tool',
      orElse: () => const ChatMessage(role: 'user', content: ''),
    );

    switch (scenario) {
      case MockScenario.assisted:
        yield* _assistedTurn(req, lastUser);

      case MockScenario.plain:
        yield const LlmTextDelta('Halo! Saya mock agent. ');
        yield const LlmTextDelta('Siap membantu.');
        yield const LlmUsage(TokenUsage(prompt: 20, completion: 10, total: 30));
        yield const LlmDone();

      case MockScenario.singleTool:
        if (_turn == 1 || lastUser.role == 'user') {
          final call = const ToolCall(
            id: 'call_mock_1',
            name: 'datetime',
            args: {},
          );
          yield LlmToolCall(call);
          yield const LlmUsage(
            TokenUsage(prompt: 40, completion: 15, total: 55),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else {
          yield const LlmTextDelta(
            'Waktu saat ini (mock): 2026-11-04T10:00:00Z',
          );
          yield const LlmUsage(
            TokenUsage(prompt: 60, completion: 20, total: 80),
          );
          yield const LlmDone();
        }

      case MockScenario.multiTool:
        final toolCount = req.messages.where((m) => m.role == 'tool').length;
        if (toolCount == 0) {
          // Extract expression from last user message (PRD: deterministic args)
          final userText = lastUser.content;
          final m = RegExp(r'([0-9().+\-*/%^\s]+)').firstMatch(userText);
          var expr = '2+3';
          if (m != null) {
            final cand = m.group(1)!.trim();
            if (RegExp(r'\d').hasMatch(cand)) expr = cand;
          }
          // prefer explicit "hitung X" / "calc X"
          final m2 = RegExp(r'(?:hitung|calc)\s+(.+)\$', caseSensitive: false).firstMatch(userText.trim());
          if (m2 != null) expr = m2.group(1)!.trim();
          yield LlmToolCall(
            ToolCall(
              id: 'call_calc_1',
              name: 'calc',
              args: {'expression': expr},
            ),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else if (toolCount == 1) {
          yield const LlmToolCall(
            ToolCall(id: 'call_dt_1', name: 'datetime', args: {}),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else {
          final toolMsg = req.messages.where((m) => m.role == 'tool').map((m) => m.content).join('; ');
          yield LlmTextDelta('Hasil tool: $toolMsg');
          yield const LlmDone();
        }

      case MockScenario.loopTrap:
        // Always request the same tool → should be stopped by LoopDetector.
        yield LlmToolCall(
          ToolCall(id: 'call_loop_$_turn', name: 'datetime', args: {}),
        );
        yield const LlmDone(finishReason: 'tool_calls');
    }
  }

  @override
  Future<List<double>> embed(String text) async => List.filled(8, 0.1);
}

enum MockScenario { plain, assisted, singleTool, multiTool, loopTrap }

Stream<LlmEvent> _assistedTurn(ChatRequest req, ChatMessage lastUser) async* {
  // Turn kedua: tool result sudah masuk — rangkum hasil tool untuk user.
  if (lastUser.role == 'tool') {
    final result = lastUser.content.trim();
    yield LlmTextDelta('Hasil (mock) dari tool: $result.');
    yield const LlmTextDelta(
      ' Saya masih agent mock — sambungkan provider LLM untuk percakapan penuh.',
    );
    yield const LlmUsage(TokenUsage(prompt: 60, completion: 24, total: 84));
    yield const LlmDone();
    return;
  }

  // Turn pertama: pertimbangkan tool call untuk pertanyaan yang bisa
  // dijawab deterministik.
  final toolNames = req.tools.map((t) => t.name).toSet();
  final text = lastUser.content.trim();
  final mathExpr = _mathExpression(text);
  final wantsTime = RegExp(
    r'(jam berapa|waktu sekarang|tanggal berapa|sekarang (jam|tanggal)|'
    r'current (time|date)|what time|today.s date)',
    caseSensitive: false,
  ).hasMatch(text);
  if (mathExpr != null && toolNames.contains('calc')) {
    yield LlmToolCall(
      ToolCall(
        id: 'call_mock_calc_1',
        name: 'calc',
        args: {'expression': mathExpr},
      ),
    );
    yield const LlmUsage(TokenUsage(prompt: 30, completion: 10, total: 40));
    yield const LlmDone(finishReason: 'tool_calls');
    return;
  }
  if (wantsTime && toolNames.contains('datetime')) {
    yield const LlmToolCall(
      ToolCall(id: 'call_mock_dt_1', name: 'datetime', args: {}),
    );
    yield const LlmUsage(TokenUsage(prompt: 30, completion: 10, total: 40));
    yield const LlmDone(finishReason: 'tool_calls');
    return;
  }

  // Tanpa tool: balasan kontekstual deterministik.
  yield LlmTextDelta(_assistedReply(text));
  yield const LlmUsage(TokenUsage(prompt: 24, completion: 40, total: 64));
  yield const LlmDone();
}

/// Ambil ekspresi hitungan sederhana dari teks ("hitung 25*4", "berapa
/// 2+3?", "(12+8)/5"). Null bila tidak ada ekspresi aritmetika yang jelas;
/// tidak diaktifkan hanya karena ada "-" (menghindari tanggal seperti
/// 2026-11-04 ikut terhitung).
String? _mathExpression(String text) {
  final withKeyword = RegExp(
    r'(?:hitung|kalkulasi|berapa|calc(?:ulate)?)\s*'
    r'([0-9][0-9.\s]*[0-9](?:[+\-*/%^][()0-9.\s]+)+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (withKeyword != null) return withKeyword.group(1)!.trim();
  final bare = RegExp(r'([0-9][()0-9.]*' r'(?:[+*/%^][()0-9.]+)+)').firstMatch(text);
  return bare?.group(1)?.trim();
}

/// Balasan kontekstual deterministik untuk scenario `assisted`.
String _assistedReply(String text) {
  final q = text.trim();
  final lower = q.toLowerCase();
  if (RegExp('^(halo|hai|hi|hello|selamat (pagi|siang|sore|malam))\\b')
      .hasMatch(lower)) {
    return 'Halo! Saya mock agent. Saya bisa: menghitung ("hitung 25*4"), '
        'menanyakan waktu ("jam berapa?"), dan mengecek status runtime '
        'via /status. Untuk jawaban LLM sungguhan, atur provider di menu '
        'Providers lalu jadikan default.';
  }
  if (RegExp('(siapa (kamu|anda)|kamu siapa|who are you|your name|nama kamu)')
      .hasMatch(lower)) {
    return 'Saya Tiko yang berjalan dengan provider mock: jawaban saya '
        'deterministik, tidak memakai LLM eksternal. Kemampuan saya saat ini: '
        'kalkulasi aritmetika via tool calc dan waktu via tool datetime '
        '(bila diizinkan security mode). Pasang provider sungguhan '
        'mis. OpenAI/Ollama di Settings > Providers untuk chat normal.';
  }
  if (RegExp('(bagaimana|cara|how)')
          .hasMatch(lower) &&
      RegExp('(setting|konfigur|provider|api.?key|model)')
          .hasMatch(lower)) {
    return 'Langkah menghubungkan LLM sungguhan: (1) buka menu Providers, '
        '(2) pilih provider (mis. openai_compat/Ollama) lalu isi base URL '
        'dan API key, (3) set "default" atau pakai pemilih model di header '
        'chat untuk sesi ini. Sementara provider belum diubah, saya (mock) '
        'hanya bisa hitung dan tanya waktu.';
  }
  final shown = q.isEmpty ? '(pesan kosong)' : (q.length > 120 ? '${q.substring(0, 120)}…' : q);
  if (RegExp('^(help|bantuan|/help|apa (yang )?bisa)', caseSensitive: false)
      .hasMatch(lower)) {
    return 'Saya mock agent, kemampuan terbatas namun nyata: '
        '"hitung 12*8" (tool calc), "jam berapa" (tool datetime), '
        'dan menjelaskan cara setting provider. Untuk LLM sesungguhnya, '
        'buka Settings > Providers.';
  }
  return 'Anda berkata: "$shown". '
      'Saya mock agent — jawaban saya deterministik, bukan dari LLM. Coba '
      '"hitung 25*4", "jam berapa?", atau "bantuan". Untuk percakapan '
      'nyata atur provider di Settings > Providers.';
}

/// In-memory tool executor for mock tests.
class MockToolExecutor implements ToolExecutor {
  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    switch (call.name) {
      case 'datetime':
        return ToolResult(
          callId: call.id,
          content: '2026-11-04T10:00:00Z',
          durationMs: 1,
        );
      case 'calc':
        final expr = call.args['expression'] as String? ?? '0';
        // Very naive eval for tests only.
        final result = _evalSimple(expr);
        return ToolResult(
          callId: call.id,
          content: result.toString(),
          durationMs: 1,
        );
      default:
        return ToolResult(
          callId: call.id,
          content: 'Unknown tool: ${call.name}',
          isError: true,
        );
    }
  }

  num _evalSimple(String expr) {
    expr = expr.replaceAll(' ', '');
    if (expr.contains('+')) {
      final parts = expr.split('+');
      return num.parse(parts[0]) + num.parse(parts[1]);
    }
    if (expr.contains('-')) {
      final parts = expr.split('-');
      return num.parse(parts[0]) - num.parse(parts[1]);
    }
    return num.tryParse(expr) ?? 0;
  }
}

/// Always-allow permission gate for tests.
class AllowAllGate implements PermissionGate {
  @override
  Future<PermissionResult> check(ToolCall call, Session session) async =>
      const PermissionResult(PermissionVerdict.allowed);
}

/// Deny-all gate.
class DenyAllGate implements PermissionGate {
  @override
  Future<PermissionResult> check(ToolCall call, Session session) async =>
      const PermissionResult(
        PermissionVerdict.denied,
        reason: 'denied by policy',
      );
}

/// In-memory no-op memory.
class NoopMemory implements MemoryStore {
  @override
  Future<void> addMessage(Message m) async {}

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async => [];

  @override
  Future<void> upsertFact(Fact f) async {}

  @override
  Future<void> afterTurn(Session session) async {}
}
