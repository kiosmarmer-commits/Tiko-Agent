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

  String get name => 'firecrawl_browser';

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
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String?;
      
      switch (action) {
        case 'create_session':
          return await _createSession(args, ctx);
        case 'close_session':
          return await _closeSession(args, ctx);
        case 'navigate':
          return await _navigate(args, ctx);
        case 'click':
          return await _click(args, ctx);
        case 'type':
          return await _type(args, ctx);
        case 'wait_for_selector':
          return await _waitForSelector(args, ctx);
        case 'get_text':
          return await _getText(args, ctx);
        case 'get_attribute':
          return await _getAttribute(args, ctx);
        case 'execute_script':
          return await _executeScript(args, ctx);
        case 'take_screenshot':
          return await _takeScreenshot(args, ctx);
        case 'get_html':
          return await _getHtml(args, ctx);
        case 'go_back':
          return await _goBack(args, ctx);
        case 'go_forward':
          return await _goForward(args, ctx);
        case 'reload':
          return await _reload(args, ctx);
        case 'get_title':
          return await _getTitle(args, ctx);
        case 'get_url':
          return await _getUrl(args, ctx);
        case 'scrape':
          return await _scrape(args, ctx);
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

  Future<ToolResult> _createSession(Map<String, dynamic> args, ToolContext ctx) async {
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
        callId: '',
        content: jsonEncode({
          'status': 'created',
          'session_id': _sessionId,
          'session_url': data['url'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create session: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _closeSession(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      
      await _makeRequest('DELETE', '/v0/sessions/$sessionId', null);
      if (_sessionId == sessionId) {
        _sessionId = null;
      }
      
      return ToolResult(
        callId: '',
        content: jsonEncode({'status': 'closed', 'session_id': sessionId}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to close session: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _navigate(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final url = args['url'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (url == null || url.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'navigated', 'url': url}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to navigate: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _click(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final selector = args['selector'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'clicked', 'selector': selector}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to click: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _type(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final selector = args['selector'] as String?;
      final text = args['text'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty || text == null) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'typed', 'selector': selector, 'text': text}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to type: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _waitForSelector(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final selector = args['selector'] as String?;
      final timeoutMs = args['timeout'] as num? ?? 5000;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'waited', 'selector': selector, 'found': found}),
        isError: !found,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to wait for selector: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getText(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final selector = args['selector'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'retrieved', 'selector': selector, 'text': text}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get text: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getAttribute(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final selector = args['selector'] as String?;
      final attribute = args['attribute'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (selector == null || selector.isEmpty || attribute == null || attribute.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'retrieved', 'selector': selector, 'attribute': attribute, 'value': value}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get attribute: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _executeScript(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      final script = args['script'] as String?;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No active session'}),
          isError: true,
        );
      }
      if (script == null || script.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'executed', 'result': result}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to execute script: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _takeScreenshot(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'captured', 'screenshot': screenshot}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to take screenshot: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getHtml(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'retrieved', 'html': html}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get HTML: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _goBack(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'navigated_back'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to go back: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _goForward(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'navigated_forward'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to go forward: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _reload(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'reloaded'}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to reload: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getTitle(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'retrieved', 'title': title}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get title: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getUrl(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String? ?? _sessionId;
      
      if (sessionId == null || sessionId.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
        content: jsonEncode({'status': 'retrieved', 'url': url}),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get URL: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _scrape(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final url = args['url'] as String?;
      final options = args['scrape_options'] as Map<String, dynamic>?;
      
      if (url == null || url.isEmpty) {
        return ToolResult(
          callId: '',
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
        callId: '',
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
        callId: '',
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
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      
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
