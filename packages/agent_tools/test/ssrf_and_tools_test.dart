import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');
  final ctx = ToolContext(session: session, workspacePath: '.');

  test('SSRF blocks localhost', () async {
    final g = SsrfGuard();
    expect(await g.checkUrl('http://127.0.0.1/'), isNotNull);
    expect(await g.checkUrl('http://localhost/'), isNotNull);
    expect(await g.checkUrl('http://169.254.169.254/latest'), isNotNull);
  });

  test('SSRF allows public-looking host (DNS may vary)', () async {
    final g = SsrfGuard();
    // example.com should resolve public
    final err = await g.checkUrl('https://example.com/');
    // May be null (allowed) depending on network in CI
    expect(
      err == null || err.contains('DNS') || err.contains('resolve'),
      isTrue,
    );
  });

  test('shell rejects metachar', () async {
    final tool = ShellTool();
    final r = await tool.run({'cmd': 'ls; rm -rf /'}, ctx);
    expect(r.isError, isTrue);
    expect(r.content, contains('Metacharacter'));
  });

  test('calc (2+3)*4', () async {
    final tool = CalcTool();
    final r = await tool.run({'expression': '(2+3)*4'}, ctx);
    expect(r.isError, isFalse);
    expect(r.content, contains('"value":"20"'));
  });

  test('registry includes new tools', () {
    final reg = ToolRegistry();
    reg.registerAll(createBuiltinTools(workspaceRoot: '.'));
    expect(
      reg.names,
      containsAll(['web_fetch', 'shell', 'write_file', 'read_file']),
    );
  });
}
