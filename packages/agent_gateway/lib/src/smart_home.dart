import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Normalized smart-home device shared by Home Assistant, Tuya and eWeLink.
class SmartDevice {
  const SmartDevice({
    required this.id,
    required this.name,
    required this.provider,
    this.category,
    this.online,
    this.capabilities = const [],
    this.state = const {},
    this.meta = const {},
  });

  final String id;
  final String name;
  final String provider;
  final String? category;
  final bool? online;
  final List<String> capabilities;
  final Map<String, Object?> state;
  final Map<String, Object?> meta;
}

class SmartDeviceEvent {
  const SmartDeviceEvent({
    required this.deviceId,
    required this.state,
    this.online,
    this.raw = const {},
  });

  final String deviceId;
  final Map<String, Object?> state;
  final bool? online;
  final Map<String, Object?> raw;
}

abstract interface class SmartHomeProvider {
  String get name;
  Stream<SmartDeviceEvent> get events;
  Future<List<SmartDevice>> listDevices();
  Future<SmartDevice> getDevice(String deviceId);
  Future<void> execute(String deviceId, Map<String, Object?> command);
  Future<void> close();
}

abstract class _HttpSmartHomeProvider implements SmartHomeProvider {
  _HttpSmartHomeProvider({http.Client? client})
    : client = client ?? http.Client();

  final http.Client client;
  final _events = StreamController<SmartDeviceEvent>.broadcast();

  @override
  Stream<SmartDeviceEvent> get events => _events.stream;

  void emit(SmartDeviceEvent event) => _events.add(event);

  @override
  Future<void> close() async {
    await _events.close();
    client.close();
  }
}

/// Home Assistant REST + WebSocket smart-home provider.
///
/// This is also the recommended Google Home integration path: connect Google
/// Home to Home Assistant, then Tiko sees those entities through one provider.
class HomeAssistantSmartHomeProvider extends _HttpSmartHomeProvider {
  HomeAssistantSmartHomeProvider({
    required String baseUrl,
    required this.accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.allowedEntityIds = const {},
  }) : baseUrl = _trimBaseUrl(baseUrl),
       super(client: client);

  final String baseUrl;
  final String accessToken;
  final Duration timeout;
  final Set<String> allowedEntityIds;
  WebSocket? _socket;

  @override
  String get name => 'home_assistant';

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  bool _allowed(String id) =>
      allowedEntityIds.isEmpty || allowedEntityIds.contains(id);

  @override
  Future<List<SmartDevice>> listDevices() async {
    final response = await client
        .get(Uri.parse('$baseUrl/api/states'), headers: _headers)
        .timeout(timeout);
    _check(response, 'list states');
    final raw = jsonDecode(response.body) as List<dynamic>;
    return [
      for (final item in raw)
        if (item is Map<String, dynamic> &&
            item['entity_id'] is String &&
            _allowed(item['entity_id'] as String))
          _device(item),
    ];
  }

  @override
  Future<SmartDevice> getDevice(String deviceId) async {
    _requireAllowed(deviceId);
    final response = await client
        .get(Uri.parse('$baseUrl/api/states/$deviceId'), headers: _headers)
        .timeout(timeout);
    _check(response, 'get state');
    return _device(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> execute(String deviceId, Map<String, Object?> command) async {
    _requireAllowed(deviceId);
    final service = command['service']?.toString();
    if (service == null || !service.contains('.')) {
      throw ArgumentError(
        'Home Assistant command membutuhkan service domain.service',
      );
    }
    final parts = service.split('.');
    final data = <String, Object?>{
      ...?command['data'] as Map<String, Object?>?,
      if (command['entity_id'] != null) 'entity_id': command['entity_id'],
    };
    final response = await client
        .post(
          Uri.parse('$baseUrl/api/services/${parts[0]}/${parts[1]}'),
          headers: _headers,
          body: jsonEncode(data),
        )
        .timeout(timeout);
    _check(response, 'execute $service');
  }

  /// Subscribes to Home Assistant `state_changed` events over WebSocket.
  Future<void> startEvents() async {
    if (_socket != null) return;
    final uri = Uri.parse(
      baseUrl.replaceFirst(RegExp('^http'), 'ws') + '/api/websocket',
    );
    final socket = await WebSocket.connect(uri.toString());
    _socket = socket;
    var nextId = 1;
    final auth = await socket.first;
    if (auth is! String ||
        (jsonDecode(auth) as Map)['type'] != 'auth_required') {
      throw StateError('Home Assistant WebSocket auth_required tidak diterima');
    }
    socket.add(jsonEncode({'type': 'auth', 'access_token': accessToken}));
    final authOk = await socket.first;
    if (authOk is! String || (jsonDecode(authOk) as Map)['type'] != 'auth_ok') {
      throw StateError('Home Assistant WebSocket authentication gagal');
    }
    socket.add(
      jsonEncode({
        'id': nextId++,
        'type': 'subscribe_events',
        'event_type': 'state_changed',
      }),
    );
    socket.listen((message) {
      if (message is! String) return;
      final json = jsonDecode(message);
      final event = json is Map ? json['event'] : null;
      final data = event is Map ? event['data'] : null;
      final entity = data is Map ? data['entity_id'] : null;
      final newState = data is Map ? data['new_state'] : null;
      if (entity is String && newState is Map && _allowed(entity)) {
        emit(
          SmartDeviceEvent(
            deviceId: entity,
            state: {
              'state': newState['state'],
              ...?newState['attributes'] as Map<String, Object?>?,
            },
            raw: Map<String, Object?>.from(data),
          ),
        );
      }
    });
  }

  @override
  Future<void> close() async {
    await _socket?.close();
    _socket = null;
    await super.close();
  }

  SmartDevice _device(Map<String, dynamic> raw) {
    final id = raw['entity_id'] as String;
    final attributes = raw['attributes'] is Map
        ? Map<String, Object?>.from(raw['attributes'] as Map)
        : <String, Object?>{};
    return SmartDevice(
      id: id,
      name: attributes['friendly_name']?.toString() ?? id,
      provider: name,
      category: id.split('.').first,
      online: raw['state']?.toString() != 'unavailable',
      state: {'state': raw['state'], ...attributes},
      meta: raw,
    );
  }

  void _requireAllowed(String id) {
    if (!_allowed(id))
      throw StateError('Home Assistant entity tidak diizinkan: $id');
  }

  static void _check(http.Response response, String operation) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Home Assistant $operation gagal: HTTP ${response.statusCode} ${response.body}',
      );
    }
  }
}

