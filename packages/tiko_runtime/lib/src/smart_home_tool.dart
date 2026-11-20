import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';

/// Exposes configured smart-home providers through one approval-gated tool.
class SmartHomeTool implements Tool {
  SmartHomeTool(this.providers);

  final Map<String, SmartHomeProvider> providers;

  /// Builds providers from environment variables without accepting raw YAML secrets.
  factory SmartHomeTool.fromEnvironment(Map<String, String> env) {
    final result = <String, SmartHomeProvider>{};
    final haUrl = env['TIKO_HOME_ASSISTANT_URL']?.trim();
    final haToken = env['TIKO_HOME_ASSISTANT_TOKEN']?.trim();
    if (haUrl != null &&
        haUrl.isNotEmpty &&
        haToken != null &&
        haToken.isNotEmpty) {
      result['home_assistant'] = HomeAssistantSmartHomeProvider(
        baseUrl: haUrl,
        accessToken: haToken,
      );
    }
    final tuyaId = env['TIKO_TUYA_CLIENT_ID']?.trim();
    final tuyaSecret = env['TIKO_TUYA_CLIENT_SECRET']?.trim();
    final tuyaToken = env['TIKO_TUYA_ACCESS_TOKEN']?.trim();
    if (tuyaId != null &&
        tuyaId.isNotEmpty &&
        tuyaSecret != null &&
        tuyaSecret.isNotEmpty &&
        tuyaToken != null &&
        tuyaToken.isNotEmpty) {
      result['tuya'] = TuyaSmartHomeProvider(
        clientId: tuyaId,
        clientSecret: tuyaSecret,
        accessToken: tuyaToken,
        baseUrl:
            env['TIKO_TUYA_BASE_URL']?.trim() ?? 'https://openapi.tuyaus.com',
      );
    }
    final ewUrl = env['TIKO_EWELINK_URL']?.trim();
    final ewToken = env['TIKO_EWELINK_TOKEN']?.trim();
    if (ewUrl != null &&
        ewUrl.isNotEmpty &&
        ewToken != null &&
        ewToken.isNotEmpty) {
      result['ewelink_cube'] = EwelinkCubeSmartHomeProvider(
        baseUrl: ewUrl,
        accessToken: ewToken,
      );
    }
    return SmartHomeTool(result);
  }

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'smart_home',
    description: 'List, inspect, or control an allowlisted smart-home device.',
    risk: 'high',
    timeoutSec: 30,
    inputSchema: {
      'type': 'object',
      'additionalProperties': false,
      'required': ['action'],
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'get', 'execute'],
        },
        'provider': {'type': 'string'},
        'device_id': {'type': 'string'},
        'command': {'type': 'object'},
      },
    },
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action']?.toString();
    final providerName = args['provider']?.toString();
    if (providers.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'No smart-home provider is configured.',
        isError: true,
      );
    }
    final provider = providerName == null
        ? (providers.length == 1 ? providers.values.single : null)
        : providers[providerName];
    if (provider == null) {
      return ToolResult(
        callId: '',
        content: providerName == null
            ? 'provider is required when more than one smart-home provider is configured'
            : 'Unknown smart-home provider: $providerName',
        isError: true,
      );
    }
    try {
      switch (action) {
        case 'list':
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'provider': provider.name,
              'devices': (await provider.listDevices()).map(_device).toList(),
            }),
          );
        case 'get':
        case 'execute':
          final deviceId = args['device_id']?.toString();
          if (deviceId == null || deviceId.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'device_id is required',
              isError: true,
            );
          }
          if (action == 'get') {
            return ToolResult(
              callId: '',
              content: jsonEncode(_device(await provider.getDevice(deviceId))),
            );
          }
          final raw = args['command'];
          if (raw is! Map) {
            return const ToolResult(
              callId: '',
              content: 'command object is required',
              isError: true,
            );
          }
          await provider.execute(deviceId, Map<String, Object?>.from(raw));
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'ok': true,
              'provider': provider.name,
              'device_id': deviceId,
            }),
          );
        default:
          return const ToolResult(
            callId: '',
            content: 'action must be list, get, or execute',
            isError: true,
          );
      }
    } catch (error) {
      return ToolResult(
        callId: '',
        content: 'smart-home operation failed: $error',
        isError: true,
      );
    }
  }

  /// Closes all configured provider resources.
  Future<void> close() async {
    for (final provider in providers.values) {
      await provider.close();
    }
  }

  static Map<String, Object?> _device(SmartDevice device) => {
    'id': device.id,
    'name': device.name,
    'provider': device.provider,
    'category': device.category,
    'online': device.online,
    'capabilities': device.capabilities,
    'state': device.state,
    'meta': device.meta,
  };
}
