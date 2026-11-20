import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Firecrawl Browser tool for web scraping and browser automation.
///
/// Firecrawl is a web scraping service that provides browser automation
/// capabilities for crawling and extracting data from websites.
///
/// Configuration:
/// - apiKey: Firecrawl API key (required)
/// - baseUrl: Firecrawl API base URL (default: https://api.firecrawl.dev)
/// - timeout: Request timeout (default: 60 seconds)
class FirecrawlBrowserTool implements Tool {
  FirecrawlBrowserTool({
    required this.apiKey,
    this.baseUrl = 'https://api.firecrawl.dev',
    this.timeout = const Duration(seconds: 60),
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  String? _sessionId;

  @override
  String get name => 'firecrawl_browser';

  @override
  String get description =>
      'Firecrawl Browser tool for web scraping and browser automation.';

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
                'create_session',
                'close_session',
                'navigate',
                'click',
                'type',
                'wait_for_selector',
                'get_text',
                'get_attribute',
                'execute_script',
                'take_screenshot',
                'get_html',
                'go_back',
                'go_forward',
                'reload',
                'get_title',
                'get_url',
                'scrape',
              ],
              'description': 'The Firecrawl Browser action to perform',
            },
            'url': {
              'type': 'string',
              'description': 'URL to navigate to or scrape',
            },
            'selector': {
              'type': 'string',
              'description': 'CSS selector for element actions',
            },
            'text': {
              'type': 'string',
              'description': 'Text to type',
            },
            'attribute': {
              'type': 'string',
              'description': 'Attribute name to get',
            },
            'script': {
              'type': 'string',
              'description': 'JavaScript code to execute',
            },
            'session_id': {
              'type': 'string',
              'description': 'Session ID to use (optional, uses current if not provided)',
            },
            'timeout': {
              'type': 'number',
              'description': 'Timeout in milliseconds for wait actions',
            },
            'scrape_options': {
              'type': 'object',
              'description': 'Options for scrape action',
              'properties': {
                'format': {'type': 'string', 'enum': ['markdown', 'html', 'text']},
                'include_headers': {'type': 'boolean'},
                'include_footer': {'type': 'boolean'},
              },
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
        case 'create_session':
          return await _createSession(call);
        case 'close_session':
          return await _closeSession(call);
        case 'navigate':
          return await _navigate(call);
        case 'click':
          return await _click(call);
        case 'type':
          return await _type(call);
        case 'wait_for_selector':
          return await _waitForSelector(call);
        case 'get_text':
          return await _getText(call);
        case 'get_attribute':
          return await _getAttribute(call);
        case 'execute_script':
          return await _executeScript(call);
        case 'take_screenshot':
          return await _takeScreenshot(call);
        case 'get_html':
          return await _getHtml(call);
        case 'go_back':
          return await _goBack(call);
        case 'go_forward':
          return await _goForward(call);
        case 'reload':
          return await _reload(call);
        case 'get_title':
          return await _getTitle(call);
        case 'get_url':
          return await _getUrl(call);
        case 'scrape':
          return await _scrape(call);
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

  Future<ToolResult> _createSession(ToolCall call) async {
    try {
      final response = await _makeRequest(
        'POST',
        '/v0/sessions',
        {
          'browser': 'chrome',
          'headless': true,
        },
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _sessionId = data['id'] as String?;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'created',
          'session_id': _sessionId,
          'session_url': data['url'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to create session: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _closeSession(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      await _makeRequest('DELETE', '/v0/sessions/$sessionId', null);
      if (_sessionId == sessionId) {
        _sessionId = null;
      }
      
      return ToolResult(
        content: jsonEncode({'status': 'closed', 'session_id': sessionId}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to close session: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _navigate(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final url = call.args['url'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (url == null || url.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'url is required'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/navigate',
        {'url': url},
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'navigated', 'url': url}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to navigate: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _click(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final selector = call.args['selector'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'selector is required'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/click',
        {'selector': selector},
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'clicked', 'selector': selector}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to click: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _type(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final selector = call.args['selector'] as String?;
      final text = call.args['text'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty || text == null) {
        return ToolResult(
          content: jsonEncode({'error': 'selector and text are required'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/type',
        {'selector': selector, 'text': text},
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'typed', 'selector': selector, 'text': text}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to type: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _waitForSelector(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final selector = call.args['selector'] as String?;
      final timeoutMs = call.args['timeout'] as num? ?? 5000;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'selector is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/wait_for_selector',
        {'selector': selector, 'timeout': timeoutMs},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final found = data['found'] as bool? ?? false;
      
      return ToolResult(
        content: jsonEncode({'status': 'waited', 'selector': selector, 'found': found}),
        isError: !found,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to wait for selector: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getText(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final selector = call.args['selector'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'selector is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/get_text',
        {'selector': selector},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = data['text'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'retrieved', 'selector': selector, 'text': text}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get text: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getAttribute(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final selector = call.args['selector'] as String?;
      final attribute = call.args['attribute'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty || attribute == null || attribute.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'selector and attribute are required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/get_attribute',
        {'selector': selector, 'attribute': attribute},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final value = data['value'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'retrieved', 'selector': selector, 'attribute': attribute, 'value': value}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get attribute: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _executeScript(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      final script = call.args['script'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (script == null || script.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'script is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/execute_script',
        {'script': script},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = data['result'];
      
      return ToolResult(
        content: jsonEncode({'status': 'executed', 'result': result}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to execute script: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _takeScreenshot(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/screenshot',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final screenshot = data['screenshot'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'captured', 'screenshot': screenshot}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to take screenshot: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getHtml(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/get_html',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final html = data['html'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'retrieved', 'html': html}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get HTML: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _goBack(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/go_back',
        null,
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'navigated_back'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to go back: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _goForward(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/go_forward',
        null,
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'navigated_forward'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to go forward: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _reload(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/reload',
        null,
      );
      
      return ToolResult(
        content: jsonEncode({'status': 'reloaded'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to reload: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getTitle(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/get_title',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final title = data['title'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'retrieved', 'title': title}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get title: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getUrl(ToolCall call) async {
    try {
      final sessionId = call.args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/sessions/$sessionId/get_url',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final url = data['url'] as String?;
      
      return ToolResult(
        content: jsonEncode({'status': 'retrieved', 'url': url}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get URL: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _scrape(ToolCall call) async {
    try {
      final url = call.args['url'] as String?;
      final options = call.args['scrape_options'] as Map<String, dynamic>?;
      
      if (url == null || url.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'url is required for scrape'}),
          isError: true,
        );
      }
      
      final requestBody = <String, dynamic>{
        'url': url,
        'format': options?['format'] ?? 'markdown',
      };
      
      if (options != null) {
        if (options.containsKey('include_headers')) {
          requestBody['includeHeaders'] = options['include_headers'];
        }
        if (options.containsKey('include_footer')) {
          requestBody['includeFooter'] = options['include_footer'];
        }
      }
      
      final response = await _makeRequest(
        'POST',
        '/v0/scrape',
        requestBody,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'scraped',
          'url': url,
          'content': data['content'],
          'format': data['format'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to scrape: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<http.Response> _makeRequest(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    
    final client = http.Client();
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers)
        ..body = body != null ? jsonEncode(body) : null;
      
      final response = await client.send(request).timeout(timeout);
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode >= 400) {
        throw Exception('HTTP ${response.statusCode}: $responseBody');
      }
      
      return http.Response(responseBody, response.statusCode);
    } finally {
      client.close();
    }
  }
}