/// Tuya Cloud OpenAPI provider with the official HMAC-SHA256 request signing.
class TuyaSmartHomeProvider extends _HttpSmartHomeProvider {
  TuyaSmartHomeProvider({
    required this.clientId,
    required this.clientSecret,
    required this.accessToken,
    this.baseUrl = 'https://openapi.tuyaus.com',
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.allowedDeviceIds = const {},
  }) : super(client: client);

  final String clientId;
  final String clientSecret;
  final String accessToken;
  final String baseUrl;
  final Duration timeout;
  final Set<String> allowedDeviceIds;

  @override
  String get name => 'tuya';

  @override
  Future<List<SmartDevice>> listDevices() async {
    final json = await _request('GET', '/v1.0/iot-03/devices');
    final items = _list(json['result']);
    return [
      for (final item in items)
        if (item['id'] != null && _allowed(item['id'].toString()))
          SmartDevice(
            id: item['id'].toString(),
            name: item['name']?.toString() ?? item['id'].toString(),
            provider: name,
            category: item['category']?.toString(),
            online: item['online'] as bool?,
            state: _map(item['status']),
            meta: item,
          ),
    ];
  }

  @override
  Future<SmartDevice> getDevice(String deviceId) async {
    _requireAllowed(deviceId);
    final json = await _request('GET', '/v1.0/devices/$deviceId/status');
    return SmartDevice(
      id: deviceId,
      name: deviceId,
      provider: name,
      online: true,
      state: _map(json['result']),
      meta: json,
    );
  }

