import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// F2 (docs/15 §3) — IdeIntegrationTool terhubung ke registry nyata:
/// daftar tool ACP dibaca live (termasuk tool yang diregistrasi belakangan).
void main() {
  test('manager baca tool live dari ToolRegistry', () async {
    final registry = ToolRegistry()
      ..registerAll([
        _StubTool('calc'),
        _StubTool('read_file'),
      ]);
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(enableAcp: false),
      toolRegistry: registry,
    );
    await manager.start();

    final capabilities = await manager.handleAcpRequest(AcpMessage(
      id: '1',
      type: AcpMessageType.request,
      requestType: AcpRequestType.capabilities,
    ));
    final tools =
        (capabilities.payload!['supportedTools'] as List<dynamic>).cast<String>();
    expect(tools, containsAll(['calc', 'read_file']));

    // Tool yang dimuat belakangan langsung terlihat (listing live).
    registry.register(_StubTool('code_context'));
    final listed = await manager.handleAcpRequest(AcpMessage(
      id: '2',
      type: AcpMessageType.request,
      requestType: AcpRequestType.listTools,
    ));
    final lateTools = (listed.payload!['tools'] as List<dynamic>)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(lateTools, contains('code_context'));

    final executed = await manager.handleAcpRequest(AcpMessage(
      id: '3',
      type: AcpMessageType.request,
      requestType: AcpRequestType.executeTool,
      payload: {
        'toolName': 'code_context',
        'args': {'action': 'map'},
      },
    ));
    expect(executed.type, AcpMessageType.response);
    expect(executed.payload!['success'], isTrue);
    await manager.stop();
  });

  test('IdeIntegrationTool menerima ToolRegistry (factory)', () {
    final registry = ToolRegistry()..register(_StubTool('calc'));
    final tool = IdeIntegrationToolFactory.create(
      toolRegistry: registry,
      workingDirectory: '.',
    );
    expect(tool.toolRegistry, same(registry));
  });
}

class _StubTool implements Tool {
  _StubTool(String name)
      : spec = ToolSpec(
          name: name,
          description: 'stub $name',
          inputSchema: {'type': 'object', 'properties': {}},
          risk: 'low',
          parallelSafe: true,
        );

  @override
  final ToolSpec spec;

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async =>
      const ToolResult(callId: '', content: 'stub-ok');
}
