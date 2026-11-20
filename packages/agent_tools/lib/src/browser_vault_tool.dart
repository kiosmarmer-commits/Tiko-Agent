import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'cdp_browser.dart';

/// Browser Vault tool for secure credential management in browser automation.
///
/// This tool allows agents to securely store and retrieve credentials
/// for use in browser automation tasks.
///
/// Configuration:
/// - chromePath: Path to Chrome/Chromium executable
/// - headless: Run browser in headless mode (default: true)
/// - timeout: Command timeout (default: 30 seconds)
class BrowserVaultTool implements Tool {
  BrowserVaultTool({
    this.chromePath,
    this.headless = true,
    this.timeout = const Duration(seconds: 30),
    this.wsEndpoint,
  });

  final String? chromePath;
  final bool headless;
  final Duration timeout;
  final String? wsEndpoint;

  CdpSession? _session;
  final _vault = <String, String>{};

  String get name => 'browser_vault';

  String get description =>
      'Browser vault tool for secure credential management in web automation.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'open',
                'close',
                'store',
                'retrieve',
                'delete',
                'list',
                'fill_form',
              ],
              'description': 'The vault action to perform',
            },
            'key': {
              'type': 'string',
              'description': 'Key for storing/retrieving credentials',
            },
            'value': {
              'type': 'string',
              'description': 'Value to store',
            },
            'url': {
              'type': 'string',
              'description': 'URL to navigate to before filling form',
            },
            'form_data': {
              'type': 'object',
              'description': 'Form data as key-value pairs',
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String?;
      
      switch (action) {
        case 'open':
          _session = CdpSession(
            chromePath: chromePath,
            headless: headless,
            timeout: timeout,
            wsEndpoint: wsEndpoint,
          );
          await _session!.open();
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'opened', 'session_id': _session!.sessionId}),
            isError: false,
          );

        case 'close':
          if (_session != null) {
            await _session!.close();
            _session = null;
          }
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'closed'}),
            isError: false,
          );

        case 'store':
          final key = args['key'] as String?;
          final value = args['value'] as String?;
          if (key == null || key.isEmpty || value == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'key and value are required'}),
              isError: true,
            );
          }
          _vault[key] = value;
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'stored', 'key': key}),
            isError: false,
          );

        case 'retrieve':
          final key = args['key'] as String?;
          if (key == null || key.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'key is required'}),
              isError: true,
            );
          }
          final value = _vault[key];
          if (value == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'key not found'}),
              isError: true,
            );
          }
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'key': key, 'value': value}),
            isError: false,
          );

        case 'delete':
          final key = args['key'] as String?;
          if (key == null || key.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'key is required'}),
              isError: true,
            );
          }
          _vault.remove(key);
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'deleted', 'key': key}),
            isError: false,
          );

        case 'list':
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'status': 'listed',
              'keys': _vault.keys.toList(),
            }),
            isError: false,
          );

        case 'fill_form':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final url = args['url'] as String?;
          final formData = args['form_data'] as Map<String, dynamic>? ?? {};
          
          if (url != null && url.isNotEmpty) {
            await _session!.navigate(url);
          }
          
          // Fill form fields using CDP
          for (final entry in formData.entries) {
            final fieldName = entry.key;
            final fieldValue = entry.value.toString();
            
            // Try to find and fill the field
            await _session!.evaluate('''
              (function() {
                const field = document.querySelector('[name="$fieldName"], [id="$fieldName"], [data-testid="$fieldName"]');
                if (field) {
                  if (field.tagName === 'INPUT' || field.tagName === 'TEXTAREA' || field.tagName === 'SELECT') {
                    field.value = '$fieldValue';
                    if (field.tagName === 'SELECT') {
                      field.dispatchEvent(new Event('change'));
                    } else {
                      field.dispatchEvent(new Event('input', { bubbles: true }));
                    }
                    return true;
                  }
                }
                return false;
              })()
            ''');
          }
          
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'status': 'form_filled',
              'fields': formData.keys.toList(),
            }),
            isError: false,
          );

        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }
}
