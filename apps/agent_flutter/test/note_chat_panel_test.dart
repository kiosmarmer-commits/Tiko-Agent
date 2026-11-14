import 'package:agent_flutter/ui/index_dashboard.dart';
import 'package:agent_flutter/ui/jank_monitor.dart';
import 'package:agent_flutter/ui/note_chat_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpul_core/simpul_core.dart';

void main() {
  group('JankMonitor', () {
    test('records frames, counts jank, computes p95', () {
      final monitor = JankMonitor.instance..reset();
      for (final ms in [10.0, 12.0, 11.0, 40.0, 13.0, 12.0, 10.0]) {
        monitor.recordFrameMs(ms);
      }
      expect(monitor.jankCount, 1);
      expect(monitor.p95Ms, 40.0);
      expect(monitor.frameMs, hasLength(7));
    });

    test('window caps at windowSize samples', () {
      final monitor = JankMonitor.instance..reset();
      for (var i = 0; i < 200; i++) {
        monitor.recordFrameMs(8);
      }
      expect(monitor.frameMs, hasLength(JankMonitor.windowSize));
      expect(monitor.jankCount, 0);
    });
  });

  group('IndexStatusSummary.fromNotes', () {
    test('counts notes, links, broken links, tags, words', () {
      final parsed = ParsedNote(
        path: 'a.md',
        title: 'A',
        props: {},
        tags: ['x', 'y'],
        aliases: [],
        links: [
          ParsedLink(
            target: 'a',
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: false,
            offset: 0,
          ),
        ],
        blockIds: [],
        chunks: [],
        wordCount: 42,
        body: '',
      );
      final missing = ParsedNote(
        path: 'b.md',
        title: 'B',
        props: {},
        tags: ['x'],
        aliases: [],
        links: [
          ParsedLink(
            target: 'hilang',
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: false,
            offset: 0,
          ),
        ],
        blockIds: [],
        chunks: [],
        wordCount: 8,
        body: '',
      );
      final summary = IndexStatusSummary.fromNotes(
        [
          ScannedNote(
            path: 'a.md',
            mtimeNs: 0,
            sizeBytes: 0,
            contentHash: '',
            parsed: parsed,
          ),
          ScannedNote(
            path: 'b.md',
            mtimeNs: 0,
            sizeBytes: 0,
            contentHash: '',
            parsed: missing,
          ),
        ],
        scanMs: 12,
      );
      expect(summary.noteCount, 2);
      expect(summary.linkCount, 2);
      expect(summary.brokenLinkCount, 1);
      expect(summary.tagCount, 2);
      expect(summary.totalWords, 50);
      expect(summary.scanMs, 12);
    });
  });

  group('SimpulNoteChatPanel', () {
    NoteChatAnswer fakeAnswer(String answerText) => NoteChatAnswer(
          answer: answerText,
          sources: const [
            ChatSource(path: 'ai.md', headingPath: 'AI', score: 2),
          ],
          contextTokens: 128,
          scope: NoteChatScope.note,
        );

    testWidgets('sends question, shows answer, sources, tokens, insert',
        (tester) async {
      String? inserted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteChatPanel(
            vault: '/nonexistent-vault',
            notePath: 'ai.md',
            askOverride: (
              question, {
              required scope,
              notePath,
              confirmAsk = false,
            }) async =>
                fakeAnswer('Jawaban AI lokal.'),
            onInsert: (block) => inserted = block,
          ),
        ),
      ));

      await tester.enterText(find.byType(TextField), 'apa itu embedding?');
      await tester.tap(find.text('Tanya AI lokal'));
      await tester.pumpAndSettle();

      expect(find.text('Jawaban AI lokal.'), findsOneWidget);
      expect(find.textContaining('~'), findsOneWidget);
      expect(find.text('ai.md'), findsOneWidget);

      await tester.tap(find.text('Sisipkan ke catatan (AI-U05)'));
      await tester.pumpAndSettle();
      expect(inserted, isNotNull);
      expect(inserted!, contains('> [!ai] Ditulis AI'));
      expect(inserted!, contains('Jawaban AI lokal.'));
    });

    testWidgets('deny policy shows error instead of answer', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteChatPanel(
            vault: '/nonexistent-vault',
            notePath: 'ai.md',
            askOverride: (
              question, {
              required scope,
              notePath,
              confirmAsk = false,
            }) async =>
                throw AiAccessDenied(AiAccessDecision.deny, 'ai.md'),
            onInsert: (_) {},
          ),
        ),
      ));
      await tester.enterText(find.byType(TextField), 'q');
      await tester.tap(find.text('Tanya AI lokal'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ditolak'), findsOneWidget);
    });
  });
}
