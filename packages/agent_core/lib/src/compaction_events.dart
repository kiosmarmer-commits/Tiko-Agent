/// Compaction events (Hermes parity: `agent/compaction_events.py`): record
/// v1 bebas-konten untuk setiap rewrite riwayat — tidak pernah membawa teks
/// pesan/ringkasan/error/path. Payload flat karena exporter OpenTelemetry
/// hanya meratakan key top-level; field kategoris berasal dari closed set
/// dengan fallback `other`/`unknown`. Publishing tidak pernah melempar ke
/// dalam jalur kompresi.
library;

/// Schema name + version (kompatibel Hermes v1).
const compactionSchemaName = 'hermes.compaction';
const compactionSchemaVersion = '1';

/// Jenis rewrite: kompresi batch, micro-compaction, prune tool-result.
const compactionKinds = {'summarize', 'micro_summarize', 'prune_tool_results'};

/// Pemicu kompresi (closed set Hermes, subset yang relevan Tiko).
const compactionTriggers = {
  'manual',
  'turn_start_threshold',
  'overflow',
  'unknown',
};

/// Kelas pemicu: otomatis vs manual vs overflow — untuk agregasi metrik.
String triggerClassOf(String trigger) => switch (trigger) {
      'manual' => 'manual',
      'overflow' => 'overflow',
      _ => 'auto',
    };

/// Metode ringkasan yang benar-benar dipakai.
const compactionMethods = {
  'llm_summary',
  'deterministic_fallback',
  'deterministic_prune',
  'none',
};

/// Hasil attempt: committed (riwayat benar-benar ditulis ulang),
/// skipped (attempt berhenti tanpa rewrite), failed (error).
const compactionOutcomes = {'committed', 'skipped', 'failed'};

/// Satu record `hermes.compaction` v1 — flat, bebas konten.
class CompactionEvent {
  const CompactionEvent({
    required this.kind,
    required this.trigger,
    required this.method,
    required this.outcome,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.messagesBefore,
    required this.messagesAfter,
    required this.durationMs,
    required this.ts,
    this.scope = 'history',
  });

  final String kind;
  final String scope;
  final String trigger;
  final String method;
  final String outcome;
  final int tokensBefore;
  final int tokensAfter;
  final int messagesBefore;
  final int messagesAfter;
  final int durationMs;
  final DateTime ts;

  String get triggerClass => triggerClassOf(trigger);

  Map<String, dynamic> toJson() => {
        'schema': compactionSchemaName,
        'schema_version': compactionSchemaVersion,
        'ts': ts.toIso8601String(),
        'kind': compactionKinds.contains(kind) ? kind : 'other',
        'scope': scope,
        'trigger': compactionTriggers.contains(trigger) ? trigger : 'other',
        'trigger_class': triggerClass,
        'method': compactionMethods.contains(method) ? method : 'other',
        'outcome': compactionOutcomes.contains(outcome) ? outcome : 'other',
        'tokens_before': tokensBefore,
        'tokens_after': tokensAfter,
        'messages_before': messagesBefore,
        'messages_after': messagesAfter,
        'duration_ms': durationMs,
      };
}

/// Callback sink kompresi — kegagalan callback TIDAK dipropagasi ke jalur
/// kompresi (kontrak Hermes: publishing never raises into compaction).
typedef CompactionEventCallback = void Function(CompactionEvent event);

/// Ring buffer record kompresi terakhir untuk observability host.
class CompactionEventSink {
  CompactionEventSink({this.capacity = 100});

  final int capacity;
  final List<CompactionEvent> _records = [];

  /// Emit satu record — never-raises.
  void emit(CompactionEvent event) {
    try {
      _records.add(event);
      while (_records.length > capacity) {
        _records.removeAt(0);
      }
    } catch (_) {}
  }

  List<CompactionEvent> get records => List.unmodifiable(_records);

  /// Bentuk wire (list JSON flat) — siap diteruskan ke OTEL/host.
  List<Map<String, dynamic>> toJson() =>
      [for (final r in _records) r.toJson()];

  void clear() => _records.clear();
}
