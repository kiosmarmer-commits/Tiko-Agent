import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('web_search tool registered in builtins', () {
    final tools = createBuiltinTools(workspaceRoot: '.');
    expect(tools.map((t) => t.spec.name), contains('web_search'));
  });

  test('cache map exists', () {
    expect(WebSearchTool.cacheTtl, const Duration(hours: 1));
  });
}
