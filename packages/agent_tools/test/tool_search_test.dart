import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

ToolSpec _spec(String name, String description) => ToolSpec(
      name: name,
      description: description,
      inputSchema: const {'type': 'object'},
    );

void main() {
  test('rankToolSpecs scores name matches above description matches',
      () async {
    final specs = [
      _spec('read_file', 'Baca isi file dari workspace'),
      _spec('web_search', 'Cari di web dengan search engine'),
      _spec('memory_search', 'Cari memori tersimpan'),
      _spec('calc', 'Kalkulasi angka'),
    ];
    final ranked = rankToolSpecs(specs, 'cari file lama', k: 3);
    expect(ranked.first.name, 'read_file');
    expect(ranked.map((s) => s.name), contains('memory_search'));
  });

  test('rankToolSpecs falls back to the first k tools on an empty query',
      () {
    final specs = [
      _spec('a_tool', 'x'),
      _spec('b_tool', 'y'),
    ];
    expect(rankToolSpecs(specs, '   ', k: 1).single.name, 'a_tool');
  });

  test('ToolSearchTool returns matching schemas as JSON', () async {
    final specs = [
      _spec('read_file', 'Baca isi file'),
      _spec('write_file', 'Tulis file'),
    ];
    final tool = ToolSearchTool(() => specs);
    final ctx = ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: '/tmp',
    );
    final result = await tool.run({'query': 'tulis file'}, ctx);
    expect(result.isError, isFalse);
    expect(result.content, contains('write_file'));
    // write_file ranks first (name + description match); read_file may also
    // match on the shared "file" token but never above it.
    expect(result.content.indexOf('write_file'),
        lessThan(result.content.indexOf('read_file')));
  });

  test('ToolSearchTool rejects an empty query', () async {
    final tool = ToolSearchTool(() => const []);
    final ctx = ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: '/tmp',
    );
    final result = await tool.run({'query': '  '}, ctx);
    expect(result.isError, isTrue);
  });
}
