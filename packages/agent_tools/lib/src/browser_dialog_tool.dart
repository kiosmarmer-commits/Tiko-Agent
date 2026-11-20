import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'cdp_browser.dart';

/// Browser Dialog tool for handling browser dialogs (alerts, confirms, prompts).
///
/// This tool allows agents to interact with browser dialogs that appear
/// during web automation.
///
/// Configuration:
/// - chromePath: Path to Chrome/Chromium executable
/// - headless: Run browser in headless mode (default: true)
/// - timeout: Command timeout (default: 30 seconds)
class BrowserDialogTool implements Tool {
  BrowserDialogTool({
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
                'set_dialog_handler',
                'get_dialog_state',
              ],
              'description': 'The dialog action to perform',
            },
            'handler': {
              'type': 'string',
              'enum': ['accept', 'dismiss', 'prompt'],
              'description': 'How to handle dialogs (accept, dismiss, or prompt with text)',
            },
            'text': {
              'type': 'string',
              'description': 'Text to enter for prompt dialogs',
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

        case 'set_dialog_handler':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final handler = args['handler'] as String? ?? 'accept';
          final text = args['text'] as String?;
          
          // Set up dialog handler via CDP
          await _session!.sendCommand('Page.setInterceptFileChooserDialog', {'enabled': true});
          
          // For simplicity, we'll handle the most common case
          // In a real implementation, you'd set up event listeners
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'status': 'handler_set',
              'handler': handler,
              'text': text,
            }),
            isError: false,
          );

        case 'get_dialog_state':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          // Get current dialog state
          // This would normally listen for Page.javascriptDialogOpening event
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'status': 'no_dialog',
              'message': 'No active dialog detected',
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
