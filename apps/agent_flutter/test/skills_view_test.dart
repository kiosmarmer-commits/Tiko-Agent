import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/skills_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final skills = [
    const SkillItem(
      slug: 'catatan-keuangan',
      name: 'Catatan Keuangan',
      description: 'Membuat catatan pemasukan/pengeluaran.',
      status: 'approved',
      version: 3,
      uses: 12,
      successes: 11,
      positive: 7,
      negative: 2,
      approvedBy: 'api',
    ),
    const SkillItem(
      slug: 'netral',
      name: 'Netral',
      status: 'draft',
    ),
  ];

  group('GUI-P1-03: SkillsPage', () {
    testWidgets('menampilkan skill, status chip approved, dan feedback aktif',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkillsPage(
            skills: skills,
            online: true,
            loading: false,
            onLoadHistory: (_) async => <SkillHistoryEntry>[],
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('catatan-keuangan'), findsOneWidget);
      expect(find.text('netral'), findsOneWidget);
      expect(find.text('approved'), findsOneWidget);
      expect(find.text('draft'), findsOneWidget);
      expect(
          find.text('v3 \u00b7 uses 12 \u00b7 \ud83d\udc4d 7 \u00b7 \ud83d\udc4e 2 \u00b7 sukses 92%'),
          findsOneWidget);
      expect(find.byTooltip('Feedback \ud83d\udc4d untuk catatan-keuangan'),
          findsOneWidget);
    });

    testWidgets('feedback tepat meneruskan slug dan polaritas', (tester) async {
      final calls = <(String, bool)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkillsPage(
            skills: skills,
            online: true,
            loading: false,
            onLoadHistory: (_) async => <SkillHistoryEntry>[],
            onFeedback: (slug, positive) async {
              calls.add((slug, positive));
              return true;
            },
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(
          find.byTooltip('Feedback \ud83d\udc4d untuk catatan-keuangan'));
      await tester.pump();
      expect(calls.single, ('catatan-keuangan', true));
    });

    testWidgets('feedback pada skill draft dinonaktifkan oleh gate model',
        (tester) async {
      final calls = <(String, bool)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkillsPage(
            skills: <SkillItem>[skills.last],
            online: true,
            loading: false,
            onFeedback: (slug, positive) async {
              calls.add((slug, positive));
              return true;
            },
          ),
        ),
      ));
      await tester.pump();

      expect(
          find.byTooltip('Feedback hanya untuk skill trial/approved'),
          findsNWidgets(2));
      await tester.tap(
          find.byTooltip('Feedback hanya untuk skill trial/approved').first,
          warnIfMissed: false);
      await tester.pump();
      expect(calls, isEmpty);
    });

    testWidgets('filter teks menyaring daftar skill', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkillsPage(
            skills: skills,
            online: true,
            loading: false,
            onLoadHistory: (_) async => <SkillHistoryEntry>[],
          ),
        ),
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'catatan');
      await tester.pump();
      expect(find.text('catatan-keuangan'), findsOneWidget);
      expect(find.text('netral'), findsNothing);
    });

    testWidgets('aksi lifecycle approve memanggil callback dan laporan hasil',
        (tester) async {
      var approved = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkillsPage(
            skills: <SkillItem>[skills.last],
            online: true,
            loading: false,
            onEvaluate: (slug) async => throw StateError('tidak dipakai'),
            onApprove: (slug) async {
              approved = slug;
              return const SkillGateOutcome(
                ok: true,
                slug: 'netral',
                stage: 'approved',
                message: 'lulus',
              );
            },
            onLoadHistory: (_) async => <SkillHistoryEntry>[],
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byTooltip('Aksi lifecycle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve (promosikan)'));
      await tester.pump();

      expect(approved, 'netral');
      expect(find.textContaining('netral: approved OK'),
          findsOneWidget);
    });
  });
}
