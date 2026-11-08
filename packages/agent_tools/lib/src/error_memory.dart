import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Signature-based error memory (NEW-09): normalizes error output into
/// a stable signature so recurring failures match across sessions and
/// the fix that previously worked can be reused before retrying.
class ErrorMemoryStore {
  ErrorMemoryStore({this.persistPath});

  final String? persistPath;
  final List<ErrorMemoryEntry> _entries = [];
  var _loaded = false;

  /// Lowercase, strip ANSI codes, then replace hex/long-hash/number
  /// runs with stable markers so the same failure always normalizes
  /// to the same text.
  static String normalize(String output) {
    var s = output.toLowerCase();
    s = s.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-z]'), ' ');
    s = s.replaceAll(RegExp(r'0x[0-9a-f]+'), '<hex>');
    s = s.replaceAll(RegExp(r'\b[0-9a-f]{8,}\b'), '<hash>');
    s = s.replaceAll(RegExp(r'\d+'), '<n>');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.trim();
  }

  /// Letter tokens (len >= 3) of a normalized error text.
  static Set<String> signatureTokens(String normalized) {
    return normalized
        .split(RegExp(r'[^a-z]+'))
        .where((t) => t.length >= 3)
        .toSet();
  }

  Future<void> record(ErrorMemoryEntry entry) async {
    await _ensureLoaded();
    final same = _entries.where((e) => e.signature == entry.signature);
    if (same.isEmpty) {
      _entries.add(entry);
    } else {
      final old = same.first;
      old
        ..cause = entry.cause
        ..fix = entry.fix
        ..hits = old.hits + 1
        ..tokens.addAll(entry.tokens);
    }
    await _save();
  }

  Future<List<ErrorMemoryMatch>> lookup(
    String output, {
    int k = 3,
    double threshold = 0.3,
  }) async {
    await _ensureLoaded();
    final query = signatureTokens(normalize(output));
    if (query.isEmpty) return const [];
    final matches = <ErrorMemoryMatch>[];
    for (final e in _entries) {
      final union = query.union(e.tokens).length;
      if (union == 0) continue;
      final inter = query.intersection(e.tokens).length;
      final sim = inter / union;
      if (sim >= threshold) {
        matches.add(ErrorMemoryMatch(entry: e, similarity: sim));
      }
    }
    matches.sort((a, b) => b.similarity.compareTo(a.similarity));
    if (matches.length > k) matches.removeRange(k, matches.length);
    return matches;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final path = persistPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is List) {
        for (final item in data) {
          if (item is Map<String, dynamic>) {
            _entries.add(ErrorMemoryEntry.fromJson(item));
          }
        }
      }
    } catch (_) {
      // Persist file korup: mulai dari memori kosong.
    }
  }

  Future<void> _save() async {
    final path = persistPath;
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    final data = _entries.map((e) => e.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }
}

/// One stored failure with its cause, the fix that worked and how many
/// times the same signature has been seen.
class ErrorMemoryEntry {
  ErrorMemoryEntry({
    required this.signature,
    required this.cause,
    required this.fix,
    this.hits = 1,
    String? createdAt,
    Set<String>? tokens,
  })  : createdAt = createdAt ?? DateTime.now().toUtc().toIso8601String(),
        tokens = tokens ?? <String>{};

  final String signature;
  String cause;
  String fix;
  int hits;
  final String createdAt;
  final Set<String> tokens;

  Map<String, dynamic> toJson() => {
    'signature': signature,
    'cause': cause,
    'fix': fix,
    'hits': hits,
    'created_at': createdAt,
    'tokens': tokens.toList()..sort(),
  };

  factory ErrorMemoryEntry.fromJson(Map<String, dynamic> json) =>
      ErrorMemoryEntry(
        signature: json['signature'] as String? ?? '',
        cause: json['cause'] as String? ?? '',
        fix: json['fix'] as String? ?? '',
        hits: (json['hits'] as num?)?.toInt() ?? 1,
        createdAt: json['created_at'] as String?,
        tokens: (json['tokens'] as List?)
            ?.map((t) => t.toString())
            .toSet(),
      );
}

/// One lookup hit: the stored entry plus its Jaccard similarity.
class ErrorMemoryMatch {
  const ErrorMemoryMatch({required this.entry, required this.similarity});

  final ErrorMemoryEntry entry;
  final double similarity;
}

/// error_record — store a failure with its cause and working fix.
class ErrorRecordTool implements Tool {
  ErrorRecordTool({required this.store});

  final ErrorMemoryStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'error_record',
    description:
        'Catat error yang baru terjadi beserta penyebab dan perbaikan '
        'yang berhasil, untuk dipakai ulang di sesi berikutnya.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'output': {
          'type': 'string',
          'description': 'Teks error (stderr/exception) apa adanya.',
        },
        'cause': {'type': 'string', 'description': 'Penyebab utama.'},
        'fix': {'type': 'string', 'description': 'Perbaikan yang berhasil.'},
      },
      'required': ['output', 'cause', 'fix'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final output = args['output'] as String? ?? '';
    final cause = args['cause'] as String? ?? '';
    final fix = args['fix'] as String? ?? '';
    if (output.trim().isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'output wajib',
        isError: true,
      );
    }
    final normalized = ErrorMemoryStore.normalize(output);
    final signature =
        normalized.length > 160 ? normalized.substring(0, 160) : normalized;
    await store.record(ErrorMemoryEntry(
      signature: signature,
      cause: cause,
      fix: fix,
      tokens: ErrorMemoryStore.signatureTokens(normalized),
    ));
    return ToolResult(
      callId: '',
      content: 'OK error dicatat (signature: $signature)',
    );
  }
}

/// error_lookup — find similar past failures before retrying a step.
class ErrorLookupTool implements Tool {
  ErrorLookupTool({required this.store});

  final ErrorMemoryStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'error_lookup',
    description:
        'Cari error serupa yang pernah terjadi beserta perbaikannya. '
        'Panggil sebelum mencoba ulang langkah yang gagal.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'output': {
          'type': 'string',
          'description': 'Teks error saat ini.',
        },
        'k': {
          'type': 'integer',
          'description': 'Jumlah hasil maksimum (default 3).',
        },
      },
      'required': ['output'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final output = args['output'] as String? ?? '';
    if (output.trim().isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'output wajib',
        isError: true,
      );
    }
    final k = (args['k'] as num?)?.toInt() ?? 3;
    final matches = await store.lookup(output, k: k);
    if (matches.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada error serupa di memori.',
      );
    }
    final lines = <String>[];
    for (final m in matches) {
      lines
        ..add('- signature: ${m.signature}')
        ..add('  cause: ${m.cause}')
        ..add('  fix: ${m.fix}')
        ..add('  hits: ${m.hits}')
        ..add('  similarity: ${m.similarity.toStringAsFixed(2)}');
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
