import 'package:agent_core/agent_core.dart';

/// Satu keputusan yang tercatat beserta alasannya.
class DecisionEntry {
  DecisionEntry({
    required this.id,
    required this.decision,
    required this.rationale,
    required this.alternatives,
  }) : recordedAt = DateTime.now().toUtc().toIso8601String();

  final String id;
  final String decision;
  final String rationale;
  final List<String> alternatives;
  final String recordedAt;
}

/// Jejak keputusan agent (bagian dari why/NEW-10): setiap pilihan
/// penting dicatat dengan alasan dan alternatif yang dibuang, agar
/// bisa ditelusuri belakangan tanpa harus membaca ulang seluruh log.
class DecisionLog {
  final List<DecisionEntry> _entries = [];
  int _counter = 0;

  /// Mencatat keputusan baru; mengembalikan entry-nya.
  DecisionEntry record(
    String decision,
    String rationale,
    List<String> alternatives,
  ) {
    final id = 'd-${_counter + 1}';
    _counter++;
    final e = DecisionEntry(
      id: id,
      decision: decision,
      rationale: rationale,
      alternatives: List.unmodifiable(alternatives),
    );
    _entries.add(e);
    return e;
  }

  /// Cari keputusan yang memuat [query] pada teks keputusan atau alasan.
  List<DecisionEntry> search(String query) {
    final q = query.toLowerCase();
    return [
      for (final e in _entries)
        if (e.decision.toLowerCase().contains(q) ||
            e.rationale.toLowerCase().contains(q))
          e,
    ];
  }

  /// Semua keputusan terurut lama ke baru.
  List<DecisionEntry> get entries => List.unmodifiable(_entries);

  /// Jumlah keputusan yang tercatat.
  int get length => _entries.length;
}

/// record_decision — catat keputusan penting beserta alasannya.
class RecordDecisionTool implements Tool {
  RecordDecisionTool({required this.log});

  final DecisionLog log;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'record_decision',
    description:
        'Catat keputusan penting yang barusan diambil: keputusannya, '
        'alasannya, dan alternatif yang dibuang (jika ada).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'decision': {
          'type': 'string',
          'description': 'Keputusannya (1-300 karakter).',
        },
        'rationale': {
          'type': 'string',
          'description': 'Alasannya (1-500 karakter).',
        },
        'alternatives': {
          'type': 'array',
          'description': 'Alternatif yang dibuang (maks 5).',
        },
      },
      'required': ['decision', 'rationale'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final decision = (args['decision'] as String?)?.trim() ?? '';
    final rationale = (args['rationale'] as String?)?.trim() ?? '';
    if (decision.isEmpty || decision.length > 300) {
      return const ToolResult(
        callId: '',
        content: 'decision wajib 1-300 karakter',
        isError: true,
      );
    }
    if (rationale.isEmpty || rationale.length > 500) {
      return const ToolResult(
        callId: '',
        content: 'rationale wajib 1-500 karakter',
        isError: true,
      );
    }
    final raw = args['alternatives'];
    if (raw != null && raw is! List) {
      return const ToolResult(
        callId: '',
        content: 'alternatives wajib array string',
        isError: true,
      );
    }
    final alternatives = <String>[];
    if (raw is List) {
      for (final a in raw) {
        final s = a.toString().trim();
        if (s.isNotEmpty) alternatives.add(s);
      }
      if (alternatives.length > 5) {
        return const ToolResult(
          callId: '',
          content: 'maksimal 5 alternatif',
          isError: true,
        );
      }
    }
    final e = log.record(decision, rationale, alternatives);
    return ToolResult(
      callId: '',
      content: 'OK keputusan ${e.id} tercatat',
    );
  }
}

/// why — jelaskan keputusan yang diambil (jejak decision log).
class WhyTool implements Tool {
  WhyTool({required this.log});

  final DecisionLog log;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'why',
    description:
        'Tampilkan keputusan yang tercatat (filter dengan query bila '
        'ada) beserta alasan dan alternatif yang dibuang.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'Kata kunci (opsional).',
        },
      },
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    final entries = query.isEmpty ? log.entries : log.search(query);
    if (entries.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada keputusan yang tercatat (untuk query itu).',
        isError: true,
      );
    }
    final lines = <String>[];
    for (final e in entries) {
      final alts = e.alternatives.isEmpty
          ? ''
          : ' (alternatif dibuang: ${e.alternatives.join(', ')})';
      lines.add('${e.id}: ${e.decision} — ${e.rationale}$alts');
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
