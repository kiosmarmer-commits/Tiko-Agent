import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'cdp_browser.dart';

/// BrowserUse tool for advanced browser automation.
///
/// BrowserUse is a tool that provides high-level browser automation
/// capabilities similar to the BrowserUse library.
///
/// Configuration:
/// - chromePath: Path to Chrome/Chromium executable
/// - headless: Run browser in headless mode (default: true)
/// - timeout: Command timeout (default: 30 seconds)
class BrowserUseTool implements Tool {
  BrowserUseTool({
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
  String get name => 'browseruse';

  @override
  String get description =>
      'BrowserUse tool for advanced browser automation with high-level commands.';

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
                'navigate',
                'click',
                'type',
                'select',
                'wait_for_selector',
                'wait_for_navigation',
                'go_back',
                'go_forward',
                'reload',
                'get_title',
                'get_url',
                'get_text',
                'get_attribute',
                'execute_script',
                'take_screenshot',
                'get_html',
              ],
              'description': 'The BrowserUse action to perform',
            },
            'url': {
              'type': 'string',
              'description': 'URL to navigate to',
            },
            'selector': {
              'type': 'string',
              'description': 'CSS selector for element actions',
            },
            'text': {
              'type': 'string',
              'description': 'Text to type or select option',
            },
            'attribute': {
              'type': 'string',
              'description': 'Attribute name to get',
            },
            'script': {
              'type': 'string',
              'description': 'JavaScript code to execute',
            },
            'timeout': {
              'type': 'number',
              'description': 'Timeout in milliseconds for wait actions',
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

        case 'navigate':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final url = args['url'] as String?;
          if (url == null || url.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'url is required'}),
              isError: true,
            );
          }
          await _session!.navigate(url);
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'navigated', 'url': url}),
            isError: false,
          );

        case 'click':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          if (selector == null || selector.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector is required'}),
              isError: true,
            );
          }
          await _session!.evaluate('''
            (function() {
              const element = document.querySelector('$selector');
              if (element) {
                element.click();
                return true;
              }
              return false;
            })()
          ''');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'clicked', 'selector': selector}),
            isError: false,
          );

        case 'type':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          final text = args['text'] as String?;
          if (selector == null || selector.isEmpty || text == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector and text are required'}),
              isError: true,
            );
          }
          await _session!.evaluate('''
            (function() {
              const element = document.querySelector('$selector');
              if (element) {
                element.value = '$text';
                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
              return false;
            })()
          ''');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'typed', 'selector': selector, 'text': text}),
            isError: false,
          );

        case 'select':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          final text = args['text'] as String?;
          if (selector == null || selector.isEmpty || text == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector and text are required'}),
              isError: true,
            );
          }
          await _session!.evaluate('''
            (function() {
              const element = document.querySelector('$selector');
              if (element && element.tagName === 'SELECT') {
                const option = element.querySelector('option[value="$text"]') || 
                               Array.from(element.options).find(opt => opt.text === '$text');
                if (option) {
                  option.selected = true;
                  element.dispatchEvent(new Event('change', { bubbles: true }));
                  return true;
                }
              }
              return false;
            })()
          ''');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'selected', 'selector': selector, 'value': text}),
            isError: false,
          );

        case 'wait_for_selector':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          final timeoutMs = args['timeout'] as num? ?? 5000;
          if (selector == null || selector.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector is required'}),
              isError: true,
            );
          }
          final found = await _waitForSelector(selector, timeoutMs);
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'found', 'selector': selector, 'found': found}),
            isError: !found,
          );

        case 'get_title':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final title = await _session!.evaluate('document.title');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'title': title}),
            isError: false,
          );

        case 'get_url':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final url = await _session!.evaluate('window.location.href');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'url': url}),
            isError: false,
          );

        case 'get_text':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          if (selector == null || selector.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector is required'}),
              isError: true,
            );
          }
          final text = await _session!.evaluate('''
            (function() {
              const element = document.querySelector('$selector');
              return element ? element.textContent : null;
            })()
          ''');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'selector': selector, 'text': text}),
            isError: false,
          );

        case 'get_attribute':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final selector = args['selector'] as String?;
          final attribute = args['attribute'] as String?;
          if (selector == null || selector.isEmpty || attribute == null || attribute.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'selector and attribute are required'}),
              isError: true,
            );
          }
          final value = await _session!.evaluate('''
            (function() {
              const element = document.querySelector('$selector');
              return element ? element.getAttribute('$attribute') : null;
            })()
          ''');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'selector': selector, 'attribute': attribute, 'value': value}),
            isError: false,
          );

        case 'execute_script':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final script = args['script'] as String?;
          if (script == null || script.isEmpty) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'script is required'}),
              isError: true,
            );
          }
          final result = await _session!.evaluate(script);
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'executed', 'result': result}),
            isError: false,
          );

        case 'take_screenshot':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final screenshot = await _session!.screenshot();
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'captured', 'screenshot': screenshot}),
            isError: false,
          );

        case 'get_html':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final html = await _session!.getContent();
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'retrieved', 'html': html}),
            isError: false,
          );

        case 'go_back':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          await _session!.evaluate('window.history.back()');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'navigated_back'}),
            isError: false,
          );

        case 'go_forward':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          await _session!.evaluate('window.history.forward()');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'navigated_forward'}),
            isError: false,
          );

        case 'reload':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          await _session!.evaluate('window.location.reload()');
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'reloaded'}),
            isError: false,
          );

        case 'wait_for_navigation':
          if (_session == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({'error': 'Session not opened. Call open first.'}),
              isError: true,
            );
          }
          final timeoutMs = args['timeout'] as num? ?? 5000;
          // Wait for navigation to complete
          await Future.delayed(Duration(milliseconds: timeoutMs.toInt()));
          return ToolResult(
            callId: '',
            content: jsonEncode({'status': 'navigation_completed'}),
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

  Future<bool> _waitForSelector(String selector, num timeoutMs) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start).inMilliseconds < timeoutMs) {
      try {
        final result = await _session!.evaluate('''
          (function() {
            return document.querySelector('$selector') !== null;
          })()
        ''');
        if (result == true) {
          return true;
        }
      } catch (e) {
        // Ignore errors and continue waiting
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }
}
