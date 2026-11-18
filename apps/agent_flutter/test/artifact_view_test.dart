import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/artifact_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Scaffold body) => MaterialApp(home: body);

const _listing = ArtifactsListing(
  truncated: false,
  files: [
    ArtifactFileInfo(path: 'README.md', bytes: 2048),
    ArtifactFileInfo(path: 'src/main.dart', bytes: 30),
  ],
);

void main() {
  testWidgets('menampilkan daftar file dengan ukuran + tap membuka file',
      (tester) async {
    String? opened;
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: _listing,
        online: true,
        loading: false,
        onOpenFile: (p) => opened = p,
      ),
    )));
    await tester.pump();

    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('src/main.dart'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);

    await tester.tap(find.text('src/main.dart'));
    expect(opened, 'src/main.dart');
  });

  testWidgets('dir tidak kosong: header menampilkan subdan tombol naik',
      (tester) async {
    String? dirOpened;
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: _listing,
        online: true,
        loading: false,
        dir: 'src',
        onOpenDir: (d) => dirOpened = d,
      ),
    )));
    await tester.pump();

    expect(find.textContaining('2 file'), findsOneWidget);
    await tester.tap(find.text('.. (naik)'));
    expect(dirOpened, '');
  });

  testWidgets('preview teks tampil; toggle diff menukar preview/diff',
      (tester) async {
    const content = ArtifactContent(
      path: 'src/main.dart',
      bytes: 30,
      content: 'void main(){}',
      bakExists: true,
    );
    const diff = ArtifactDiff(
      path: 'src/main.dart',
      oldExists: true,
      newExists: true,
      lines: [
        DiffLine(type: '=', text: 'sama'),
        DiffLine(type: '-', text: 'lama'),
        DiffLine(type: '+', text: 'baru'),
      ],
    );
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: _listing,
        online: true,
        loading: false,
        content: content,
        diff: diff,
      ),
    )));
    await tester.pump();

    expect(find.textContaining('void main(){}'), findsOneWidget);

    await tester.tap(find.text('Diff'));
    await tester.pump();

    expect(find.textContaining('+ baru'), findsOneWidget);
    expect(find.textContaining('- lama'), findsOneWidget);
    expect(find.textContaining('= sama'), findsOneWidget);
  });

  testWidgets('file biner: placeholder tanpa konten diff/preview',
      (tester) async {
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: _listing,
        online: true,
        loading: false,
        content: const ArtifactContent(
          path: 'img.bin',
          binary: true,
          bakExists: false,
        ),
      ),
    )));
    await tester.pump();

    expect(find.textContaining('File biner'), findsOneWidget);
    expect(find.text('Diff'), findsNothing);
  });

  testWidgets('listing null menampilkan pesan; error tampil', (tester) async {
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: null,
        online: true,
        loading: false,
        error: '400 invalid_request',
      ),
    )));
    await tester.pump();

    expect(find.text('Belum ada data artifacts.'), findsOneWidget);
    expect(find.text('400 invalid_request'), findsOneWidget);
  });

  testWidgets('tombol refresh memanggil onRefresh', (tester) async {
    var refresh = 0;
    await tester.pumpWidget(_wrap(Scaffold(
      body: ArtifactsPage(
        listing: _listing,
        online: true,
        loading: false,
        onRefresh: () async {
          refresh += 1;
        },
      ),
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    expect(refresh, 1);
  });
}
