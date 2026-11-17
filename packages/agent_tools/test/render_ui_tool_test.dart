import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  const tool = RenderUiTool();
  final ctx = ToolContext(
    session: Session(id: 's1', channel: 'test', userKey: 'tester'),
    workspacePath: '/tmp',
  );

  test('spesifikasi valid menghasilkan blok genui yang bisa diekstrak',
      () async {
    final res = await tool.run({
      'spec': {
        'type': 'section',
        'title': 'Ringkasan',
        'children': [
          {'type': 'metric', 'label': 'Total', 'value': 42},
        ],
      },
    }, ctx);
    expect(res.isError, isFalse);
    final blocks = extractGenUiBlocks(res.content);
    expect(blocks, hasLength(1));
    expect(blocks.first.spec.root.type, 'section');
    expect(blocks.first.spec.nodeCount, 2);
  });

  test('spesifikasi tidak valid ditolak fail-closed tanpa blok UI', () async {
    final res = await tool.run({
      'spec': {'type': 'webview', 'src': 'http://evil'},
    }, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('tipe tidak dikenal'));
    expect(res.content, contains('render_ui ulang'));
    expect(extractGenUiBlocks(res.content), isEmpty);
  });

  test('spec kosong ditolak', () async {
    final res = await tool.run(const {}, ctx);
    expect(res.isError, isTrue);
  });

  test('tool terdaftar dengan risk low dan nama render_ui', () {
    expect(tool.spec.name, 'render_ui');
    expect(tool.spec.risk, 'low');
  });
}
