import 'dart:convert';
import 'dart:io';

import 'rag_pipeline.dart';
import 'self_rag_controller.dart';

/// EVAL-01 (audit 2026-11-28 §9.4) — benchmark RAG deterministik dengan
/// fixture berlabel. Harness membangun pipeline dari korpus fixture,
/// menjalankan query berlabel, dan menghitung precision/recall@k plus
/// tingkat keputusan evidence gate. Korpus & query berasal dari fixture
/// eksternal (file JSON) sehingga angka baseline bisa direplay dan
/// digate di CI tanpa korpus eksternal berbayar.
class RagBenchmarkCase {
  const RagBenchmarkCase({
    required this.query,
    required this.relevantDocIds,
    this.description,
  });

  factory RagBenchmarkCase.fromJson(Map<String, dynamic> json) =>
      RagBenchmarkCase(
        query: json['query'] as String? ?? '',
        relevantDocIds: [
          for (final v in json['relevant_doc_ids'] as List? ?? const [])
            if (v is String) v,
        ],
        description: json['description'] as String?,
      );

  /// Query user (bisa paraphrase dari isi dokumen).
  final String query;

  /// docId yang dianggap relevan; KOSONG = kasus distraktor — diharapkan
  /// tidak mengembalikan hit relevan dan evidence gate menolak.
  final List<String> relevantDocIds;
  final String? description;
}

class RagBenchmarkReport {
  const RagBenchmarkReport({
    required this.totalCases,
    required this.relevantCases,
    required this.distractorCases,
    required this.precisionAtK,
    required this.recallAtK,
    required this.gateAcceptedRelevant,
    required this.gateRejectedDistractor,
    required this.perCase,
  });

  final int totalCases;
  final int relevantCases;
  final int distractorCases;

  /// Rata-rata precision@k pada kasus relevan (0..1).
  final double precisionAtK;

  /// Rata-rata recall@k pada kasus relevan (0..1).
  final double recallAtK;

  /// Proporsi kasus relevan yang diterima evidence gate (0..1).
  final double gateAcceptedRelevant;

  /// Proporsi kasus distraktor yang ditolak evidence gate (0..1).
  final double gateRejectedDistractor;

  final List<Map<String, dynamic>> perCase;

  Map<String, dynamic> toJson() => {
        'total_cases': totalCases,
        'relevant_cases': relevantCases,
        'distractor_cases': distractorCases,
        'precision_at_k': precisionAtK,
        'recall_at_k': recallAtK,
        'gate_accepted_relevant': gateAcceptedRelevant,
        'gate_rejected_distractor': gateRejectedDistractor,
        'per_case': perCase,
      };
}

/// Fixture benchmark: korpus dokumen + kasus berlabel.
class RagBenchmarkFixture {
  const RagBenchmarkFixture({required this.documents, required this.cases});

  factory RagBenchmarkFixture.fromJson(Map<String, dynamic> json) =>
      RagBenchmarkFixture(
        documents: {
          for (final e in (json['documents'] as Map<String, dynamic>? ?? {})
              .entries)
            e.key: '${e.value}',
        },
        cases: [
          for (final v in json['cases'] as List? ?? const [])
            if (v is Map<String, dynamic>) RagBenchmarkCase.fromJson(v),
        ],
      );

  factory RagBenchmarkFixture.fromFile(String path) =>
      RagBenchmarkFixture.fromJson(
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
      );

  final Map<String, String> documents;
  final List<RagBenchmarkCase> cases;
}

class RagBenchmark {
  const RagBenchmark({
    this.k = 4,
    this.gate = const SelfRagController(),
  });

  final int k;
  final SelfRagController gate;

  /// Menjalankan benchmark di atas [pipeline]. Pipeline diasumsikan sudah
  /// berisi korpus (mis. dari [RagBenchmarkFixture.documents]).
  Future<RagBenchmarkReport> run(
    RagPipeline pipeline,
    List<RagBenchmarkCase> cases,
  ) async {
    var relevantCount = 0;
    var distractorCount = 0;
    var precisionSum = 0.0;
    var recallSum = 0.0;
    var gateAccepted = 0;
    var gateRejected = 0;
    final perCase = <Map<String, dynamic>>[];

    for (final c in cases) {
      final result = await pipeline.retrieve(c.query, k: k);
      final hitDocs = result.hits.map((h) => h.chunk.docId).toSet();
      final relevant = c.relevantDocIds.toSet();
      final isDistractor = relevant.isEmpty;
      final precision = isDistractor || hitDocs.isEmpty
          ? 0.0
          : hitDocs.intersection(relevant).length / hitDocs.length;
      final recall = isDistractor || relevant.isEmpty
          ? 0.0
          : hitDocs.intersection(relevant).length / relevant.length;
      final assessment = gate.assess(
        query: c.query,
        hits: result.hits,
        context: result.context,
        embedderConfigured: pipeline.embedder != null,
      );
      if (isDistractor) {
        distractorCount++;
        if (!assessment.accepted) gateRejected++;
      } else {
        relevantCount++;
        precisionSum += precision;
        recallSum += recall;
        if (assessment.accepted) gateAccepted++;
      }
      perCase.add({
        'query': c.query,
        'relevant_doc_ids': c.relevantDocIds,
        'hit_doc_ids': hitDocs.toList(),
        'precision': precision,
        'recall': recall,
        'gate': assessment.status,
        if (c.description != null) 'description': c.description,
      });
    }

    return RagBenchmarkReport(
      totalCases: cases.length,
      relevantCases: relevantCount,
      distractorCases: distractorCount,
      precisionAtK: relevantCount == 0 ? 0 : precisionSum / relevantCount,
      recallAtK: relevantCount == 0 ? 0 : recallSum / relevantCount,
      gateAcceptedRelevant:
          relevantCount == 0 ? 0 : gateAccepted / relevantCount,
      gateRejectedDistractor:
          distractorCount == 0 ? 0 : gateRejected / distractorCount,
      perCase: perCase,
    );
  }
}
