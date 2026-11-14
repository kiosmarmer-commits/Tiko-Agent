import 'dart:io';

import 'package:agent_flutter/ui/graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpul_core/simpul_core.dart';

void main() {
  group('logika murni graph view', () {
    test('lodForScale mengikuti ambang GRA-R03', () {
      expect(lodForScale(0.1), GraphLod.aggregate);
      expect(lodForScale(0.34), GraphLod.aggregate);
      expect(lodForScale(0.35), GraphLod.individual);
      expect(lodForScale(0.8), GraphLod.individual);
      expect(lodForScale(0.9), GraphLod.detailed);
      expect(lodForScale(3.0), GraphLod.detailed);
    });

    test('radiusForDegree tumbuh dengan derajat dan terkunci 4..18', () {
      expect(radiusForDegree(0), 4.0);
      expect(radiusForDegree(9), greaterThan(radiusForDegree(1)));
      expect(radiusForDegree(10000), 18.0);
    });

    test('folderColor deterministik per folder dan berbeda antar folder', () {
      expect(folderColor('a/b/c.md'), folderColor('a/b/d.md'));
      expect(folderColor('a/b/c.md'), isNot(folderColor('x/c.md')));
    });

    test('matchesFilter: substring path/judul, tag:, nested tag', () {
      expect(matchesFilter('ml/saraf.md', 'Saraf', ['ml'], ''), isTrue);
      expect(matchesFilter('ml/saraf.md', 'Saraf', ['ml'], 'saraf'), isTrue);
      expect(matchesFilter('ml/saraf.md', 'Saraf', ['ml'], 'SARAF'), isTrue);
      expect(matchesFilter('ml/saraf.md', 'Saraf', ['ml'], 'ops'), isFalse);
      expect(matchesFilter('ml/saraf.md', 'Saraf', ['ml'], 'tag:ml'), isTrue);
      expect(matchesFilter('x.md', 'X', ['ml/deep'], 'tag:ml'), isTrue);
      expect(matchesFilter('x.md', 'X', ['belajar'], 'tag:ml'), isFalse);
      expect(matchesFilter('x.md', 'X', [], 'tag:'), isTrue);
    });
  });

  group('GraphViewController', () {
    late Directory tmp;
    late String vault;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('agent-flutter-graph');
      vault = '${tmp.path}/vault';
      await Directory('$vault/ml').create(recursive: true);
      await File('$vault/ml/saraf.md').writeAsString(
        '---\ntitle: Saraf\ntags: [ml]\n---\nlihat [[gd]]\n',
      );
      await File('$vault/ml/gd.md').writeAsString(
        '---\ntitle: GD\ntags: [ml]\n---\nteks gradient descent\n',
      );
      await File('$vault/ops/deploy.md').create(recursive: true);
      await File('$vault/ops/deploy.md').writeAsString(
        '---\ntitle: Deploy\n---\ndocker dan CI\n',
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('load membangun graf, kuartet pohon, dan derajat', () async {
      final controller = GraphViewController(iterations: 20);
      await controller.load(vault);
      expect(controller.error, isNull);
      expect(controller.graph, isNotNull);
      expect(controller.graph!.nodeCount, 3);
      expect(controller.titles, containsAll(['Saraf', 'GD', 'Deploy']));
      expect(controller.graph!.targets.length, 1);
      final saraf = controller.graph!.paths.indexOf('ml/saraf.md');
      expect(controller.degrees[saraf], 1);
      expect(controller.tree, isNotNull);
      expect(controller.communityOf.length, 3);
      expect(controller.warmStart, isFalse);
      controller.dispose();
    });

    test('load kedua memakai warm start dari cache bersama CLI', () async {
      final index = JsonVaultIndex('$vault/.simpul/index.json');
      await index.replaceAll(const []);
      await index.close();

      final controller = GraphViewController(iterations: 20);
      await controller.load(vault);
      expect(controller.warmStart, isFalse);
      await controller.load(vault);
      expect(controller.warmStart, isTrue);
      controller.dispose();
    });

    test('visibleIds dan filter tag bekerja', () async {
      final controller = GraphViewController(iterations: 20);
      await controller.load(vault);
      expect(controller.visibleIds.length, 3);
      controller.setFilter('tag:ml');
      expect(controller.visibleIds.length, 2);
      controller.setFilter('deploy');
      expect(controller.visibleIds.single, 2);
      controller.setFilter('');
      expect(controller.visibleIds.length, 3);
      controller.dispose();
    });

    test('neighborsOf mengembalikan tetangga unik', () async {
      final controller = GraphViewController(iterations: 20);
      await controller.load(vault);
      final saraf = controller.graph!.paths.indexOf('ml/saraf.md');
      final gd = controller.graph!.paths.indexOf('ml/gd.md');
      expect(controller.neighborsOf(saraf), contains(gd));
      controller.dispose();
    });

    test('vault tidak ada menghasilkan error, bukan crash', () async {
      final controller = GraphViewController(iterations: 20);
      await controller.load('${tmp.path}/tidak-ada');
      expect(controller.error, isNotNull);
      expect(controller.graph, isNull);
      controller.dispose();
    });
  });

  group('widget GraphView', () {
    late Directory uiTmp;
    late GraphViewController uiController;

    setUpAll(() async {
      uiTmp = await Directory.systemTemp.createTemp('agent-flutter-graph-ui');
      final vault = '${uiTmp.path}/vault';
      await Directory(vault).create(recursive: true);
      await File('$vault/a.md').writeAsString('---\ntitle: A\n---\nlihat [[b]]\n');
      await File('$vault/b.md').writeAsString('---\ntitle: B\n---\nteks\n');
      uiController = GraphViewController(iterations: 10);
      await uiController.load(vault);
    });

    tearDownAll(() async {
      uiController.dispose();
      await uiTmp.delete(recursive: true);
    });

    testWidgets('menampilkan graf yang sudah dimuat', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: GraphView(controller: uiController),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(uiController.graph, isNotNull);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SimpulGraphPage menampilkan halaman dan status kosong',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SimpulGraphPage()));
      expect(find.text('Graf Vault (Simpul)'), findsOneWidget);
      expect(find.text('Belum ada graf — isi path vault lalu Muat.'), findsOneWidget);
      expect(find.text('Muat'), findsOneWidget);
    });
  });
}
