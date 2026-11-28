import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Fase 45 — Marketplace skill packages: paket portabel berisi tool buatan
/// (`made_*`, hasil ToolMakerPipeline Fase 37) yang bisa di-export menjadi
/// manifest ber-checksum dan di-import kembali fail-closed (checksum wajib,
/// contract tests wajib lulus sebelum install).
///
/// Konvensi repo:
/// - Checksum sha256 atas payload kanonik tools (urut nama) — integritas
///   ditentukan konten, bukan timestamp.
/// - Import fail-closed: nama wajib namespace `made_`, checksum wajib cocok,
///   contract tests wajib lulus bila sandbox tersedia; sandbox tidak ada
///   berarti import gagal (bukan di-skip).
/// - Never-raises: semua operasi mengembalikan laporan jujur.
class ToolPackageManifest {
  const ToolPackageManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.createdAt,
    required this.tools,
    required this.checksum,
  });

  final String id;
  final String name;
  final String version;
  final DateTime createdAt;
  final List<ForgedToolDef> tools;
  final String checksum;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'checksum': checksum,
        'tools': [
          for (final t in tools)
            {
              'name': t.name,
              'description': t.description,
              'command': t.command,
              'tests': [
                for (final test in t.tests)
                  {
                    'input': test.input,
                    if (test.expectContains != null)
                      'expect_contains': test.expectContains,
                  },
              ],
            },
        ],
      };

  static String canonicalToolsJson(Map<String, dynamic> manifest) {
    final tools = manifest['tools'];
    final normalized = (tools is List ? tools : const <dynamic>[])
        .whereType<Map>()
        .map((t) => Map<String, dynamic>.from(t))
        .map((t) {
      final tests = t['tests'];
      return <String, dynamic>{
        'name': '${t['name'] ?? ''}',
        'description': '${t['description'] ?? ''}',
        'command': [
          for (final c in (t['command'] as List? ?? const <dynamic>[])) '$c',
        ],
        'tests': [
          for (final test in (tests as List? ?? const <dynamic>[]))
            test is Map
                ? <String, dynamic>{
                    'input': Map<String, dynamic>.from(test['input'] as Map? ??
                        const {}),
                    if (test['expect_contains'] is String &&
                        (test['expect_contains'] as String).isNotEmpty)
                      'expect_contains': test['expect_contains'],
                  }
                : <String, dynamic>{},
        ],
      };
    }).toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return jsonEncode(normalized);
  }

  static String computeChecksum(Map<String, dynamic> manifest) =>
      crypto.sha256.convert(canonicalToolsJson(manifest).codeUnits).toString();
}

class ToolPackageVerifyReport {
  const ToolPackageVerifyReport({
    required this.ok,
    required this.installed,
    required this.skippedExisting,
    this.checksumError,
    this.testFailure,
  });

  final bool ok;
  final List<String> installed;
  final List<String> skippedExisting;
  final String? checksumError;
  final String? testFailure;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'installed': installed,
        'skipped_existing': skippedExisting,
        if (checksumError != null) 'checksum_error': checksumError,
        if (testFailure != null) 'test_failure': testFailure,
      };
}

class ToolPackager {
  const ToolPackager({this.maxTools = 32});

  final int maxTools;

  static final RegExp _namePattern = RegExp(r'^made_[a-z0-9_]{1,40}$');

  ToolPackageManifest export({
    required String id,
    required String name,
    required String version,
    required List<ForgedToolDef> defs,
    DateTime? createdAt,
  }) {
    final manifest = ToolPackageManifest(
      id: id.trim(),
      name: name.trim(),
      version: version.trim(),
      createdAt: createdAt ?? DateTime.now().toUtc(),
      tools: [...defs]..sort((a, b) => a.name.compareTo(b.name)),
      checksum: '',
    );
    final withChecksum = ToolPackageManifest(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      createdAt: manifest.createdAt,
      tools: manifest.tools,
      checksum: ToolPackageManifest.computeChecksum(manifest.toJson()),
    );
    return withChecksum;
  }

  /// Verifikasi manifest: checksum + validasi tiap def. Mengembalikan null
  /// bila valid, selain itu alasan kegagalan (fail-closed).
  String? verifyManifest(Map<String, dynamic> manifest) {
    final toolsRaw = manifest['tools'];
    if (toolsRaw is! List || toolsRaw.isEmpty) {
      return 'manifest tidak memuat tools.';
    }
    if (toolsRaw.length > maxTools) {
      return 'terlalu banyak tools (${toolsRaw.length} > $maxTools).';
    }
    final expected = '${manifest['checksum'] ?? ''}'.trim();
    if (expected.isEmpty) return 'checksum wajib ada (fail-closed).';
    if (ToolPackageManifest.computeChecksum(manifest) != expected) {
      return 'checksum tidak cocok — paket ditolak.';
    }
    for (final raw in toolsRaw) {
      if (raw is! Map) return 'tool entry bukan object.';
      final name = '${raw['name'] ?? ''}'.trim();
      if (!_namePattern.hasMatch(name)) {
        return 'nama tool tidak valid (wajib made_ + [a-z0-9_]): $name';
      }
      final command = raw['command'];
      if (command is! List || command.isEmpty) return 'command kosong: $name';
      final tests = raw['tests'];
      if (tests is! List || tests.isEmpty) {
        return 'tests wajib ada untuk $name (fail-closed).';
      }
      for (final t in tests) {
        if (t is! Map || t['input'] is! Map) {
          return 'test entry tidak valid pada $name.';
        }
      }
    }
    return null;
  }

