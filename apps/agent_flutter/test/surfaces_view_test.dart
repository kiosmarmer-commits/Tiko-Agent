import 'package:agent_flutter/ui/surfaces_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Surface page (Fase E4): daftar snapshot, detail dirender dari record
/// A2UI (fail-closed), dan konfirmasi penghapusan.
void main() {
  Map<String, dynamic> record() => {
        'surfaceId': 's-ui-1',
        'sessionKey': 'web:abc',
        'updatedAt': '2026-11-22T10:00:00.000Z',
        'catalogId': 'tiko.basic.v1',
        'components': [
          {'id': 'root', 'component': 'Metric', 'label': 'CPU', 'value': '87%'},
        ],
        'dataModel': <String, dynamic>{},
      };

  Future<void> pumpPage(
    WidgetTester tester, {
    List<Map<String, dynamic>>? surfaces,
    Future<Map<String, dynamic>?> Function(String)? onShowDetail,
    Future<bool> Function(String)? onDelete,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SurfacesPage(
          surfaces: surfaces,
          online: true,
          loading: false,
          onShowDetail: onShowDetail,
          onDelete: onDelete,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('halaman kosong: pesan instruksi render_a2ui', (tester) async {
    await pumpPage(tester, surfaces: []);
    expect(find.byType(SurfacesPage), findsOneWidget);
    expect(find.textContaining('render_a2ui'), findsOneWidget);
  });

  testWidgets('daftar + detail sheet me-render record lewat A2uiSurfaceRecordView',
      (tester) async {
    await pumpPage(tester, surfaces: [record()],
        onShowDetail: (id) async {
      expect(id, 's-ui-1');
      return record();
    });
    expect(find.byType(ListTile), findsOneWidget);

    await tester.tap(find.text('s-ui-1'));
    await tester.pumpAndSettle();
    expect(find.byType(A2uiSurfaceRecordView), findsOneWidget);
    expect(find.textContaining('CPU'), findsOneWidget);
  });

  testWidgets('hapus memunculkan dialog konfirmasi lalu memanggil onDelete',
      (tester) async {
    var deletedId = '';
    await pumpPage(tester, surfaces: [record()],
        onDelete: (id) async {
      deletedId = id;
      return true;
    });
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Hapus surface?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Hapus'));
    await tester.pumpAndSettle();
    expect(deletedId, 's-ui-1');
  });

  testWidgets('detail sheet 404 menampilkan pesan tidak ditemukan, bukan crash',
      (tester) async {
    await pumpPage(tester, surfaces: [record()],
        onShowDetail: (id) async => null);
    await tester.tap(find.text('s-ui-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tidak ditemukan'), findsOneWidget);
  });
}
