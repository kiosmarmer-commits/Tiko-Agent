import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-sop', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

void main() {
  late String dataDir;
  late String workspace;

  setUp(() async {
    dataDir = await Directory.systemTemp
        .createTemp('sop_test')
        .then((d) => d.path);
    workspace = dataDir;
  });

  tearDown(() async {
    await Directory(dataDir).delete(recursive: true);
  });

  SopTool newTool({SopRunTeam? runTeam}) =>
      SopTool(store: SopStore(path: '$dataDir/sop_templates.json'), runTeam: runTeam);

  test('SOP-1: seed \u2014 dua template generik tersedia saat pertama', () async {
    final tool = newTool();
    final result = await tool.run({'action': 'list'}, _ctx(workspace));
    expect(result.content, contains('bugfix-delivery'));
    expect(result.content, contains('feature-delivery'));
  });

  test('SOP-2: show \u2014 detail roles + steps; id tak dikenal \u2192 error',
      () async {
    final tool = newTool();
    final show = await tool.run(
      {'action': 'show', 'id': 'bugfix-delivery'},
      _ctx(workspace),
    );
    expect(show.content, contains('investigator'));
    expect(show.content, contains('Reproduksi'));
    final missing = await tool.run(
      {'action': 'show', 'id': 'tidak-ada'},
      _ctx(workspace),
    );
    expect(missing.isError, isTrue);
  });

  test('SOP-3: create valid tersimpan + persist; invalid ditolak', () async {
    final tool = newTool();
    final template = const JsonEncoder().convert({
      'id': 'review-doc',
      'name': 'Review Dokumen',
      'roles': [
        {'name': 'author'},
        {'name': 'editor', 'responsibility': 'cek struktur'},
      ],
      'steps': [
        {'title': 'Draft', 'role': 'author'},
        {'title': 'Review', 'role': 'editor', 'outputs': ['catatan']},
      ],
    });
    final created = await tool.run(
      {'action': 'create', 'template': template},
      _ctx(workspace),
    );
    expect(created.isError, isFalse);
    final persisted = newTool();
    final list = await persisted.run({'action': 'list'}, _ctx(workspace));
    expect(list.content, contains('review-doc'));

    final invalid = await tool.run(
      {
        'action': 'create',
        'template': const JsonEncoder().convert({
          'id': 'BAD ID',
          'name': 'X',
          'roles': [],
          'steps': [],
        }),
      },
      _ctx(workspace),
    );
    expect(invalid.isError, isTrue);
  });

  test('SOP-4: run tanpa execute \u2014 render rencana deterministik tanpa LLM',
      () async {
    final tool = newTool();
    final result = await tool.run(
      {
        'action': 'run',
        'id': 'bugfix-delivery',
        'goal': 'Perbaiki parser config yang gagal',
      },
      _ctx(workspace),
    );
    expect(result.isError, isFalse);
    expect(result.content, contains('# SOP: Bugfix Delivery'));
    expect(result.content, contains('Perbaiki parser config yang gagal'));
    expect(result.content, contains('## Langkah'));
  });

  test('SOP-5: run execute via bot team callback', () async {
    var called = 0;
    final tool = newTool(runTeam: (goal, sopMd) async {
      called++;
      return {'ok': true, 'goal': goal};
    });
    final result = await tool.run(
      {
        'action': 'run',
        'id': 'feature-delivery',
        'goal': 'Tambah fitur ekspor',
        'execute': true,
      },
      _ctx(workspace),
    );
    expect(called, 1);
    expect(result.content, contains('"ok": true'));
    expect(result.content, contains('Tambah fitur ekspor'));
  });

  test('SOP-6: delete \u2014 idempoten jujur', () async {
    final tool = newTool();
    final ok = await tool.run(
      {'action': 'delete', 'id': 'bugfix-delivery'},
      _ctx(workspace),
    );
    expect(ok.isError, isFalse);
    final gone = await tool.run(
      {'action': 'delete', 'id': 'bugfix-delivery'},
      _ctx(workspace),
    );
    expect(gone.isError, isTrue);
  });
}