  List<ForgedToolDef> defsFromManifest(Map<String, dynamic> manifest) {
    final out = <ForgedToolDef>[];
    final toolsRaw = manifest['tools'];
    if (toolsRaw is! List) return out;
    for (final raw in toolsRaw) {
      if (raw is! Map) continue;
      final tests = <ForgeTest>[];
      for (final t in (raw['tests'] as List? ?? const <dynamic>[])) {
        if (t is! Map) continue;
        tests.add(ForgeTest(
          input: Map<String, dynamic>.from(t['input'] as Map),
          expectContains: t['expect_contains'] is String &&
                  (t['expect_contains'] as String).isNotEmpty
              ? t['expect_contains'] as String
              : null,
        ));
      }
      out.add(ForgedToolDef(
        name: '${raw['name']}'.trim(),
        description: '${raw['description'] ?? ''}'.trim(),
        command: [for (final c in (raw['command'] as List? ?? const [])) '$c'],
        tests: tests,
      ));
    }
    return out;
  }
}

/// Tool `tool_package` — export/import/list paket tool buatan.
/// Import menjalankan contract tests lewat [runTests] (ToolForge + sandbox)
/// dan instalasi lewat [install] — keduanya fail-closed.
class ToolPackageTool implements Tool {
  ToolPackageTool({
    required this.installedDefs,
    required this.runTests,
    required this.install,
    required this.hasTool,
    this.maxTools = 32,
  });

  /// Def tool `made_*` yang terpasang saat ini (dari registry).
  final List<ForgedToolDef> Function() installedDefs;

  /// Contract tests (null/error detail bila gagal atau sandbox tidak ada).
  final Future<String?> Function(ForgedToolDef def) runTests;

  /// Instalasi def ke registry; false bila nama sudah dipakai.
  final bool Function(ForgedToolDef def) install;

  final bool Function(String name) hasTool;

  final int maxTools;

  static final RegExp _packager = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'tool_package',
        description:
            'Ekspor/impor paket tool buatan (made_*) sebagai manifest JSON '
            'ber-checksum. Impor wajib lulus checksum + contract tests '
            'sebelum terpasang (fail-closed).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['export', 'import', 'list'],
            },
            'id': {'type': 'string', 'description': 'Id paket (export).'},
            'name': {'type': 'string', 'description': 'Nama paket (export).'},
            'version': {
              'type': 'string',
              'description': 'Versi paket (export).',
            },
            'package': {
              'type': 'string',
              'description': 'Manifest JSON paket (import, inline).',
            },
            'dry_run': {
              'type': 'boolean',
              'description':
                  'Impor hanya verifikasi + contract tests tanpa install.',
            },
          },
          'required': ['action'],
        },
        risk: 'high',
        timeoutSec: 120,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = '${args['action'] ?? ''}'.trim();
    switch (action) {
      case 'export':
        final id = '${args['id'] ?? ''}'.trim();
        if (!_packager.hasMatch(id)) {
          return const ToolResult(
            callId: '',
            content: 'id paket tidak valid (wajib [a-z0-9][a-z0-9_-]{0,63}).',
            isError: true,
          );
        }
        final defs = installedDefs();
        if (defs.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'Tidak ada tool made_* terpasang untuk diekspor.',
            isError: true,
          );
        }
        final manifest = const ToolPackager(maxTools: 32).export(
          id: id,
          name: '${args['name'] ?? id}'.trim(),
          version: '${args['version'] ?? '1.0.0'}'.trim(),
          defs: defs.length > maxTools ? defs.sublist(0, maxTools) : defs,
        );
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ')
              .convert(manifest.toJson()),
        );
      case 'import':
        final raw = '${args['package'] ?? ''}'.trim();
        if (raw.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'argumen `package` (manifest JSON) wajib.',
            isError: true,
          );
        }
        Map<String, dynamic> manifest;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) throw const FormatException('bukan object');
          manifest = Map<String, dynamic>.from(decoded);
        } on FormatException {
          return const ToolResult(
            callId: '',
            content: 'manifest bukan JSON object yang valid.',
            isError: true,
          );
        }
        final verifier = ToolPackager(maxTools: maxTools);
        final err = verifier.verifyManifest(manifest);
        if (err != null) {
          return ToolResult(
            callId: '',
            content: 'paket ditolak: $err',
            isError: true,
          );
        }
        final defs = verifier.defsFromManifest(manifest);
        final installed = <String>[];
        final skipped = <String>[];
        for (final def in defs) {
          if (hasTool(def.name)) {
            skipped.add(def.name);
            continue;
          }
          final failure = await runTests(def);
          if (failure != null) {
            return ToolResult(
              callId: '',
              content: 'contract tests gagal untuk ${def.name}: $failure — '
                  'tidak ada tool yang terpasang dari tool ini.',
              isError: true,
            );
          }
          if (args['dry_run'] == true) {
            installed.add('${def.name} (dry-run)');
            continue;
          }
          if (!install(def)) {
            skipped.add(def.name);
          } else {
            installed.add(def.name);
          }
        }
        final report = ToolPackageVerifyReport(
          ok: true,
          installed: installed,
          skippedExisting: skipped,
        );
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert(report.toJson()),
        );
      case 'list':
        final defs = installedDefs()..sort((a, b) => a.name.compareTo(b.name));
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert({
            'count': defs.length,
            'tools': [
              for (final d in defs)
                {'name': d.name, 'description': d.description},
            ],
          }),
        );
      default:
        return const ToolResult(
          callId: '',
          content: 'action tidak dikenal (export|import|list).',
          isError: true,
        );
    }
  }
}
