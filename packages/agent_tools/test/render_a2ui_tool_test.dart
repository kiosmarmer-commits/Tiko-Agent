import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  const tool = RenderA2uiTool();
  final ctx = ToolContext(
    session: Session(id: 's1', channel: 'test', userKey: 'tester'),
    workspacePath: '/tmp',
  );

  final validMessages = [
    {
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-chip',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['m1', 'b1'],
          },
          {'id': 'm1', 'component': 'Metric', 'label': 'CPU', 'value': '87%'},
          {
            'id': 'b1',
            'component': 'Button',
            'label': 'Jalankan pemeriksaan',
            'action': {'name': 'run_diag', 'payload': {'t': 'cpu'}},
          },
        ],
      },
    },
  ];

  test('pesanan valid menghasilkan blok a2ui yang bisa diekstrak', () async {
    final res = await tool.run({'messages': validMessages}, ctx);
    expect(res.isError, isFalse);
    final blocks = extractA2uiBlocks(res.content);
    expect(blocks, hasLength(1));
    expect(blocks.first.messages.single, isA<A2uiCreateSurface>());
    expect(res.content, contains('s-chip'));
  });

  test('menerima JSONL string sebagai masukan', () async {
    final jsonl = jsonEncode(validMessages.first);
    final res = await tool.run({'messages': jsonl}, ctx);
    expect(res.isError, isFalse);
    expect(extractA2uiBlocks(res.content), hasLength(1));
  });

  test('pesan tidak valid ditolak fail-closed tanpa blok UI', () async {
    final res = await tool.run({
      'messages': [
        {
          'version': '1.0',
          'createSurface': {
            'surfaceId': 'bad',
            'components': [
              {'id': 'root', 'component': 'Webview', 'src': 'http://evil'},
            ],
          },
        },
      ],
    }, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('render_a2ui ulang'));
    expect(extractA2uiBlocks(res.content), isEmpty);
  });

  test('update mandiri lolos validasi tool — urutan divalidasi saat apply',
      () async {
    final res = await tool.run({
      'messages': [
        {
          'version': '1.0',
          'updateComponents': {
            'surfaceId': 'ghost',
            'components': [
              {'id': 'root', 'component': 'Divider'},
            ],
          },
        },
      ],
    }, ctx);
    expect(res.isError, isFalse);
    expect(extractA2uiBlocks(res.content), isNotEmpty);
  });

  test('messages kosong ditolak', () async {
    final res = await tool.run(const {}, ctx);
    expect(res.isError, isTrue);
  });

  test('tool terdaftar dengan nama render_a2ui dan risk medium', () {
    expect(tool.spec.name, 'render_a2ui');
    expect(tool.spec.risk, 'medium');
  });

  test('roundtrip: keluaran tool parse ulang menjadi pesan sama', () async {
    final res = await tool.run({'messages': validMessages}, ctx);
    final body = extractA2uiBlocks(res.content).first.messages;
    final set = A2uiSurfaceSet();
    expect(() => set.apply(body), returnsNormally);
    expect(set.surface('s-chip'), isNotNull);
  });
}
