/// Fase 32 — API-Bank task schema (audit 2026-11-28 §6 #17, gap:
/// "API-Bank task schema belum disertakan"). Adapter skema dataset benchmark
/// tool-use bergaya API-Bank (EMNLP 2023): tiap kasus memuat query pengguna,
/// dokumentasi API yang tersedia, dan daftar panggilan API yang diharapkan.
///
/// BUKAN salinan dataset eksternal: parser menerima format JSONL standar
/// (`query`, `api_docs`, `expected_calls`) sehingga dataset asli bisa
/// dimuat bila pengguna memilikinya, dan repo menyertakan fixture mini
/// tersendiri untuk regresi CI tanpa dependensi jaringan/lisensi.
///
/// Konversi memakai infrastruktur [EvalCase]/[EvalHarness] yang sudah ada
/// (kind `tool_precision`) — tidak ada harness kedua.

import 'dart:convert';

import 'eval_harness.dart';

/// Satu kasus skema API-Bank.
class ApiBankCase {
  const ApiBankCase({
    required this.id,
    required this.query,
    this.apiDocs = const [],
    this.expectedCalls = const [],
    this.requiresRefresh = false,
  });

  factory ApiBankCase.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return ApiBankCase(
      id: id.isEmpty ? 'apibank-${DateTime.now().microsecondsSinceEpoch}' : id,
      query: json['query'] as String? ?? '',
      apiDocs: [
        for (final doc in json['api_docs'] as List<dynamic>? ?? const [])
          if (doc is Map<String, dynamic>)
            ApiDoc(
              name: doc['name'] as String? ?? '',
              description: doc['description'] as String? ?? '',
            ),
      ],
      expectedCalls: [
        for (final call in json['expected_calls'] as List<dynamic>? ?? const [])
          if (call is Map<String, dynamic>)
            ExpectedApiCall(
              name: call['name'] as String? ?? '',
              arguments:
                  (call['arguments'] as Map<String, dynamic>? ?? const {}),
            ),
      ],
      requiresRefresh: json['requires_refresh'] as bool? ?? false,
    );
  }

  final String id;
  final String query;
  final List<ApiDoc> apiDocs;
  final List<ExpectedApiCall> expectedCalls;

  /// API-Bank: sebagian kasus butuh refresh token sebelum panggilan API.
  final bool requiresRefresh;

  Map<String, dynamic> toJson() => {
        'id': id,
        'query': query,
        'api_docs': [for (final d in apiDocs) d.toJson()],
        'expected_calls': [for (final c in expectedCalls) c.toJson()],
        if (requiresRefresh) 'requires_refresh': true,
      };
}

class ApiDoc {
  const ApiDoc({required this.name, required this.description});

  final String name;
  final String description;

  Map<String, dynamic> toJson() => {'name': name, 'description': description};
}

class ExpectedApiCall {
  const ExpectedApiCall({required this.name, this.arguments = const {}});

  final String name;
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (arguments.isNotEmpty) 'arguments': arguments,
      };
}

/// Adapter: parse JSONL API-Bank dan konversi ke [EvalCase] (kind
/// `tool_precision`) untuk dijalankan [EvalHarness] biasa.
class ApiBankAdapter {
  const ApiBankAdapter();

  /// Parse JSONL; baris kosong/invalid dilewati (fail-open) — jumlah hasil
  /// boleh lebih kecil dari jumlah baris.
  List<ApiBankCase> parseJsonl(String content) {
    final out = <ApiBankCase>[];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          out.add(ApiBankCase.fromJson(decoded));
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Konversi ke [EvalCase] tool-precision: nama API diharapkan →
  /// `expectedTools`; dokumentasi API disertakan di prompt agar runner dapat
  /// mensimulasikan pemilihan tool; argumen expected dipertahankan di meta
  /// untuk verifikasi lebih lanjut.
  List<EvalCase> toEvalCases(List<ApiBankCase> cases) => [
        for (final c in cases)
          EvalCase(
            id: c.id,
            kind: EvalKind.toolPrecision,
            prompt: [
              c.query,
              if (c.apiDocs.isNotEmpty)
                'API tersedia: '
                    '${c.apiDocs.map((d) => d.name).join(', ')}.',
              if (c.requiresRefresh)
                'Kasus ini membutuhkan refresh token terlebih dahulu.',
            ].join('\n'),
            expectedTools: {
              for (final call in c.expectedCalls)
                if (call.name.isNotEmpty) call.name,
            },
            expectSuccess: true,
            meta: {
              'api_bank': true,
              'requires_refresh': c.requiresRefresh,
              'expected_calls': [for (final call in c.expectedCalls) call.toJson()],
            },
          ),
      ];

  /// Parse sekaligus konversi (jalur utama pemakaian).
  List<EvalCase> fromJsonl(String content) =>
      toEvalCases(parseJsonl(content));
}
