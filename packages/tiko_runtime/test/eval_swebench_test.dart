import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// S20-B - loader SWE-bench: dataset JSONL resmi (instance_id,
/// problem_statement, repo) diputar ulang sebagai gate eval di runtime mock.
void main() {
  TikoRuntime? rt;
  Directory? temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('s20-swebench-');
    final config = File(p.join(temp!.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp!.path}/workspace
data_dir: ${temp!.path}/data
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
    rt = await TikoRuntime.create(configPath: config.path, safe: false);
  });

  tearDownAll(() async {
    await rt?.close();
    final dir = temp;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  String writeDataset(String name, List<String> lines) {
    final file = File(p.join(temp!.path, name));
    file.writeAsStringSync('${lines.join('\n')}\n');
    return file.path;
  }

  test('parse JSONL SWE-bench: instance_id -> id, problem_statement -> prompt',
      () async {
    final path = writeDataset('valid.jsonl', [
      jsonEncode({
        'instance_id': 'sympy__sympy-13031',
        'problem_statement': 'Fix the infinity symbol in the latex printer.',
        'repo': 'sympy/sympy',
      }),
      jsonEncode({
        'instance_id': 'django__django-11039',
        'problem_statement': 'Add support for GENERATED ALWAYS AS in migrations.',
        'repo': 'django/django',
      }),
    ]);
    final tasks = await specsFromSwebenchFile(path);
    expect(tasks, hasLength(2));
    expect(tasks[0].id, 'swebench-sympy__sympy-13031');
    expect(tasks[0].prompt, contains('latex printer'));
    expect(tasks[0].expectSuccess, isTrue);
  });

  test('baris korup dan problem_statement kosong di-skip (fail-soft)',
      () async {
    final path = writeDataset('mixed.jsonl', [
      '{json rusak tanpa penutup',
      jsonEncode({'instance_id': 'x__y-1', 'problem_statement': '   '}),
      jsonEncode({'problem_statement': 'Hanya prompt tanpa instance_id'}),
      jsonEncode({'instance_id': 'z__z-9', 'problem_statement': 'soal nyata'}),
    ]);
    final tasks = await specsFromSwebenchFile(path);
    expect(tasks, hasLength(2));
    expect(tasks[0].id, 'swebench-3');
    expect(tasks[1].id, 'swebench-z__z-9');
    expect(tasks[1].prompt, 'soal nyata');
  });

  test('limit membatasi jumlah kasus (maks 200)', () async {
    final lines = [
      for (var i = 1; i <= 10; i++)
        jsonEncode({
          'instance_id': 'repo__issue-$i',
          'problem_statement': 'soal $i',
        }),
    ];
    final path = writeDataset('limit.jsonl', lines);
    expect(await specsFromSwebenchFile(path, limit: 3), hasLength(3));
    expect(await specsFromSwebenchFile(path, limit: 0), hasLength(1));
    expect(await specsFromSwebenchFile(path, limit: 999), hasLength(10));
  });

  test('subsetRepo hanya menyertakan repo yang cocok', () async {
    final path = writeDataset('repos.jsonl', [
      jsonEncode({
        'instance_id': 'a__b-1',
        'problem_statement': 'soal a',
        'repo': 'django/django',
      }),
      jsonEncode({
        'instance_id': 'c__d-2',
        'problem_statement': 'soal c',
        'repo': 'sympy/sympy',
      }),
    ]);
    final tasks = await specsFromSwebenchFile(path, subsetRepo: 'django/django');
    expect(tasks, hasLength(1));
    expect(tasks.single.id, 'swebench-a__b-1');
  });

  test('dataset tidak ada -> kosong, bukan error', () async {
    expect(
        await specsFromSwebenchFile(p.join(temp!.path, 'tidak-ada.jsonl')),
        isEmpty);
  });

  test('runSwebenchReplay: dataset jadi gate eval + baseline comparison',
      () async {
    final path = writeDataset('replay.jsonl', [
      jsonEncode({
        'instance_id': 'mock__case-1',
        'problem_statement': 'jawab pertanyaan sederhana',
      }),
      jsonEncode({
        'instance_id': 'mock__case-2',
        'problem_statement': 'hitung sesuatu',
      }),
    ]);
    final report = await runSwebenchReplay(
      rt!,
      datasetPath: path,
      outPath: p.join(temp!.path, 'swebench-report.json'),
    );
    expect(report['scenario'], 'swebench-replay');
    expect(report['dataset_path'], path);
    expect((report['total'] as num).toInt(), 2);
    expect(report['report_path'], isNotNull);

    final current =
        jsonDecode(File(p.join(temp!.path, 'swebench-report.json')).readAsStringSync())
            as Map<String, dynamic>;
    final baseline = await runSwebenchReplay(
      rt!,
      datasetPath: path,
    );
    final compared = compareEvalReports(current: current, baseline: baseline);
    expect(compared['gate_passed'], isTrue);
    expect(compared['regressed'], isEmpty);
  });

  test('runSwebenchReplay: baseline tidak ada -> ArgumentError', () async {
    final path = writeDataset('single.jsonl', [
      jsonEncode({'instance_id': 'x', 'problem_statement': 'soal'}),
    ]);
    await expectLater(
      runSwebenchReplay(rt!, datasetPath: path, baselinePath: '/nonexistent/b.json'),
      throwsArgumentError,
    );
  });
}
