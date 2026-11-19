import 'dart:async';
import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  group('TeamsGateway', () {
    test('channel is teams', () {
      final gateway = TeamsGateway(webhookUrl: 'https://example.com/webhook');
      expect(gateway.channel, 'teams');
    });

    test('inbound stream is broadcast', () {
      final gateway = TeamsGateway(webhookUrl: 'https://example.com/webhook');
      expect(gateway.inbound.isBroadcast, isTrue);
    });

    test('pushInbound adds message to stream', () async {
      final gateway = TeamsGateway(webhookUrl: 'https://example.com/webhook');
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      gateway.pushInbound(
        userKey: 'user123',
        sessionKey: 'session456',
        text: 'Hello from Teams',
      );

      await untilCalled(subscription.onData);
      expect(messages.length, 1);
      expect(messages[0].text, 'Hello from Teams');
      expect(messages[0].channel, 'teams');
      expect(messages[0].userKey, 'user123');

      await subscription.cancel();
    });

    test('sendTyping is no-op', () async {
      final gateway = TeamsGateway(webhookUrl: 'https://example.com/webhook');
      await gateway.sendTyping('session123');
      // Should not throw
    });

    test('close closes inbound stream', () async {
      final gateway = TeamsGateway(webhookUrl: 'https://example.com/webhook');
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      await gateway.close();

      // Stream should be closed
      expect(subscription.isPaused, isTrue);
      await subscription.cancel();
    });
  });

  group('LineGateway', () {
    test('channel is line', () {
      final gateway = LineGateway(
        channelAccessToken: 'test-token',
        channelSecret: 'test-secret',
      );
      expect(gateway.channel, 'line');
    });

    test('inbound stream is broadcast', () {
      final gateway = LineGateway(
        channelAccessToken: 'test-token',
        channelSecret: 'test-secret',
      );
      expect(gateway.inbound.isBroadcast, isTrue);
    });

    test('pushInbound adds message to stream', () async {
      final gateway = LineGateway(
        channelAccessToken: 'test-token',
        channelSecret: 'test-secret',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      gateway.pushInbound(
        webhookData: {
          'events': [
            {
              'type': 'message',
              'message': {'text': 'Hello from LINE'},
              'source': {'userId': 'user123'},
            },
          ],
        },
      );

      await untilCalled(subscription.onData);
      expect(messages.length, 1);
      expect(messages[0].text, 'Hello from LINE');
      expect(messages[0].channel, 'line');

      await subscription.cancel();
    });

    test('sendTyping is no-op', () async {
      final gateway = LineGateway(
        channelAccessToken: 'test-token',
        channelSecret: 'test-secret',
      );
      await gateway.sendTyping('session123');
      // Should not throw
    });

    test('close closes inbound stream', () async {
      final gateway = LineGateway(
        channelAccessToken: 'test-token',
        channelSecret: 'test-secret',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      await gateway.close();

      expect(subscription.isPaused, isTrue);
      await subscription.cancel();
    });
  });

  group('SmsGateway', () {
    test('channel is sms', () {
      final gateway = SmsGateway.twilio(
        fromNumber: '+1234567890',
        accountSid: 'test-sid',
        authToken: 'test-token',
      );
      expect(gateway.channel, 'sms');
    });

    test('inbound stream is broadcast', () {
      final gateway = SmsGateway.twilio(
        fromNumber: '+1234567890',
        accountSid: 'test-sid',
        authToken: 'test-token',
      );
      expect(gateway.inbound.isBroadcast, isTrue);
    });

    test('pushInbound adds message to stream', () async {
      final gateway = SmsGateway.twilio(
        fromNumber: '+1234567890',
        accountSid: 'test-sid',
        authToken: 'test-token',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      gateway.pushInbound(
        fromNumber: '+1987654321',
        toNumber: '+1234567890',
        text: 'Hello from SMS',
      );

      await untilCalled(subscription.onData);
      expect(messages.length, 1);
      expect(messages[0].text, 'Hello from SMS');
      expect(messages[0].channel, 'sms');

      await subscription.cancel();
    });

    test('sendTyping is no-op', () async {
      final gateway = SmsGateway.twilio(
        fromNumber: '+1234567890',
        accountSid: 'test-sid',
        authToken: 'test-token',
      );
      await gateway.sendTyping('session123');
      // Should not throw
    });

    test('close closes inbound stream', () async {
      final gateway = SmsGateway.twilio(
        fromNumber: '+1234567890',
        accountSid: 'test-sid',
        authToken: 'test-token',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      await gateway.close();

      expect(subscription.isPaused, isTrue);
      await subscription.cancel();
    });
  });

  group('MattermostGateway', () {
    test('channel is mattermost', () {
      final gateway = MattermostGateway(
        serverUrl: 'https://mattermost.example.com',
        token: 'test-token',
      );
      expect(gateway.channel, 'mattermost');
    });

    test('inbound stream is broadcast', () {
      final gateway = MattermostGateway(
        serverUrl: 'https://mattermost.example.com',
        token: 'test-token',
      );
      expect(gateway.inbound.isBroadcast, isTrue);
    });

    test('pushInbound adds message to stream', () async {
      final gateway = MattermostGateway(
        serverUrl: 'https://mattermost.example.com',
        token: 'test-token',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      gateway.pushInbound(
        webhookData: {
          'user_id': 'user123',
          'channel_id': 'channel456',
          'text': 'Hello from Mattermost',
          'post_id': 'post789',
          'team_id': 'team012',
        },
      );

      await untilCalled(subscription.onData);
      expect(messages.length, 1);
      expect(messages[0].text, 'Hello from Mattermost');
      expect(messages[0].channel, 'mattermost');

      await subscription.cancel();
    });

    test('sendTyping is no-op', () async {
      final gateway = MattermostGateway(
        serverUrl: 'https://mattermost.example.com',
        token: 'test-token',
      );
      await gateway.sendTyping('session123');
      // Should not throw
    });

    test('close closes inbound stream', () async {
      final gateway = MattermostGateway(
        serverUrl: 'https://mattermost.example.com',
        token: 'test-token',
      );
      final messages = <InboundMessage>[];
      final subscription = gateway.inbound.listen(messages.add);

      await gateway.close();

      expect(subscription.isPaused, isTrue);
      await subscription.cancel();
    });
  });
}
