import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('web_search tool registered', () {
    final reg = ToolRegistry();
    reg.registerAll(createBuiltinTools(workspaceRoot: '.'));
    expect(reg.names, contains('web_search'));
  });

  test('web_search fails gracefully without SearXNG', () async {
    final tool = WebSearchTool(searxngBaseUrl: 'http://127.0.0.1:9');
    final session = Session(id: 's', channel: 'cli', userKey: 'u');
    final r = await tool.run({
      'query': 'test',
    }, ToolContext(session: session, workspacePath: '.'));
    expect(r.isError, isTrue);
  });

  test('MCP loader requires an explicit non-empty allowlist', () async {
    final registry = ToolRegistry();
    final loader = McpToolLoader(registry, sandbox: SandboxRunner());
    final loaded = await loader.loadServers([
      {'id': 'unrestricted', 'command': 'python3', 'args': ['-V'], 'allow': []},
    ]);
    expect(loaded, 0);
    expect(registry.names, isEmpty);
    expect(loader.statuses.single['status'], 'disabled');
  });

  test('MCP client refuses host execution without an OS sandbox', () async {
    final client = StdioMcpClient(command: 'python3', args: ['-V']);
    await expectLater(client.start(), throwsUnsupportedError);
    await client.close();
  });

  test('MCP stdio mock server tools/list and tools/call', () async {
    final serverPath =
        [
          'tools/mock_mcp_server/server.py',
          '../../tools/mock_mcp_server/server.py',
          '../../../tools/mock_mcp_server/server.py',
        ].firstWhere(
          (p) => File(p).existsSync(),
          orElse: () => 'tools/mock_mcp_server/server.py',
        );
    if (!File(serverPath).existsSync()) {
      // Skip if path not found from test cwd
      return;
    }
    final client = StdioMcpClient(
      command: 'python3',
      args: [serverPath],
      allowUnsandboxedForTesting: true,
    );
    try {
      await client.start();
      final tools = await client.listTools();
      client.allowedTools = tools.map((tool) => tool.name).toSet();
      expect(tools.map((t) => t.name), containsAll(['ping', 'echo']));
      final pong = await client.callTool('ping', {});
      expect(pong, contains('pong'));
      expect(pong, contains('untrusted_data'));
      final echo = await client.callTool('echo', {'text': 'halo'});
      expect(echo, contains('halo'));
    } finally {
      await client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('MCP stdio negotiates stateless 2026 protocol and uses per-request metadata', () async {
    final serverPath =
        [
          'tools/mock_mcp_server/server.py',
          '../../tools/mock_mcp_server/server.py',
          '../../../tools/mock_mcp_server/server.py',
        ].firstWhere(
          (p) => File(p).existsSync(),
          orElse: () => 'tools/mock_mcp_server/server.py',
        );
    if (!File(serverPath).existsSync()) return;
    final client = StdioMcpClient(
      command: 'python3',
      args: [serverPath, '--modern'],
      allowUnsandboxedForTesting: true,
    );
    try {
      await client.start();
      expect(client.serverName, 'modern-mock');
      final tools = await client.listTools();
      expect(tools.map((tool) => tool.name), containsAll(['ping', 'echo']));
      client.allowedTools = tools.map((tool) => tool.name).toSet();
      expect(await client.callTool('echo', {'text': 'modern'}), contains('modern'));
    } finally {
      await client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 15)));
}
