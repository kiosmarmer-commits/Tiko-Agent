import 'dart:convert';

import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/artifact_view.dart';
import 'package:agent_flutter/ui/chat_artifact_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _png1x1Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  ArtifactsListing seedListing() => const ArtifactsListing(
        files: [
          ArtifactFileInfo(path: 'notes/', bytes: 0),
          ArtifactFileInfo(path: 'halo.txt', bytes: 32),
        ],
      );

  ArtifactContent seedContent() => const ArtifactContent(
        path: 'halo.txt',
        bytes: 32,
        content: 'isi halo',
        bakExists: true,
      );

  ArtifactDiff seedDiff() => const ArtifactDiff(
        path: 'halo.txt',
        oldExists: true,
        newExists: true,
        lines: [
          DiffLine(type: '=', text: 'satu'),
          DiffLine(type: '+', text: 'dua'),
        ],
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  test('collectFileRefs: unik, maks 6, skip .. dan backslash', () {
    final refs = collectFileRefs(
      'lihat @file:src/a.dart dan @file:src/a.dart lalu '
      '@file:../secret.txt @file:x\\y.txt '
      '@file:b.txt @file:c.txt @file:d.txt @file:e.txt @file:f.txt '
      '@file:g.txt',
    );
    expect(refs, ['src/a.dart', 'b.txt', 'c.txt', 'd.txt', 'e.txt', 'f.txt']);
  });

  test('collectFileRefs: teks tanpa referensi menghasilkan kosong', () {
    expect(collectFileRefs('pesan biasa tanpa file'), isEmpty);
  });

  test('parseMessageFileCards: JSON valid, non-JSON, dan selain list', () {
    final ok = parseMessageFileCards(
      '[{"path":"a.txt","changed":true},{"path":"b.txt"}]',
    );
    expect(ok.length, 2);
    expect(ok[0].path, 'a.txt');
    expect(ok[0].changed, isTrue);
    expect(ok[1].changed, isFalse);

    expect(parseMessageFileCards('bukan json'), isEmpty);
    expect(parseMessageFileCards('{"path":"a.txt"}'), isEmpty);
    expect(parseMessageFileCards(null), isEmpty);
  });

  testWidgets('ChatArtifactPanel merender listing file dan panggil callback',
      (tester) async {
    String? openedFile;
    String? openedDir;
    var refreshed = 0;
    var closed = 0;

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: seedListing(),
        onOpenDir: (d) => openedDir = d,
        onOpenFile: (f) => openedFile = f,
        onClosePreview: () => closed++,
        onRefresh: () => refreshed++,
      ),
    ));

    expect(find.text('halo.txt'), findsOneWidget);
    expect(find.text('notes/'), findsOneWidget);

    await tester.tap(find.text('halo.txt'));
    expect(openedFile, 'halo.txt');

    await tester.tap(find.text('notes/'));
    expect(openedDir, 'notes/');

    await tester.tap(find.byTooltip('Muat ulang daftar file'));
    expect(refreshed, 1);

    await tester.tap(find.byTooltip('Tutup panel file'));
    expect(closed, 1);
  });

  testWidgets('ChatArtifactPanel menampilkan preview file dan diff',
      (tester) async {
    var closed = 0;
    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: seedListing(),
        preview: seedContent(),
        diff: seedDiff(),
        previewShowDiff: true,
        onClosePreview: () => closed++,
      ),
    ));

    expect(find.text('+ dua'), findsOneWidget);

    await tester.tap(find.byTooltip('Tutup panel file'));
    expect(closed, 1);
  });

  testWidgets('ChatArtifactPanel tombol naik menghitung direktori induk',
      (tester) async {
    String? openedDir;
    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: seedListing(),
        dir: 'notes/sub',
      ),
    ));

    await tester.tap(find.text('.. (naik)'));
    expect(openedDir, isNull);

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: seedListing(),
        dir: 'notes/sub',
        onOpenDir: (d) => openedDir = d,
      ),
    ));

    await tester.tap(find.text('.. (naik)'));
    expect(openedDir, 'notes');
  });

  testWidgets('ArtifactPreviewPanel tombol salin menyalin isi file ke clipboard',
      (tester) async {
    await tester.pumpWidget(wrap(
      ArtifactPreviewPanel(content: seedContent(), diff: seedDiff()),
    ));

    await tester.tap(find.byKey(const Key('btn-artifact-copy')));
    await tester.pump();
  });

  testWidgets('ArtifactPreviewPanel reset tampilan diff saat path berubah',
      (tester) async {
    await tester.pumpWidget(wrap(
      ArtifactPreviewPanel(
        content: seedContent(),
        diff: seedDiff(),
        initialShowDiff: true,
      ),
    ));

    expect(find.text('+ dua'), findsOneWidget);

    await tester.pumpWidget(wrap(
      ArtifactPreviewPanel(
        content: seedContent(),
        diff: seedDiff(),
        initialShowDiff: false,
      ),
    ));

    expect(find.text('isi halo'), findsOneWidget);
    expect(find.text('+ dua'), findsNothing);
  });

  testWidgets('ChatArtifactPanel chip Sesi ini memfilter file per sesi (Hermes S7)',
      (tester) async {
    final listing = const ArtifactsListing(
      files: [
        ArtifactFileInfo(path: 'notes/', bytes: 0),
        ArtifactFileInfo(
          path: 'lama.txt',
          bytes: 8,
          modified: '2025-12-31T00:00:00.000Z',
        ),
        ArtifactFileInfo(
          path: 'baru.txt',
          bytes: 8,
          modified: '2026-02-01T00:00:00.000Z',
        ),
      ],
    );

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: listing,
        sessionStartedAt: '2026-01-01T00:00:00.000Z',
        sessionLabel: 'Demo',
      ),
    ));

    expect(find.byKey(const Key('chip-artifact-session-only')), findsOneWidget);
    expect(find.text('Sesi ini \u00b7 Demo'), findsOneWidget);
    expect(find.text('lama.txt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-artifact-session-only')));
    await tester.pump();

    expect(find.text('lama.txt'), findsNothing);
    expect(find.text('baru.txt'), findsOneWidget);
    expect(find.text('notes/'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-artifact-session-only')));
    await tester.pump();
    expect(find.text('lama.txt'), findsOneWidget);
  });

  testWidgets('ChatArtifactPanel file sesuai referensi tetap tampil meski lama (Hermes S7)',
      (tester) async {
    final listing = const ArtifactsListing(
      files: [
        ArtifactFileInfo(
          path: 'src/lama.txt',
          bytes: 8,
          modified: '2025-12-31T00:00:00.000Z',
        ),
        ArtifactFileInfo(
          path: 'lain.txt',
          bytes: 8,
          modified: '2025-12-31T00:00:00.000Z',
        ),
      ],
    );

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: listing,
        sessionStartedAt: '2026-01-01T00:00:00.000Z',
        sessionRefs: const ['lama.txt'],
      ),
    ));

    await tester.tap(find.byKey(const Key('chip-artifact-session-only')));
    await tester.pump();

    expect(find.text('src/lama.txt'), findsOneWidget);
    expect(find.text('lain.txt'), findsNothing);
  });

  testWidgets('ChatArtifactPanel memuat thumbnail gambar via onLoadImage (Hermes S7)',
      (tester) async {
    final listing = const ArtifactsListing(
      files: [
        ArtifactFileInfo(path: 'gambar.png', bytes: 96),
      ],
    );
    final requested = <String>[];
    final png = base64Decode(_png1x1Base64);

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: listing,
        onLoadImage: (path) async {
          requested.add(path);
          return png;
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(requested, ['gambar.png']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('ChatArtifactPanel tombol unduh + publikasikan memanggil callback (Hermes S7)',
      (tester) async {
    final downloaded = <String>[];
    final published = <String>[];

    await tester.pumpWidget(wrap(
      ChatArtifactPanel(
        online: true,
        listing: seedListing(),
        preview: seedContent(),
        onDownload: (path) => downloaded.add(path),
        onPublish: (path) => published.add(path),
      ),
    ));

    await tester.tap(find.byKey(const Key('btn-artifact-download')));
    await tester.tap(find.byKey(const Key('btn-artifact-publish')));

    expect(downloaded, ['halo.txt']);
    expect(published, ['halo.txt']);
  });

  testWidgets('ArtifactPreviewPanel mode Code menampilkan nomor baris (Hermes S7)',
      (tester) async {
    await tester.pumpWidget(wrap(
      ArtifactPreviewPanel(
        content: const ArtifactContent(
          path: 'halo.txt',
          bytes: 32,
          content: 'baris satu\nbaris dua',
          bakExists: true,
        ),
        diff: seedDiff(),
      ),
    ));

    await tester.tap(find.text('Code'));
    await tester.pump();

    expect(find.textContaining('baris satu', findRichText: true), findsOneWidget);
    expect(find.text('+ dua'), findsNothing);
  });

  testWidgets('ArtifactPreviewPanel preview gambar dari base64 inline (Hermes S7)',
      (tester) async {
    await tester.pumpWidget(wrap(
      ArtifactPreviewPanel(
        content: ArtifactContent(
          path: 'gambar.png',
          bytes: 96,
          binary: true,
          isImage: true,
          contentBase64: _png1x1Base64,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('ArtifactPreviewPanel tombol unduh/publikasi hilang bila callback null',
      (tester) async {
    await tester.pumpWidget(wrap(ArtifactPreviewPanel(content: seedContent())));

    expect(find.byKey(const Key('btn-artifact-download')), findsNothing);
    expect(find.byKey(const Key('btn-artifact-publish')), findsNothing);
  });
}
