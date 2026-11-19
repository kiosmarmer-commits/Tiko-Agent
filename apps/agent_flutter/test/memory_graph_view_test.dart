import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/memory_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const entries = [
    LayerEntry(
      id: 'lay-2',
      layer: 'semantic',
      text: 'Tiko adalah agent personal',
      importance: 0.9,
      tags: ['tiko', 'identitas'],
      accessCount: 4,
      createdAt: '2026-11-18T13:00:00.000Z',
      lastAccessedAt: '2026-11-18T14:00:00.000Z',
      sourceSession: 'web:default',
    ),
    LayerEntry(
      id: 'lay-1',
      layer: 'episodic',
      text: 'Percakapan build pertama',
      importance: 0.4,
      accessCount: 0,
      createdAt: '2026-11-17T09:00:00.000Z',
    ),
  ];

  testWidgets('Timeline mengelompokkan per tanggal dan menampilkan provenance',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MemoryGraphTimeline(
          entries: entries,
          online: true,
          loading: false,
          truncated: true,
          total: 9,
        ),
      ),
    ));

    expect(find.text('2026-11-18 · 1 entri'), findsOneWidget);
    expect(find.text('2026-11-17 · 1 entri'), findsOneWidget);
    expect(find.text('SEMANTIC'), findsOneWidget);
    expect(find.text('EPISODIC'), findsOneWidget);
    expect(find.textContaining('akses 4'), findsOneWidget);
    expect(find.textContaining('sesi web:default'), findsOneWidget);
    expect(find.text('#tiko'), findsOneWidget);
    expect(find.textContaining('terpotong dari 9'), findsOneWidget);
  });

  testWidgets('Timeline kosong menampilkan placeholder', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MemoryGraphTimeline(
          entries: [],
          online: true,
          loading: false,
        ),
      ),
    ));

    expect(find.textContaining('Belum ada memori berlapis'), findsOneWidget);
  });

  testWidgets('Tombol hapus di timeline memanggil onDelete', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MemoryGraphTimeline(
          entries: entries,
          online: false,
          loading: false,
          onDelete: (id) async {
            deleted.add(id);
          },
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('btn-delete-graph-lay-1')));
    expect(deleted, ['lay-1']);
  });
}
