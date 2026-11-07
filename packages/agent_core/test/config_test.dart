import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('parse agent yaml subset', () {
    const yaml = '''
agent:
  max_iterations: 7
security:
  mode: ask
  shell_allowlist: ["ls", "pwd"]
search:
  searxng_base_url: "http://127.0.0.1:8080"
http:
  domain_allowlist: ["example.com"]
workspace: "/tmp/ws"
''';
    final c = AppConfig.parse(yaml);
    expect(c.maxIterations, 7);
    expect(c.shellAllowlist, contains('ls'));
    expect(c.searxngBaseUrl, contains('8080'));
    expect(c.httpDomainAllowlist, contains('example.com'));
    expect(c.workspace, '/tmp/ws');
  });
}
