import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/memory_explorer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Memory Explorer (GUI-P1-12) view: 4 tab — Fakta, Kurasi, Lapisan, RAG.
void main() {
  CuratedMemoryInfo curated() => CuratedMemoryInfo(
        memory: const CuratedFileInfo(text: '# Fakta Tiko', chars: 12),
        user: const CuratedFileInfo(text: 'Suka teh', chars: 8),
        budget: 100,
        used: 20,
      );

  LayersSnapshot layers() => const LayersSnapshot(
        stats: {
          'episodic': LayerStats(count: 1, avgScore: 0.4),
          'semantic': LayerStats(count: 1, avgScore: 0.8),
        },
        entries: [
          LayerEntry(
            id: 'lay-1',
            layer: 'semantic',
            text: 'Tiko agent ditulis Dart',
            importance: 0.8,
            tags: ['tiko'],
            accessCount: 2,
            createdAt: '2026-11-18T13:00:00.000Z',
          ),
          LayerEntry(
            id: 'lay-2',
            layer: 'episodic',
            text: 'Pengguna tanya build',
            importance: 0.4,
          ),
        ],
        total: 2,
        truncated: false,
      );

  RagSourcesInfo rag() => const RagSourcesInfo(
        chunkCount: 3,
        docs: [
          RagDocInfo(
              docId: 'handbook.md',
              chunks: 2,
              chars: 900,
              preview: 'Panduan build'),
          RagDocInfo(docId: 'faq.md', chunks: 1, chars: 240, preview: 'FAQ'),
        ],
        truncated: false,
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('tab Fakta menampilkan daftar memori', (tester) async {
    await tester.pumpWidget(wrap(MemoryExplorerPage(
      memories: const [
        MemoryFact(id: 'm-1', text: 'Suka teh', kind: 'preference'),
      ],
      curated: curated(),
      layers: layers(),
      rag: rag(),
      online: true,
      loading: false,
    )));
    expect(find.text('Suka teh'), findsOneWidget);
    expect(find.text('m-1 \u00b7 preference'), findsOneWidget);
  });

  testWidgets('tab Kurasi menampilkan budget + isi file', (tester) async {
    await tester.pumpWidget(wrap(MemoryExplorerPage(
      memories: const [],
      curated: curated(),
      layers: layers(),
      rag: rag(),
      online: true,
      loading: false,
    )));
    await tester.tap(find.text('Kurasi'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('curated-budget')), findsOneWidget);
    expect(find.text('20/100 karakter'), findsOneWidget);
    expect(find.byKey(const Key('memory-curated-mem')), findsOneWidget);
    expect(find.byKey(const Key('memory-curated-user')), findsOneWidget);
  });

  testWidgets('tab Lapisan: stats + expansion detail + add sheet',
      (tester) async {
    var added = false;
    await tester.pumpWidget(wrap(MemoryExplorerPage(
      memories: const [],
      curated: curated(),
      layers: layers(),
      rag: rag(),
      online: true,
      loading: false,
      onAddLayer: (body) async {
        added = body['layer'] == 'semantic' && body['text'] == 'uji';
        return null;
      },
    )));
    await tester.tap(find.text('Lapisan'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('layers-stats')), findsOneWidget);
    expect(find.text('Tiko agent ditulis Dart'), findsOneWidget);

    await tester.tap(find.text('Tiko agent ditulis Dart'));
    await tester.pumpAndSettle();
    expect(find.textContaining('dibuat 2026-11-18'), findsOneWidget);
    expect(find.byKey(const Key('btn-delete-layer-lay-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-add-layer')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('layer-text')), 'uji');
    await tester.tap(find.byKey(const Key('btn-submit-layer')));
    await tester.pumpAndSettle();
    expect(added, isTrue);
    expect(find.byKey(const Key('btn-add-layer')), findsOneWidget);
  });

  testWidgets('tab RAG menampilkan dokumen sumber', (tester) async {
    await tester.pumpWidget(wrap(MemoryExplorerPage(
      memories: const [],
      curated: curated(),
      layers: layers(),
      rag: rag(),
      online: true,
      loading: false,
    )));
    await tester.tap(find.text('RAG'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rag-list')), findsOneWidget);
    expect(find.text('3 chunk dalam 2 dokumen'), findsOneWidget);
    expect(find.text('handbook.md'), findsOneWidget);
    expect(find.textContaining('2 chunk \u00b7 900 karakter'), findsOneWidget);
  });

  testWidgets('kurasi: simpan memanggil callback + error tampil',
      (tester) async {
    var savedFile = '';
    await tester.pumpWidget(wrap(MemoryExplorerPage(
      memories: const [],
      curated: curated(),
      layers: layers(),
      rag: rag(),
      online: true,
      loading: false,
      onSaveCurated: (file, text) async {
        savedFile = file;
        return text.isEmpty ? 'teks wajib' : null;
      },
    )));
    await tester.tap(find.text('Kurasi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-save-curated-memory')));
    await tester.pumpAndSettle();
    expect(savedFile, 'memory');
    expect(find.text('Kurasi memory tersimpan'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    await tester.enterText(
        find.byKey(const Key('memory-curated-mem')), '');
    await tester.tap(find.byKey(const Key('btn-save-curated-memory')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
