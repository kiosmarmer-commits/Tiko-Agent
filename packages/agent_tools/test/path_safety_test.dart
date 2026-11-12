import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('safeResolve blocks parent traversal and accepts an in-root file', () {
    final root = Directory.systemTemp.createTempSync('ws_');
    try {
      expect(safeResolve(root.path, '../etc/passwd'), isNull);
      File('${root.path}/a.txt').writeAsStringSync('x');
      expect(safeResolve(root.path, 'a.txt'), isNotNull);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('safeResolve rejects a missing child below an escaping symlink', () async {
    final root = Directory.systemTemp.createTempSync('ws-link-root-');
    final outside = Directory.systemTemp.createTempSync('ws-link-outside-');
    try {
      await Link('${root.path}/escape').create(outside.path);
      expect(safeResolve(root.path, 'escape/new/file.txt'), isNull);
    } finally {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  test('safeResolve rejects broken symlinks instead of treating them as new files', () async {
    final root = Directory.systemTemp.createTempSync('ws-broken-link-');
    try {
      await Link('${root.path}/broken').create('${root.path}/outside-missing');
      expect(safeResolve(root.path, 'broken'), isNull);
      expect(safeResolve(root.path, 'broken/new.txt'), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('safeResolve rejects sibling paths sharing the workspace prefix', () {
    final parent = Directory.systemTemp.createTempSync('ws-prefix-');
    final root = Directory('${parent.path}/workspace')..createSync();
    final sibling = Directory('${parent.path}/workspace-other')..createSync();
    try {
      expect(safeResolve(root.path, sibling.path), isNull);
    } finally {
      parent.deleteSync(recursive: true);
    }
  });
}
