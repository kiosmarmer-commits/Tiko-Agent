import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'cdp_browser.dart';

/// Browser CDP (Chrome DevTools Protocol) tool for direct low-level browser control.
///
/// This tool provides direct access to Chrome DevTools Protocol commands,
/// allowing for fine-grained control over browser behavior.
///
/// Configuration:
/// - chromePath: Path to Chrome/Chromium executable
/// - headless: Run browser in headless mode (default: true)
/// - timeout: Command timeout (default: 30 seconds)
/// - wsEndpoint: Explicit CDP WebSocket endpoint (optional)
class BrowserCdpTool implements Tool {
  BrowserCdpTool({
    this.chromePath,
    this.headless = true,
    this.timeout = const Duration(seconds: 30),
    this.wsEndpoint,
    this.maxResultBytes = 64 * 1024,
  });

  final String? chromePath;
  final bool headless;
  final Duration timeout;
  final String? wsEndpoint;
  final int maxResultBytes;

  CdpSession? _session;

  @override
  String get name => 'browser_cdp';

  @override
  String get description =>
      'Direct Chrome DevTools Protocol tool for low-level browser automation. '
      'Allows executing raw CDP commands for advanced browser control.';

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
                'execute_cdp',
                'navigate',
                'get_content',
                'evaluate',
                'screenshot',
              ],
              'description': 'The CDP action to perform',
            },
            'method': {
              'type': 'string',
              'description': 'CDP method name (for execute_cdp action)',
            },
            'params': {
              'type': 'object',
              'description': 'CDP method parameters (for execute_cdp action)',
            },
            'url': {
              'type': 'string',
              'description': 'URL to navigate to',
            },
            'expression': {
              'type': 'string',
              'description': 'JavaScript expression to evaluate',
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(ToolCall call) async {
    try {
      final action = call.args['action'] as String?;
      
      switch (action) {
        case 'open':
          _session = CdpSession(
            chromePath: chromePath,
            headless: headless,
            timeout: timeout,
            wsEndpoint: wsEndpoint,
            maxResultBytes: maxResultBytes,
          );
          await _session!.open();
          return ToolResult(
            content: jsonEncode({'status': 'opened', 'session_id': _session!.sessionId}),
            isError: false,
          );

        case 'close':
          if (_session != null) {
            await _session!.close();
            _session = null;
          }
          return ToolResult(
            content: jsonEncode({'status': 'closed'}),
            isError: false,
          );

        case 'execute_cdp':
          if (_session == null) {
            return ToolResult(
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final method = call.args['method'] as String?;
          final params = call.args['params'] as Map<String, dynamic>? ?? {};
          
          if (method == null || method.isEmpty) {
            return ToolResult(
              content: jsonEncode({'error': 'method is required'}),
              isError: true,
            );
          }
          
          final result = await _session!.sendCommand(method, params);
          return ToolResult(
            content: jsonEncode({'result': result}),
            isError: false,
          );

        case 'navigate':
          if (_session == null) {
            return ToolResult(
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final url = call.args['url'] as String?;
          if (url == null || url.isEmpty) {
            return ToolResult(
              content: jsonEncode({'error': 'url is required'}),
              isError: true,
            );
          }
          await _session!.navigate(url);
          return ToolResult(
            content: jsonEncode({'status': 'navigated', 'url': url}),
            isError: false,
          );

        case 'get_content':
          if (_session == null) {
            return ToolResult(
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final content = await _session!.getContent();
          return ToolResult(
            content: jsonEncode({'content': content}),
            isError: false,
          );

        case 'evaluate':
          if (_session == null) {
            return ToolResult(
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final expression = call.args['expression'] as String?;
          if (expression == null || expression.isEmpty) {
            return ToolResult(
              content: jsonEncode({'error': 'expression is required'}),
              isError: true,
            );
          }
          final result = await _session!.evaluate(expression);
          return ToolResult(
            content: jsonEncode({'result': result}),
            isError: false,
          );

        case 'screenshot':
          if (_session == null) {
            return ToolResult(
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final screenshot = await _session!.screenshot();
          return ToolResult(
            content: jsonEncode({'screenshot': screenshot}),
            isError: false,
          );

        default:
          return ToolResult(
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }
}
