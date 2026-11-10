import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('external content sources taint the session', () {
    for (final name in [
      'web_fetch',
      'web_search',
      'http_request',
      'cdp_browser',
      'mcp_github_create_issue',
      'script_custom',
    ]) {
      expect(ToolTrust.isExternalTaintSource(name), isTrue, reason: name);
    }
  });

  test('workspace output is untrusted but does not create external taint', () {
    for (final name in ['read_file', 'list_dir', 'grep', 'probe', 'shell']) {
      expect(ToolTrust.isUntrustedOutput(name), isTrue, reason: name);
      expect(ToolTrust.isExternalTaintSource(name), isFalse, reason: name);
    }
  });

  test('ordinary trusted outputs remain outside the untrusted envelope', () {
    for (final name in ['datetime', 'calc', 'memory_search']) {
      expect(ToolTrust.isUntrustedOutput(name), isFalse, reason: name);
      expect(ToolTrust.isExternalTaintSource(name), isFalse, reason: name);
    }
  });
}