  @override
  Future<void> execute(String deviceId, Map<String, Object?> command) async {
    _requireAllowed(deviceId);
    final commands = command['commands'] ?? [command];
    await _request(
      'POST',
      '/v1.0/devices/$deviceId/commands',
      body: {'commands': commands},
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final encoded = body == null ? '' : jsonEncode(body);
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final contentHash = sha256.convert(utf8.encode(encoded)).toString();
    final stringToSign = '$method\n$contentHash\n\n$path';
    final signInput = '$clientId$accessToken$timestamp$stringToSign';
    final sign = Hmac(
      sha256,
      utf8.encode(clientSecret),
    ).convert(utf8.encode(signInput)).toString().toUpperCase();
    final headers = {
      'client_id': clientId,
      'access_token': accessToken,
      't': timestamp,
      'sign_method': 'HMAC-SHA256',
      'sign': sign,
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse('$baseUrl$path');
    final response = method == 'GET'
        ? await client.get(uri, headers: headers).timeout(timeout)
        : await client
              .post(uri, headers: headers, body: encoded)
              .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Tuya HTTP ${response.statusCode}: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['success'] == false) {
      throw StateError('Tuya API error: ${json['msg'] ?? json['code']}');
    }
    return json;
  }

  bool _allowed(String id) =>
      allowedDeviceIds.isEmpty || allowedDeviceIds.contains(id);

  void _requireAllowed(String id) {
    if (!_allowed(id)) throw StateError('Tuya device tidak diizinkan: $id');
  }

  static List<Map<String, dynamic>> _list(dynamic value) {
    if (value is List) return value.whereType<Map<String, dynamic>>().toList();
    if (value is Map && value['list'] is List) {
      return (value['list'] as List).whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }

  static Map<String, Object?> _map(dynamic value) => value is Map
      ? Map<String, Object?>.fromEntries(
          value.entries.map((e) => MapEntry(e.key.toString(), e.value)),
        )
      : {};
}

/// eWeLink CUBE/iHost local provider for SONOFF and bridged devices.
class EwelinkCubeSmartHomeProvider extends _HttpSmartHomeProvider {
  EwelinkCubeSmartHomeProvider({
    required String baseUrl,
    required this.accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.allowedDeviceIds = const {},
  }) : baseUrl = _trimBaseUrl(baseUrl),
       super(client: client);

  final String baseUrl;
  final String accessToken;
  final Duration timeout;
  final Set<String> allowedDeviceIds;
  HttpClient? _sseClient;

  @override
  String get name => 'ewelink_cube';

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  @override
  Future<List<SmartDevice>> listDevices() async {
    final json = await _request('GET', '/open-api/v2/rest/devices');
    final data = json['data'] is Map ? json['data'] as Map : const {};
    final list = data['device_list'] is List
        ? data['device_list'] as List
        : const [];
    return [
      for (final raw in list)
        if (raw is Map && raw['serial_number'] != null)
          _device(Map<String, dynamic>.from(raw)),
    ];
  }

  @override
  Future<SmartDevice> getDevice(String deviceId) async {
    _requireAllowed(deviceId);
    final json = await _request('GET', '/open-api/v2/rest/devices/$deviceId');
    final data = json['data'] as Map<String, dynamic>;
    return _device(data);
  }

  @override
  Future<void> execute(String deviceId, Map<String, Object?> command) async {
    _requireAllowed(deviceId);
    await _request(
      'PUT',
      '/open-api/v2/rest/devices/$deviceId',
      body: {'state': command['state'] ?? command},
    );
  }

  Future<void> startEvents() async {
    if (_sseClient != null) return;
    final sseClient = HttpClient();
    _sseClient = sseClient;
    final request = await sseClient.getUrl(
      Uri.parse(
        '$baseUrl/open-api/v2/sse/bridge?access_token=${Uri.encodeQueryComponent(accessToken)}',
      ),
    );
    final response = await request.close();
    () async {
      String? eventName;
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('event:')) eventName = line.substring(6).trim();
        if (line.startsWith('data:')) {
          final raw = jsonDecode(line.substring(5).trim());
          if (raw is Map) {
            final payload = raw['payload'] is Map ? raw['payload'] as Map : raw;
            final id = payload['serial_number']?.toString();
            if (id != null && _allowed(id)) {
              emit(
                SmartDeviceEvent(
                  deviceId: id,
                  state: payload['state'] is Map
                      ? Map<String, Object?>.from(payload['state'] as Map)
                      : const {},
                  online: payload['online'] as bool?,
                  raw: {
                    'event': eventName,
                    ...Map<String, Object?>.from(payload),
                  },
                ),
              );
            }
          }
        }
      }
    }();
  }

  @override
  Future<void> close() async {
    _sseClient?.close(force: true);
    _sseClient = null;
    await super.close();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final response = method == 'GET'
        ? await client.get(uri, headers: _headers).timeout(timeout)
        : await client
              .put(uri, headers: _headers, body: jsonEncode(body ?? {}))
              .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'eWeLink CUBE HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['error'] != null && json['error'] != 0) {
      throw StateError(
        'eWeLink CUBE API error: ${json['message'] ?? json['error']}',
      );
    }
    return json;
  }

  SmartDevice _device(Map<String, dynamic> raw) {
    final id = raw['serial_number'].toString();
    return SmartDevice(
      id: id,
      name: raw['name']?.toString() ?? id,
      provider: name,
      category: raw['display_category']?.toString(),
      online: raw['online'] as bool?,
      capabilities: [
        for (final c in raw['capabilities'] as List? ?? const [])
          if (c is Map && c['capability'] != null) c['capability'].toString(),
      ],
      state: raw['state'] is Map
          ? Map<String, Object?>.from(raw['state'] as Map)
          : const {},
      meta: raw,
    );
  }

  bool _allowed(String id) =>
      allowedDeviceIds.isEmpty || allowedDeviceIds.contains(id);

  void _requireAllowed(String id) {
    if (!_allowed(id)) throw StateError('eWeLink device tidak diizinkan: $id');
  }
}

String _trimBaseUrl(String value) =>
    value.endsWith('/') ? value.substring(0, value.length - 1) : value;
