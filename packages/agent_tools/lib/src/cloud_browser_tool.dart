import 'package:agent_core/agent_core.dart';

import 'browser_backends.dart';

/// Browser tool backed by cloud providers (Browserbase/Browser Use) with a
/// local Chromium fallback, via [CloudBrowserRouter]. Complements the
/// local-only [BrowserTool] the same way Hermes Agent pairs cloud and
/// local browser backends.
class CloudBrowserTool implements Tool {
  CloudBrowserTool(this._router);

  final CloudBrowserRouter _router;
  CloudBrowserHandle? _handle;

  @override
  ToolSpec get spec => ToolSpec(
        name: 'cloud_browser',
        description:
            'Browse via cloud browser backend (Browserbase/Browser Use) '
            'dengan fallback Chromium lokal. Aksi: navigate|read_text|evaluate|close.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['navigate', 'read_text', 'evaluate', 'close'],
            },
            'url': {'type': 'string', 'description': 'Untuk aksi navigate'},
            'expression': {
              'type': 'string',
              'description': 'Ekspresi JS untuk aksi evaluate',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 120,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      switch (args['action']?.toString()) {
        case 'navigate':
          final url = (args['url'] as String?)?.trim() ?? '';
          if (url.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'url wajib untuk aksi navigate',
              isError: true,
            );
          }
          final handle = await _ensureSession();
          return ToolResult(
            callId: '',
            content: await handle.session.navigate(url),
          );
        case 'read_text':
          final handle = await _ensureSession();
          return ToolResult(
            callId: '',
            content: await handle.session.readText(),
          );
        case 'evaluate':
          final expression = (args['expression'] as String?)?.trim() ?? '';
          if (expression.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'expression wajib untuk aksi evaluate',
              isError: true,
            );
          }
          final handle = await _ensureSession();
          return ToolResult(
            callId: '',
            content: await handle.session.evaluate(expression),
          );
        case 'close':
          final handle = _handle;
          _handle = null;
          await handle?.release();
          return const ToolResult(callId: '', content: 'sesi browser ditutup');
        default:
          return const ToolResult(
            callId: '',
            content:
                'aksi tidak dikenal; gunakan navigate|read_text|evaluate|close',
            isError: true,
          );
      }
    } on BrowserBackendException catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    }
  }

  Future<CloudBrowserHandle> _ensureSession() async {
    final existing = _handle;
    if (existing != null) return existing;
    final handle = await _router.acquire();
    _handle = handle;
    return handle;
  }
}
