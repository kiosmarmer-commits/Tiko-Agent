import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('ACP resources are listed and read from the real registry', () async {
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(enableAcp: false),
    );
    await manager.start();
    final listed = await manager.handleAcpRequest(
      AcpMessage(
        id: '1',
        type: AcpMessageType.request,
        requestType: AcpRequestType.listResources,
      ),
    );
    final resources = listed.payload!['resources'] as List<dynamic>;
    expect(resources, isNotEmpty);
    expect(resources.any((r) => (r as Map)['uri'] == 'tiko://status'), isTrue);

    final read = await manager.handleAcpRequest(
      AcpMessage(
        id: '2',
        type: AcpMessageType.request,
        requestType: AcpRequestType.readResource,
        payload: {'uri': 'tiko://status'},
      ),
    );
    expect(read.type, AcpMessageType.response);
    expect(read.payload!['content'], contains('isRunning'));

    final write = await manager.handleAcpRequest(
      AcpMessage(
        id: '3',
        type: AcpMessageType.request,
        requestType: AcpRequestType.writeResource,
        payload: {'uri': 'tiko://status', 'content': 'bad'},
      ),
    );
    expect(write.type, AcpMessageType.error);
    await manager.stop();
  });

  test('ACP unsupported command fails closed', () async {
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(enableAcp: false),
    );
    final result = await manager.handleAcpRequest(
      AcpMessage(
        id: '4',
        type: AcpMessageType.request,
        requestType: AcpRequestType.executeCommand,
        payload: {'command': 'shell.exec'},
      ),
    );
    expect(result.payload!['success'], isFalse);
  });
}
