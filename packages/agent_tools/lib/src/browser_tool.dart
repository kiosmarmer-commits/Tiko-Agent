import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'cdp_browser.dart';
import 'sandbox.dart';

/// Browser automation tool that provides full web control capabilities.
///
/// This tool implements comprehensive browser automation similar to Hermes Agent,
/// including:
/// - Page navigation and interaction
/// - Form filling and submission
/// - Element extraction and manipulation
/// - Screenshot capture
/// - PDF generation
/// - Cookie management
/// - Network request interception
class BrowserTool implements Tool {
  BrowserTool({
    this.sandbox,
    this.chromePath,
    this.headless = true,
    this.timeout = const Duration(seconds: 30),
    this.maxResultBytes = 64 * 1024,
    this.allowPrivateUrls = false,
  });

  final SandboxRunner? sandbox;
  final String? chromePath;
  final bool headless;
  final Duration timeout;
  final int maxResultBytes;
  final bool allowPrivateUrls;

  CdpSession? _session;
  bool _isInitialized = false;

  String get name => 'browser';

  String get description =>
      'Browser automation tool for navigating, interacting with, and extracting data from web pages. '
      'Supports navigation, form filling, element extraction, screenshots, and more.';

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
                'navigate',
                'evaluate',
                'read_text',
                'click',
                'type',
                'fill_form',
                'submit_form',
                'extract_element',
                'extract_elements',
                'screenshot',
                'pdf',
                'wait_for_selector',
                'wait_for_navigation',
                'go_back',
                'go_forward',
                'reload',
                'get_title',
                'get_url',
                'get_cookies',
                'set_cookie',
                'delete_cookie',
                'close',
              ],
              'description': 'The browser action to perform',
            },
            'url': {
              'type': 'string',
              'description': 'URL to navigate to (for navigate action)',
            },
            'expression': {
              'type': 'string',
              'description': 'JavaScript expression to evaluate (for evaluate action)',
            },
            'selector': {
              'type': 'string',
              'description': 'CSS selector for element actions',
            },
            'text': {
              'type': 'string',
              'description': 'Text to type or fill (for type, fill_form actions)',
            },
            'form_data': {
              'type': 'object',
              'description': 'Form data as key-value pairs (for fill_form action)',
              'additionalProperties': {'type': 'string'},
            },
            'wait_timeout': {
              'type': 'integer',
              'description': 'Timeout in seconds for wait actions',
              'minimum': 1,
              'maximum': 60,
            },
            'screenshot_path': {
              'type': 'string',
              'description': 'Path to save screenshot (for screenshot action)',
            },
            'pdf_path': {
              'type': 'string',
              'description': 'Path to save PDF (for pdf action)',
            },
            'viewport_width': {
              'type': 'integer',
              'description': 'Viewport width for screenshot/PDF',
              'minimum': 100,
              'maximum': 10000,
            },
            'viewport_height': {
              'type': 'integer',
              'description': 'Viewport height for screenshot/PDF',
              'minimum': 100,
              'maximum': 10000,
            },
          },
          'required': ['action'],
        },
        parallelSafe: false, // Browser operations are not thread-safe
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final sw = Stopwatch()..start();
    final content = await execute(args);
    return ToolResult(
      callId: '',
      content: content,
      durationMs: sw.elapsedMilliseconds,
    );
  }

  Future<String> execute(Map<String, dynamic> arguments) async {
    try {
      final action = arguments['action'] as String?;
      
      if (action == null) {
        return jsonEncode({
          'success': false,
          'error': 'action is required',
        });
      }

      // Initialize session if needed
      await _ensureSession();

      final result = await _executeAction(action, arguments);
      
      return jsonEncode({
        'success': true,
        'result': result,
      });
    } catch (e) {
      return jsonEncode({
        'success': false,
        'error': e.toString(),
      });
    }
  }

  Future<void> _ensureSession() async {
    if (_isInitialized && _session != null) return;
    
    _session = CdpSession(
      chromePath: chromePath,
      headless: headless,
      timeout: timeout,
      allowPrivateUrls: allowPrivateUrls,
      maxResultBytes: maxResultBytes,
    );
    
    await _session!.open();
    _isInitialized = true;
  }

  Future<String> _executeAction(
    String action,
    Map<String, dynamic> arguments,
  ) async {
    final session = _session!;

    switch (action) {
      case 'navigate':
        final url = arguments['url'] as String?;
        if (url == null) throw ArgumentError('url is required for navigate');
        return await session.navigate(url);

      case 'evaluate':
        final expression = arguments['expression'] as String?;
        if (expression == null) throw ArgumentError('expression is required for evaluate');
        return await session.evaluate(expression);

      case 'read_text':
        return await session.readText();

      case 'click':
        final selector = arguments['selector'] as String?;
        if (selector == null) throw ArgumentError('selector is required for click');
        return await _clickElement(selector);

      case 'type':
        final selector = arguments['selector'] as String?;
        final text = arguments['text'] as String?;
        if (selector == null) throw ArgumentError('selector is required for type');
        if (text == null) throw ArgumentError('text is required for type');
        return await _typeText(selector, text);

      case 'fill_form':
        final formData = arguments['form_data'] as Map<String, dynamic>?;
        if (formData == null) throw ArgumentError('form_data is required for fill_form');
        return await _fillForm(formData);

      case 'submit_form':
        final selector = arguments['selector'] as String?;
        return await _submitForm(selector);

      case 'extract_element':
        final selector = arguments['selector'] as String?;
        if (selector == null) throw ArgumentError('selector is required for extract_element');
        return await _extractElement(selector);

      case 'extract_elements':
        final selector = arguments['selector'] as String?;
        if (selector == null) throw ArgumentError('selector is required for extract_elements');
        return await _extractElements(selector);

      case 'screenshot':
        final path = arguments['screenshot_path'] as String?;
        final width = arguments['viewport_width'] as int?;
        final height = arguments['viewport_height'] as int?;
        return await _takeScreenshot(path, width, height);

      case 'pdf':
        final path = arguments['pdf_path'] as String?;
        final width = arguments['viewport_width'] as int?;
        final height = arguments['viewport_height'] as int?;
        return await _generatePdf(path, width, height);

      case 'wait_for_selector':
        final selector = arguments['selector'] as String?;
        final timeout = arguments['wait_timeout'] as int? ?? 10;
        if (selector == null) throw ArgumentError('selector is required for wait_for_selector');
        return await _waitForSelector(selector, Duration(seconds: timeout));

      case 'wait_for_navigation':
        final timeout = arguments['wait_timeout'] as int? ?? 10;
        return await _waitForNavigation(Duration(seconds: timeout));

      case 'go_back':
        return await _goBack();

      case 'go_forward':
        return await _goForward();

      case 'reload':
        return await _reload();

      case 'get_title':
        return await _getTitle();

      case 'get_url':
        return await _getUrl();

      case 'get_cookies':
        return await _getCookies();

      case 'set_cookie':
        final name = arguments['name'] as String?;
        final value = arguments['value'] as String?;
        final url = arguments['url'] as String?;
        if (name == null || value == null) {
          throw ArgumentError('name and value are required for set_cookie');
        }
        return await _setCookie(name, value, url);

      case 'delete_cookie':
        final name = arguments['name'] as String?;
        final url = arguments['url'] as String?;
        if (name == null) throw ArgumentError('name is required for delete_cookie');
        return await _deleteCookie(name, url);

      case 'close':
        await _closeSession();
        return 'Browser session closed';

      default:
        throw ArgumentError('Unknown browser action: $action');
    }
  }

  Future<String> _clickElement(String selector) async {
    final js = '''
      const element = document.querySelector('$selector');
      if (!element) {
        throw new Error('Element not found: $selector');
      }
      element.click();
      return 'Clicked element: $selector';
    ''';
    return await _session!.evaluate(js);
  }

  Future<String> _typeText(String selector, String text) async {
    final js = '''
      const element = document.querySelector('$selector');
      if (!element) {
        throw new Error('Element not found: $selector');
      }
      element.focus();
      element.value = '${text.replaceAll("'", "\\'")}';
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
      return 'Typed text into element: $selector';
    ''';
    return await _session!.evaluate(js);
  }

  Future<String> _fillForm(Map<String, dynamic> formData) async {
    final jsEntries = formData.entries.map((e) =>
        "'{${e.key}}': '{${e.value.toString().replaceAll("'", "\\'")}}'"
    ).join(', ');
    
    final js = '''
      const data = { $jsEntries };
      let filledCount = 0;
      for (const [name, value] of Object.entries(data)) {
        const input = document.querySelector(\[name=\`\${name}\`\], input[name=\`\${name}\`], textarea[name=\`\${name}\`]);
        if (input) {
          input.value = value;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          filledCount++;
        }
      }
      return \`Filled \${filledCount} form fields\`;
    ''';
    return await _session!.evaluate(js);
  }

  Future<String> _submitForm(String? selector) async {
    final js = selector != null
        ? '''
          const form = document.querySelector('$selector');
          if (!form || form.tagName !== 'FORM') {
            throw new Error('Form not found: $selector');
          }
          form.submit();
          return 'Form submitted: $selector';
        '''
        : '''
          const forms = document.querySelectorAll('form');
          if (forms.length === 0) {
            throw new Error('No forms found on page');
          }
          forms[0].submit();
          return 'First form submitted';
        ''';
    return await _session!.evaluate(js);
  }

  Future<String> _extractElement(String selector) async {
    final js = '''
      const element = document.querySelector('$selector');
      if (!element) {
        throw new Error('Element not found: $selector');
      }
      return {
        tagName: element.tagName,
        textContent: element.textContent?.trim() || '',
        innerHTML: element.innerHTML,
        attributes: Object.fromEntries(
          Array.from(element.attributes).map(attr => [attr.name, attr.value])
        )
      };
    ''';
    return await _session!.evaluate(js);
  }

  Future<String> _extractElements(String selector) async {
    final js = '''
      const elements = document.querySelectorAll('$selector');
      return Array.from(elements).map((el, index) => ({
        index: index,
        tagName: el.tagName,
        textContent: el.textContent?.trim() || '',
        innerHTML: el.innerHTML.substring(0, 200) + (el.innerHTML.length > 200 ? '...' : ''),
      }));
    ''';
    return await _session!.evaluate(js);
  }

  Future<String> _takeScreenshot(
    String? path,
    int? width,
    int? height,
  ) async {
    // Set viewport size if specified
    if (width != null && height != null) {
      await _session!.send(
        'Emulation.setDeviceMetricsOverride',
        {
          'width': width,
          'height': height,
          'deviceScaleFactor': 1.0,
          'mobile': false,
        },
        sessionId: _session!.sessionId,
      );
    }

    // Capture screenshot
    final result = await _session!.send(
      'Page.captureScreenshot',
      {'format': 'png', 'quality': 90},
      sessionId: _session!.sessionId,
    );

    final data = result['result']?['data'] as String?;
    if (data == null) {
      throw StateError('Failed to capture screenshot');
    }

    // Decode base64 and save if path is specified
    final bytes = base64.decode(data);
    if (path != null) {
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsBytes(bytes);
      return 'Screenshot saved to $path (${bytes.length} bytes)';
    }

    // Return base64 encoded data
    return 'data:image/png;base64,$data';
  }

  Future<String> _generatePdf(String? path, int? width, int? height) async {
    // Set viewport size if specified
    if (width != null && height != null) {
      await _session!.send(
        'Emulation.setDeviceMetricsOverride',
        {
          'width': width,
          'height': height,
          'deviceScaleFactor': 1.0,
          'mobile': false,
        },
        sessionId: _session!.sessionId,
      );
    }

    // Generate PDF
    final result = await _session!.send(
      'Page.printToPDF',
      {
        'landscape': false,
        'displayHeaderFooter': false,
        'printBackground': true,
        'preferCSSPageSize': true,
      },
      sessionId: _session!.sessionId,
    );

    final data = result['result']?['data'] as String?;
    if (data == null) {
      throw StateError('Failed to generate PDF');
    }

    // Decode base64 and save if path is specified
    final bytes = base64.decode(data);
    if (path != null) {
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsBytes(bytes);
      return 'PDF saved to $path (${bytes.length} bytes)';
    }

    // Return base64 encoded data
    return 'data:application/pdf;base64,$data';
  }

  Future<String> _waitForSelector(String selector, Duration timeout) async {
    final start = DateTime.now();
    
    while (DateTime.now().difference(start) < timeout) {
      try {
        final js = '''
          const element = document.querySelector('$selector');
          return element ? 'found' : 'not found';
        ''';
        final result = await _session!.evaluate(js);
        if (result.contains('found')) {
          return 'Element $selector found';
        }
      } catch (e) {
        // Element not found yet
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    throw TimeoutException('Timed out waiting for selector: $selector');
  }

  Future<String> _waitForNavigation(Duration timeout) async {
    final start = DateTime.now();
    final initialUrl = await _getUrl();
    
    while (DateTime.now().difference(start) < timeout) {
      final currentUrl = await _getUrl();
      if (currentUrl != initialUrl) {
        return 'Navigated to $currentUrl';
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    throw TimeoutException('Timed out waiting for navigation');
  }

  Future<String> _goBack() async {
    await _session!.send(
      'Page.navigateToHistoryEntry',
      {'delta': -1},
      sessionId: _session!.sessionId,
    );
    return 'Navigated back in history';
  }

  Future<String> _goForward() async {
    await _session!.send(
      'Page.navigateToHistoryEntry',
      {'delta': 1},
      sessionId: _session!.sessionId,
    );
    return 'Navigated forward in history';
  }

  Future<String> _reload() async {
    await _session!.send(
      'Page.reload',
      {'ignoreCache': true},
      sessionId: _session!.sessionId,
    );
    return 'Page reloaded';
  }

  Future<String> _getTitle() async {
    return await _session!.evaluate('document.title');
  }

  Future<String> _getUrl() async {
    return await _session!.evaluate('window.location.href');
  }

  Future<String> _getCookies() async {
    final result = await _session!.send(
      'Network.getCookies',
      {},
      sessionId: _session!.sessionId,
    );
    
    final cookies = result['result']?['cookies'] as List<dynamic>? ?? [];
    return jsonEncode({
      'cookies': cookies.map((c) => {
        'name': c['name'],
        'value': c['value'],
        'domain': c['domain'],
        'path': c['path'],
        'expires': c['expires'],
        'secure': c['secure'],
        'httpOnly': c['httpOnly'],
      }).toList(),
    });
  }

  Future<String> _setCookie(String name, String value, String? url) async {
    await _session!.send(
      'Network.setCookie',
      {
        'name': name,
        'value': value,
        if (url != null) 'url': url,
      },
      sessionId: _session!.sessionId,
    );
    return 'Cookie set: $name=$value';
  }

  Future<String> _deleteCookie(String name, String? url) async {
    await _session!.send(
      'Network.deleteCookies',
      {
        'name': name,
        if (url != null) 'url': url,
      },
      sessionId: _session!.sessionId,
    );
    return 'Cookie deleted: $name';
  }

  Future<void> _closeSession() async {
    if (_session != null) {
      await _session!.close();
      _session = null;
      _isInitialized = false;
    }
  }

  Future<void> close() async {
    await _closeSession();
  }
}

/// Browser tool factory for creating browser instances with different configurations.
class BrowserToolFactory {
  BrowserToolFactory({
    this.sandbox,
    this.chromePath,
    this.headless = true,
    this.timeout = const Duration(seconds: 30),
    this.maxResultBytes = 64 * 1024,
    this.allowPrivateUrls = false,
  });

  final SandboxRunner? sandbox;
  final String? chromePath;
  final bool headless;
  final Duration timeout;
  final int maxResultBytes;
  final bool allowPrivateUrls;

  /// Creates a new browser tool instance.
  BrowserTool create() {
    return BrowserTool(
      sandbox: sandbox,
      chromePath: chromePath,
      headless: headless,
      timeout: timeout,
      maxResultBytes: maxResultBytes,
      allowPrivateUrls: allowPrivateUrls,
    );
  }
}
