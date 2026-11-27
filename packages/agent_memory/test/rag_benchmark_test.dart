import 'dart:io';
import 'dart:isolate';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

Future<String> _fixturePath() async {
  final libUri =
      await Isolate.resolvePackageUri(Uri.parse('package:agent_memory/agent_memory.dart'));
  final libDir = File.fromUri(libUri!).parent.path;
  return '$libDir/../test/fixtures/rag_benchmark.json';
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rag_benchmark');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('EVAL-01: baseline fixture lulus ambang precision/recall/gate',
      () async {
    final fixture = RagBenchmarkFixture.fromFile(await _fixturePath());
    expect(fixture.documents.length, 6);
    expect(fixture.cases.length, 10);

    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${tmp.path}/rag_fts.json'),
    );
    for (final e in fixture.documents.entries) {
      await pipeline.ingest(e.key, e.value);
    }

    final report = await const RagBenchmark(k: 4).run(pipeline, fixture.cases);
    final json = report.toJson();
    expect(json['total_cases'], 10);
    expect(json['relevant_cases'], 8);
    expect(json['distractor_cases'], 2);

    expect(report.recallAtK, greaterThanOrEqualTo(0.75),
        reason: 'recall@4=${report.recallAtK}');
    expect(report.precisionAtK, greaterThanOrEqualTo(0.5),
        reason: 'precision@4=${report.precisionAtK}');
    expect(report.gateAcceptedRelevant, greaterThanOrEqualTo(0.75),
        reason: 'gate accept=${report.gateAcceptedRelevant}');
    expect(report.gateRejectedDistractor, 1.0,
        reason: 'gate reject distractor=${report.gateRejectedDistractor}');
  });

  test('EVAL-01: report serializable dan per-case tercatat', () async {
    final fixture = RagBenchmarkFixture.fromFile(await _fixturePath());
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${tmp.path}/rag_fts.json'),
    );
    for (final e in fixture.documents.entries) {
      await pipeline.ingest(e.key, e.value);
    }

    final report = await const RagBenchmark(k: 2).run(pipeline, fixture.cases);
    expect(report.perCase, hasLength(10));
    expect(report.perCase.first, contains('gate'));
    expect(report.toJson()['precision_at_k'], isA<double>());
  });

  test('EVAL-01: rerun deterministik (baseline replay stabil)', () async {
    final fixture = RagBenchmarkFixture.fromFile(await _fixturePath());
    Future<RagBenchmarkReport> runOnce() async {
      final pipeline = RagPipeline(
        dense: BruteForceVectorIndex(),
        lexical: FtsIndex('${tmp.path}/rag_fts_${DateTime.now().microsecondsSinceEpoch}.json'),
      );
      for (final e in fixture.documents.entries) {
        await pipeline.ingest(e.key, e.value);
      }
      return const RagBenchmark(k: 4).run(pipeline, fixture.cases);
    }

    final a = await runOnce();
    final b = await runOnce();
    expect(a.recallAtK, b.recallAtK);
    expect(a.precisionAtK, b.precisionAtK);
    expect(a.gateAcceptedRelevant, b.gateAcceptedRelevant);
  });
}
