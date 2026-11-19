// Test to verify all gateway imports work correctly
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('All gateways can be imported', () {
    // Just verify the classes exist and can be instantiated
    expect(TeamsGateway(webhookUrl: 'http://test.com'), isA<Gateway>());
    expect(LineGateway(channelAccessToken: 'token', channelSecret: 'secret'), isA<Gateway>());
    expect(SmsGateway.twilio(fromNumber: '+123', accountSid: 'sid', authToken: 'token'), isA<Gateway>());
    expect(MattermostGateway(serverUrl: 'http://test.com', token: 'token'), isA<Gateway>());
  });
}
