import 'package:agent_flutter/ui/context_ref_suggest.dart';
import 'package:flutter_test/flutter_test.dart';

/// SETTINGS-CONTEXT-REFS (Codex item 2): parsing chip `@file`/`@dir`/`@url`/
/// `@git-diff`, saran autocomplete, dan helper direktori parent. Pure-Dart.
void main() {
  group('parseContextRefs', () {
    test('parse semua kind + posisi token', () {
      final refs =
          parseContextRefs('lihat @file:src/a.dart dan @git:diff lalu @url:https://x.io');
      expect(refs.length, 3);
      expect(refs[0].kind, 'file');
      expect(refs[0].target, 'src/a.dart');
      expect(refs[0].fullLabel, '@file:src/a.dart');
      expect(refs[1].kind, 'git');
      expect(refs[1].target, 'diff');
      expect(refs[2].kind, 'url');
      expect(refs[2].target, 'https://x.io');
      expect(refs[0].start, 'lihat '.length);
    });

    test('token tanpa target (baru ketik @file:) tetap terparse', () {
      final refs = parseContextRefs('cek @file:');
      expect(refs.length, 1);
      expect(refs[0].kind, 'file');
      expect(refs[0].target, isEmpty);
    });

    test('case-insensitive kind', () {
      final refs = parseContextRefs('@FILE:Readme.md');
      expect(refs.single.kind, 'file');
    });
  });

  group('removeRange + activeTokenAt', () {
    test('removeRange menghapus token dan jaga posisi caret', () {
      final text = 'awal @file:x.dart akhir';
      final token = parseContextRefs(text).single;
      final out = removeRange(text, token.start, token.end);
      expect(out, 'awal  akhir');
    });

    test('removeRange aman untuk rentang liar', () {
      expect(removeRange('abc', 3, 1), 'abc');
      expect(removeRange('abc', -1, 2), 'abc');
      expect(removeRange('abc', 0, 9), 'abc');
    });

    test('activeTokenAt: caret di dalam token (caret > start, <= end)', () {
      const text = '@file:src/a.dart';
      expect(activeTokenAt(text, 0), isNull);
      expect(activeTokenAt(text, 6)!.kind, 'file');
      expect(activeTokenAt(text, text.length)!.target, 'src/a.dart');
      expect(activeTokenAt('@file:x selesai', 9), isNull);
    });
  });

  group('builtinPartials + suggestAt', () {
    test('ketik partial @fi menyarankan @file:', () {
      expect(builtinPartials('ketik @fi', 9), ['@file:']);
      expect(builtinPartials('ketik @', 7), kBuiltinSuggestions);
      expect(builtinPartials('ketik @git', 10), ['@git:diff', '@git:log', '@git:status']);
      expect(builtinPartials('teks biasa', 10), isEmpty);
      expect(builtinPartials('@ ', 2), isEmpty);
    });

    test('suggestAt file: filter entri prefix', () {
      final s = suggestAt('lihat @file:src/li', 18,
          entries: ['src/lib/a.dart', 'src/other.txt', 'bin/main.dart']);
      expect(s.activeKind, 'file');
      expect(s.targetPrefix, 'src/li');
      expect(s.entries, ['src/lib/a.dart']);
    });

    test('suggestAt dir: saran kind dir', () {
      final s = suggestAt('@dir:src', 8, entries: ['src/a.dart', 'doc/b.md']);
      expect(s.activeKind, 'dir');
      expect(s.entries, ['src/a.dart']);
    });

    test('suggestAt git: mode saran bertahap', () {
      expect(suggestAt('@git:d', 6).builtins, ['@git:diff']);
      expect(suggestAt('@git:', 5).builtins, ['@git:diff', '@git:log', '@git:status']);
      expect(suggestAt('@git:log', 8).builtins, ['@git:log']);
    });

    test('suggestAt url: hanya kind, tanpa entri/builtin', () {
      final s = suggestAt('@url:https://x', 14);
      expect(s.activeKind, 'url');
      expect(s.builtins, isEmpty);
      expect(s.entries, isEmpty);
    });

    test('suggestAt di luar token: partial builtin saja', () {
      final s = suggestAt('hai @di', 7);
      expect(s.builtins, ['@dir:']);
      expect(s.activeKind, isNull);
    });
  });

  group('parentDirsOf', () {
    test('direktori parent unik + urut', () {
      expect(
        parentDirsOf(['src/lib/a.dart', 'src/b.dart', 'readme.md']),
        ['src', 'src/lib'],
      );
    });

    test('path tanpa slash diabaikan', () {
      expect(parentDirsOf(['main.dart']), isEmpty);
    });
  });
}
