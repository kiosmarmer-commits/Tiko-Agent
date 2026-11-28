import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ForgedToolDef _def(String name) => ForgedToolDef(
      name: name,
      description: 'tool uji',
      command: const ['echo', 'hi'],
      tests: const [ForgeTest(input: {'x': 1})],
    );

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-pkg', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

void main() {
  late String workspace;

  setUp(() async {
    workspace = await Directory.systemTemp
        .createTemp('toolpkg_test')
        .then((d) => d.path);
  });

  tearDown(() async {
    await Directory(workspace).delete(recursive: true);
  });

  test('PKG-1: export \u2014 checksum deterministik dan tools terurut nama',
      () async {
    const packager = ToolPackager();
    final m1 = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_b'), _def('made_a')],
    );
    final m2 = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_a'), _def('made_b')],
    );
    expect(m1.checksum, isNotEmpty);
    expect(m1.checksum, m2.checksum);
    expect(m1.tools.first.name, 'made_a');
  });

  test('PKG-2: import valid \u2014 contract tests lulus \u2192 terpasang', () async {
    const packager = ToolPackager();
    final manifest = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_uji')],
    );
    final installed = <String>[];
    final tool = ToolPackageTool(
      installedDefs: () => const [],
      runTests: (def) async => null,
      install: (def) {
        installed.add(def.name);
        return true;
      },
      hasTool: (name) => installed.contains(name),
    );
    final result = await tool.run(
      {'action': 'import', 'package': const JsonEncoder().convert(manifest.toJson())},
      _ctx(workspace),
    );
    expect(result.isError, isFalse);
    expect(result.content, contains('"installed"'));
    expect(result.content, contains('made_uji'));
    expect(installed, ['made_uji']);
  });

  test('PKG-3: checksum dimanipulasi \u2192 paket ditolak', () async {
    const packager = ToolPackager();
    final manifest = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_uji')],
    );
    final json = Map.of(manifest.toJson());
    (json['tools'] as List).first['description'] = 'diubah';
    final tool = ToolPackageTool(
      installedDefs: () => const [],
      runTests: (def) async => null,
      install: (def) => true,
      hasTool: (_) => false,
    );
    final result = await tool.run(
      {'action': 'import', 'package': const JsonEncoder().convert(json)},
      _ctx(workspace),
    );
    expect(result.isError, isTrue);
    expect(result.content, contains('checksum tidak cocok'));
  });

  test('PKG-4: nama bukan namespace made_ \u2192 ditolak (fail-closed)', () async {
    const packager = ToolPackager();
    final manifest = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_uji')],
    );
    final json = Map.of(manifest.toJson());
    (json['tools'] as List).first['name'] = 'system_exec';
    json['checksum'] = ToolPackageManifest.computeChecksum(json);
    final tool = ToolPackageTool(
      installedDefs: () => const [],
      runTests: (def) async => null,
      install: (def) => true,
      hasTool: (_) => false,
    );
    final result = await tool.run(
      {'action': 'import', 'package': const JsonEncoder().convert(json)},
      _ctx(workspace),
    );
    expect(result.isError, isTrue);
    expect(result.content, contains('nama tool tidak valid'));
  });

  test('PKG-5: contract tests gagal \u2192 import error, tidak ada yang terpasang',
      () async {
    const packager = ToolPackager();
    final manifest = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_a'), _def('made_b')],
    );
    final installed = <String>[];
    final tool = ToolPackageTool(
      installedDefs: () => const [],
      runTests: (def) async => 'uji #1: exit 1',
      install: (def) {
        installed.add(def.name);
        return true;
      },
      hasTool: (name) => installed.contains(name),
    );
    final result = await tool.run(
      {'action': 'import', 'package': const JsonEncoder().convert(manifest.toJson())},
      _ctx(workspace),
    );
    expect(result.isError, isTrue);
    expect(result.content, contains('contract tests gagal'));
    expect(installed, isEmpty);
  });

  test('PKG-6: dry_run tidak meng-install; list menampilkan terpasang',
      () async {
    const packager = ToolPackager();
    final manifest = packager.export(
      id: 'uji-paket',
      name: 'Paket Uji',
      version: '1.0.0',
      defs: [_def('made_uji')],
    );
    final installed = <String>[];
    final tool = ToolPackageTool(
      installedDefs: () => [_def('made_uji')],
      runTests: (def) async => null,
      install: (def) {
        installed.add(def.name);
        return true;
      },
      hasTool: (name) => installed.contains(name),
    );
    final dry = await tool.run(
      {
        'action': 'import',
        'dry_run': true,
        'package': const JsonEncoder().convert(manifest.toJson()),
      },
      _ctx(workspace),
    );
    expect(dry.content, contains('(dry-run)'));
    expect(installed, isEmpty);
    final list = await tool.run({'action': 'list'}, _ctx(workspace));
    expect(list.content, contains('made_uji'));
  });

  test('PKG-7: id paket tidak valid \u2192 export ditolak', () async {
    final tool = ToolPackageTool(
      installedDefs: () => [_def('made_uji')],
      runTests: (def) async => null,
      install: (def) => true,
      hasTool: (_) => false,
    );
    final result = await tool.run(
      {'action': 'export', 'id': 'Paket Invalid!'},
      _ctx(workspace),
    );
    expect(result.isError, isTrue);
  });
}
