// Fase F8.2 (docs/15 §9) — approval-remember: aturan izin yang diingat
// setelah konfirmasi manual, untuk menurunkan FREKUENSI konfirmasi identik
// tanpa menghapus lapisan mediasi host (gate tetap berjalan; hanya prompt
// yang di-skip). Scope `session` in-memory; scope `workspace` persist di
// dataDir/approval_rules.json (milik operator, di luar jail workspace).

part of 'tiko_runtime.dart';

/// Satu aturan izin yang diingat: cocok untuk [tool] (dan prefix perintah
/// shell bila ada) dalam scope tertentu.
class ApprovalRule {
  ApprovalRule({
    required this.tool,
    required this.scope,
    this.cmdPrefix,
    this.sessionId,
    required this.createdAt,
  });

  factory ApprovalRule.fromJson(Map<String, dynamic> m) {
    final tool = m['tool']?.toString() ?? '';
    final scope = m['scope']?.toString() ?? '';
    if (tool.isEmpty || !const {'workspace', 'session'}.contains(scope)) {
      throw const FormatException('invalid approval rule');
    }
    return ApprovalRule(
      tool: tool,
      scope: scope,
      cmdPrefix: m['cmd_prefix']?.toString(),
      sessionId: m['session_id']?.toString(),
      createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  final String tool;
  final String scope; // 'workspace' | 'session'
  final String? cmdPrefix;
  final String? sessionId; // wajib untuk scope session
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'scope': scope,
        if (cmdPrefix != null) 'cmd_prefix': cmdPrefix,
        if (sessionId != null) 'session_id': sessionId,
        'created_at': createdAt.toIso8601String(),
      };
}

/// Store aturan approval. Fail-soft: file korup/tak terbaca dimulai kosong.
class ApprovalRules {
  ApprovalRules({required this.persistPath, this.maxRules = 200});

  final String persistPath;
  final int maxRules;
  final List<ApprovalRule> _rules = [];
  bool _loaded = false;

  int get length => _rules.length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(persistPath);
    if (!await f.exists()) return;
    try {
      final text = await f.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final rule = ApprovalRule.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (rule.scope == 'session') continue; // tidak dipersist ulang
          _rules.add(rule);
        } catch (_) {
          // Entri korup dilompati.
        }
      }
    } on Exception {
      // File tak terbaca: mulai kosong.
    }
  }

  Future<void> save() async {
    final file = File(persistPath);
    await file.parent.create(recursive: true);
    final buffer = StringBuffer(
      const JsonEncoder.withIndent('  ').convert(
        _rules.where((r) => r.scope == 'workspace').map((r) => r.toJson()).toList(),
      ),
    );
    await file.writeAsString('$buffer\n', flush: true);
  }

  /// Cocokkan call ke aturan. Shell hanya cocok bila prefix argv/awal
  /// perintah sama dengan yang diingat.
  bool matches(ToolCall call, {String? sessionId}) {
    for (final rule in _rules.reversed) {
      if (rule.tool != call.name) continue;
      if (rule.scope == 'session') {
        if (sessionId != null && rule.sessionId != sessionId) continue;
      }
      if (rule.tool == 'shell' && rule.cmdPrefix != null) {
        final cmd =
            '${call.args['command'] ?? call.args['cmd'] ?? ''}'.trim();
        if (!cmd.startsWith(rule.cmdPrefix!)) continue;
      }
      return true;
    }
    return false;
  }

  /// Ingat aksi yang baru dikonfirmasi user. Untuk shell, prefix disimpan
  /// hingga argumen terakhir penuh (bukan sub-prefix kabur) — `flutter test`
  /// tidak mengizinkan `flutter clean` otomatis.
  Future<void> remember(
    ToolCall call, {
    required String scope,
    String? sessionId,
  }) async {
    await load();
    String? prefix;
    if (call.name == 'shell') {
      final cmd = '${call.args['command'] ?? call.args['cmd'] ?? ''}'.trim();
      if (cmd.isNotEmpty) prefix = cmd;
    }
    _rules.add(ApprovalRule(
      tool: call.name,
      scope: scope,
      cmdPrefix: prefix,
      sessionId: scope == 'session' ? sessionId : null,
      createdAt: DateTime.now().toUtc(),
    ));
    while (_rules.length > maxRules) {
      _rules.removeAt(0);
    }
    if (scope == 'workspace') await save();
  }

  List<ApprovalRule> list() => List.unmodifiable(_rules);

  Future<void> clear() async {
    _rules.clear();
    await save();
  }
}
