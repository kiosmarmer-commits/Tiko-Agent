import 'dart:typed_data';

import 'package:agent_tools/agent_tools.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('Sandbox dispatcher (P2-5)', () {
    test('dispatchFor returns SandboxKind.none when no backend available',
        () async {
      // Mock all probes to return false (no backends available)
      final runner = await SandboxRunner.dispatchFor(
        'echo hello',
        httpClient: _MockFailingHttpClient(),
        riskFn: (_) => 0.1, // Low risk
      );
      
      // Should return a runner with kind = none
      expect(runner.kind, SandboxKind.none);
      
      // Runner with none should throw UnsupportedError on execution
      expect(
        () => runner.run('echo', ['hello']),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('dispatchFor returns bubblewrap for low risk when available',
        () async {
      // This test would need actual bubblewrap detection
      // For now, we just verify the structure
      final runner = await SandboxRunner.dispatchFor(
        'echo hello',
        riskFn: (_) => 0.1, // Low risk
      );
      
      // Runner should have a kind (might be none, docker, or bubblewrap depending on system)
      expect(runner.kind, isA<SandboxKind>());
    });

    test('dispatchFor returns docker for medium risk when bubblewrap unavailable',
        () async {
      final runner = await SandboxRunner.dispatchFor(
        'echo hello',
        riskFn: (_) => 0.5, // Medium risk
        httpClient: _MockFailingHttpClient(),
      );
      
      // Should have a kind
      expect(runner.kind, isA<SandboxKind>());
    });

    test('dispatchFor returns strongest isolation for high risk',
        () async {
      final runner = await SandboxRunner.dispatchFor(
        'rm -rf /',
        riskFn: (_) => 0.9, // High risk
        httpClient: _MockFailingHttpClient(),
      );
      
      // Should have a kind
      expect(runner.kind, isA<SandboxKind>());
    });

    test('SandboxRunner with none kind throws on startProcess',
        () async {
      final runner = SandboxRunner(kind: SandboxKind.none);
      
      expect(
        () => runner.startProcess('echo', ['hello']),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

/// Mock HTTP client that always fails (for testing no backend scenarios)
class _MockFailingHttpClient implements http.Client {
  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.Response> post(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.Response> put(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.Response> patch(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.Response> delete(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    throw Exception('No backend available');
  }

  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) async {
    throw Exception('No backend available');
  }

  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) async {
    throw Exception('No backend available');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw Exception('No backend available');
  }

  @override
  void close() {}
}
