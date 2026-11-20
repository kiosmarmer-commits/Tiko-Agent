import 'dart:convert';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('Home Assistant lists entities and executes services', () async {
    final client = _Client((request) {
      if (request.url.path == '/api/states') {
        return _response([
          {
            'entity_id': 'light.kitchen',
            'state': 'on',
            'attributes': {'friendly_name': 'Kitchen'},
          },
        ]);
      }
      expect(request.url.path, '/api/services/light/turn_off');
      expect(jsonDecode((request as http.Request).body), {
        'entity_id': 'light.kitchen',
      });
      return _response({});
    });
    final provider = HomeAssistantSmartHomeProvider(
      baseUrl: 'http://ha.test/',
      accessToken: 'token',
      client: client,
    );

    final devices = await provider.listDevices();
    expect(devices.single.name, 'Kitchen');
    await provider.execute('light.kitchen', {
      'service': 'light.turn_off',
      'entity_id': 'light.kitchen',
    });
  });

  test('Tuya signs requests and sends device commands', () async {
    final client = _Client((request) {
      expect(request.headers['client_id'], 'client');
      expect(request.headers['access_token'], 'access');
      expect(request.headers['sign_method'], 'HMAC-SHA256');
      expect(request.headers['sign'], isNotEmpty);
      expect(request.url.path, '/v1.0/devices/device-1/commands');
      expect(jsonDecode((request as http.Request).body), {
        'commands': [
          {'code': 'switch_1', 'value': true},
        ],
      });
      return _response({'success': true, 'result': true});
    });
    final provider = TuyaSmartHomeProvider(
      clientId: 'client',
      clientSecret: 'secret',
      accessToken: 'access',
      baseUrl: 'http://tuya.test',
      client: client,
    );
    await provider.execute('device-1', {
      'commands': [
        {'code': 'switch_1', 'value': true},
      ],
    });
  });

  test('eWeLink maps device list and controls state', () async {
    final client = _Client((request) {
      if (request.method == 'GET') {
        return _response({
          'error': 0,
          'data': {
            'device_list': [
              {
                'serial_number': 'sonoff-1',
                'name': 'Plug',
                'display_category': 'plug',
                'online': true,
                'state': {
                  'power': {'powerState': 'on'},
                },
                'capabilities': [
                  {'capability': 'power'},
                ],
              },
            ],
          },
        });
      }
      expect(request.method, 'PUT');
      expect(request.url.path, '/open-api/v2/rest/devices/sonoff-1');
      expect(jsonDecode((request as http.Request).body), {
        'state': {
          'power': {'powerState': 'off'},
        },
      });
      return _response({'error': 0, 'data': {}});
    });
    final provider = EwelinkCubeSmartHomeProvider(
      baseUrl: 'http://ewelink.test',
      accessToken: 'token',
      client: client,
    );
    expect((await provider.listDevices()).single.capabilities, ['power']);
    await provider.execute('sonoff-1', {
      'power': {'powerState': 'off'},
    });
  });
}

http.Response _response(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Client extends http.BaseClient {
  _Client(this.handler);
  final http.Response Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}
