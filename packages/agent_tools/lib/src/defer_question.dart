import 'package:agent_core/agent_core.dart';

/// Satu pertanyaan yang ditunda ke user.
class DeferredQuestion {
  DeferredQuestion({
    required this.id,
    required this.sessionId,
    required this.question,
    required this.options,
  }) : askedAt = DateTime.now().toUtc().toIso8601String();

  final String id;
  final String sessionId;
  final String question;
  final List<String> options;
  final String askedAt;
  String? answer;
  String? answeredAt;
}

/// defer_question (NEW-08): pertanyaan ambigu ditunda ke user tanpa
/// menghentikan loop — agent lanjut mengerjakan bagian yang tidak
/// bergantung pada jawaban; jawaban masuk lewat answer_deferred.
class DeferredQuestionStore {
  final Map<String, DeferredQuestion> _questions = {};
  int _counter = 0;

  /// Mencatat pertanyaan baru; mengembalikan ID-nya.
  String add(String sessionId, String question, List<String> options) {
    final id = 'q-${_counter + 1}';
    _counter++;
    _questions[id] = DeferredQuestion(
      id: id,
      sessionId: sessionId,
      question: question,
      options: List.unmodifiable(options),
    );
    return id;
  }

  /// Menandai pertanyaan terjawab; false bila ID tidak dikenal.
  bool answer(String id, String answerText) {
    final q = _questions[id];
    if (q == null) return false;
    q.answer = answerText;
    q.answeredAt = DateTime.now().toUtc().toIso8601String();
    return true;
  }

  /// Pertanyaan yang masih terbuka untuk [sessionId].
  List<DeferredQuestion> openFor(String sessionId) => [
        for (final q in _questions.values)
          if (q.answer == null && q.sessionId == sessionId) q,
      ];

  /// Total pertanyaan yang pernah dicatat.
  int get total => _questions.length;
}

/// defer_question — catat pertanyaan ambigu lalu lanjut bekerja.
class DeferQuestionTool implements Tool {
  DeferQuestionTool({required this.store});

  final DeferredQuestionStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'defer_question',
    description:
        'Catat pertanyaan ambigu untuk user tanpa menghentikan pekerjaan: '
        'sebut pertanyaan (dan opsi jawaban bila ada), lalu lanjutkan '
        'bagian tugas yang tidak bergantung pada jawabannya.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string', 'description': 'Pertanyaannya.'},
        'options': {
          'type': 'array',
          'description': 'Opsi jawaban (maks 4, opsional).',
        },
      },
      'required': ['question'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final question = (args['question'] as String?)?.trim() ?? '';
    if (question.isEmpty || question.length > 500) {
      return const ToolResult(
        callId: '',
        content: 'question wajib 1-500 karakter',
        isError: true,
      );
    }
    final raw = args['options'];
    if (raw != null && raw is! List) {
      return const ToolResult(
        callId: '',
        content: 'options wajib array string',
        isError: true,
      );
    }
    final options = <String>[];
    if (raw is List) {
      for (final o in raw) {
        final s = o.toString().trim();
        if (s.isNotEmpty) options.add(s);
      }
      if (options.length > 4) {
        return const ToolResult(
          callId: '',
          content: 'maksimal 4 opsi',
          isError: true,
        );
      }
    }
    final id = store.add(ctx.session.id, question, options);
    return ToolResult(
      callId: '',
      content: 'OK pertanyaan $id dicatat; lanjutkan pekerjaan lain '
          'tanpa menunggu jawaban',
    );
  }
}

/// answer_deferred — isi jawaban pertanyaan yang ditunda.
class AnswerDeferredTool implements Tool {
  AnswerDeferredTool({required this.store});

  final DeferredQuestionStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'answer_deferred',
    description: 'Isi jawaban pertanyaan yang ditunda berdasarkan ID-nya.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'ID pertanyaan (q-N).'},
        'answer': {'type': 'string', 'description': 'Jawabannya.'},
      },
      'required': ['id', 'answer'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final id = (args['id'] as String?)?.trim() ?? '';
    final answer = (args['answer'] as String?)?.trim() ?? '';
    if (id.isEmpty || answer.isEmpty || answer.length > 1000) {
      return const ToolResult(
        callId: '',
        content: 'id wajib; answer wajib 1-1000 karakter',
        isError: true,
      );
    }
    if (!store.answer(id, answer)) {
      return ToolResult(
        callId: '',
        content: 'ID tidak dikenal: $id',
        isError: true,
      );
    }
    return ToolResult(callId: '', content: 'OK $id terjawab');
  }
}

/// list_deferred — daftar pertanyaan terbuka sesi ini.
class ListDeferredTool implements Tool {
  ListDeferredTool({required this.store});

  final DeferredQuestionStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'list_deferred',
    description: 'Daftar pertanyaan tertunda yang belum terjawab.',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final open = store.openFor(ctx.session.id);
    if (open.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada pertanyaan tertunda.',
        isError: true,
      );
    }
    final lines = <String>[];
    for (final q in open) {
      final opts =
          q.options.isEmpty ? '' : ' (opsi: ${q.options.join(' / ')})';
      lines.add('${q.id}: ${q.question}$opts');
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
