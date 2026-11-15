// Regression guards for findings that are already closed on `main`.
//
// Source of findings: docs/REPOSITORY-AUDIT-2026-11-09.md (archived).
// Scans production source only (`lib/` and `bin/`) so that a future refactor
// cannot silently reintroduce a closed finding.
//
// Coverage boundaries: docs/VERIFICATION-STATUS-2026-11-16.md.

import 'dart:io';

import 'package:test/test.dart';

/// Walks up from the current directory until the workspace root is found.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    final hasPackages = Directory('${dir.path}/packages').existsSync();
    final hasApps = Directory('${dir.path}/apps').existsSync();
    final hasPubspec = File('${dir.path}/pubspec.yaml').existsSync();
    if (hasPackages && hasApps && hasPubspec) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  throw StateError(
    'workspace root not found from ${Directory.current.path}; '
    'run this test from a workspace member',
  );
}

/// Production Dart sources under `packages/` and `apps/`.
List<File> _productionSources(Directory root) {
  final files = <File>[];
  for (final base in const <String>['packages', 'apps']) {
    final dir = Directory('${root.path}/$base');
    if (!dir.existsSync()) {
      continue;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final path = entity.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) {
        continue;
      }
      if (path.endsWith('.g.dart')) {
        continue;
      }
      if (path.contains('/build/') || path.contains('/.dart_tool/')) {
        continue;
      }
      if (!path.contains('/lib/') && !path.contains('/bin/')) {
        continue;
      }
      files.add(entity);
    }
  }
  return files;
}

/// Body of a method, up to its closing brace at class-member indent.
///
/// Delimits on a line that is exactly `  }`. Matching the first `\n  }`
/// substring instead stops at a multi-line parameter list (`  }) async* {`),
/// which truncates the body and makes later assertions pass vacuously.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) {
    throw StateError('signature not found: $signature');
  }
  final lines = source.substring(start).split('\n');
  for (var i = 1; i < lines.length; i++) {
    if (lines[i] == '  }') {
      return lines.sublist(0, i).join('\n');
    }
  }
  throw StateError('closing brace not found for: $signature');
}

String _flutterClient() {
  final file = File(
    '${_repoRoot().path}/apps/agent_flutter/lib/agent_api_client.dart',
  );
  if (!file.existsSync()) {
    throw StateError('missing Flutter API client: ${file.path}');
  }
  return file.readAsStringSync();
}

void main() {
  test('TLS clients never accept invalid certificates', () {
    final insecure = RegExp(
      r'onBadCertificate\s*:\s*\([^)]*\)\s*(=>\s*true|\{\s*return\s+true)',
    );
    final offenders = <String>[];
    for (final file in _productionSources(_repoRoot())) {
      if (insecure.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'onBadCertificate must reject bad certificates; '
          'use (_) => false or omit the callback',
    );
  });

  test('Flutter path identifiers are percent-encoded', () {
    final source = _flutterClient();
    for (final signature in const <String>[
      'Future<bool> deleteMemory(',
      'Future<bool> decideApproval(',
    ]) {
      expect(
        _methodBody(source, signature),
        contains('Uri.encodeComponent'),
        reason: '$signature must percent-encode its path identifier',
      );
    }
  });

  test('Flutter stream authenticates with a ticket, not a raw token', () {
    final source = _flutterClient();
    final body = _methodBody(
      source,
      'Stream<Map<String, dynamic>> streamChat(',
    );
    expect(body, isNot(contains('?token=')));
    expect(body, isNot(contains("'token':")));
    expect(body, contains('queryParameters'));
    expect(body, contains('ticket'));
    expect(source, contains('_requestStreamTicket'));
  });

  test('method extraction spans multi-line parameter lists', () {
    const sample = 'class C {\n'
        '  Stream<int> f(\n'
        '    int a, {\n'
        '    int b = 1,\n'
        '  }) async* {\n'
        '    yield a + b;\n'
        '  }\n'
        '}\n';
    expect(_methodBody(sample, 'Stream<int> f('), contains('yield a + b;'));
  });

  test('Flutter read endpoints surface HTTP errors', () {
    final source = _flutterClient();
    for (final signature in const <String>[
      'Future<Map<String, dynamic>> capabilities()',
      'Future<List<Map<String, dynamic>>> doctor()',
      'Future<List<Map<String, dynamic>>> listSessions()',
      'Future<List<Map<String, dynamic>>> listApprovals()',
      'Future<List<Map<String, dynamic>>> listEvents()',
    ]) {
      expect(
        _methodBody(source, signature),
        contains('_throwIf'),
        reason: '$signature must not convert HTTP errors into empty payloads',
      );
    }
  });
}
