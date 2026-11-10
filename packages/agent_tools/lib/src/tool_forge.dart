import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'sandbox.dart';

/// Command executor used to run forged tools and their contract
/// tests; injectable so tests never need a real OS sandbox.
typedef ForgedCommandRunner = Future<ProcessResult> Function(
  List<String> parts,
);

/// One contract test: the JSON input plus the expectation the
/// forged tool must satisfy before installation.
class ForgeTest {
  const ForgeTest({
    required this.input,
    this.expectContains,
    this.expectExit0 = true,
  });

  final Map<String, dynamic> input;
  final String? expectContains;
  final bool expectExit0;
}

/// Definition of a forged tool: a sandboxed command that receives
/// the tool arguments as one JSON argument appended last.
class ForgedToolDef {
  const ForgedToolDef({
    required this.name,
    required this.description,
    required this.command,
    required this.tests,
  });

  final String name;
  final String description;
  final List<String> command;
  final List<ForgeTest> tests;
}

/// tool_forge (NEW-12): typed tools created at runtime. A tool is
/// installed only after every contract test passes, and the forge
/// stays fail-closed: with no sandbox there is no way to verify
/// the contract, so nothing is installed at all.
class ToolForge {
  ToolForge({this.sandbox, ForgedCommandRunner? commandRunner})
      : _commandRunner = commandRunner;

  final SandboxRunner? sandbox;
  final ForgedCommandRunner? _commandRunner;

  final Map<String, ForgedToolDef> _installed = {};

  /// Names installed through this forge.
  List<String> get installed => _installed.keys.toList();

  /// True when [name] was installed through this forge.
  bool isInstalled(String name) => _installed.containsKey(name);

  /// Records a definition as installed.
  void markInstalled(ForgedToolDef def) {
    _installed[def.name] = def;
  }

  /// Runs every contract test for [def]; returns null when all
  /// pass, otherwise the first failure detail.
  Future<String?> runContractTests(ForgedToolDef def) async {
    for (var i = 0; i < def.tests.length; i++) {
      final t = def.tests[i];
      final ProcessResult? outcome;
      try {
        outcome = await execute(def, t.input);
      } catch (e) {
        return 'uji #${i + 1}: error: $e';
      }
      if (outcome == null) {
        return 'uji #${i + 1}: sandbox tidak tersedia (fail-closed)';
      }
      if (t.expectExit0 && outcome.exitCode != 0) {
        return 'uji #${i + 1}: exit ${outcome.exitCode}';
      }
      final expect = t.expectContains ?? '';
      if (expect.isNotEmpty) {
        final out = '${outcome.stdout}${outcome.stderr}';
        if (!out.contains(expect)) {
          return 'uji #${i + 1}: output tidak memuat "$expect"';
        }
      }
    }
    return null;
  }

  /// Executes [def] against [input]; null means no sandbox/runner.
  Future<ProcessResult?> execute(
    ForgedToolDef def,
    Map<String, dynamic> input,
  ) async {
    final parts = [...def.command, jsonEncode(input)];
    final runner = _commandRunner;
    if (runner != null) {
      return runner(parts);
    }
    final sb = sandbox;
    if (sb == null) return null;
    return sb.run(parts, timeout: const Duration(seconds: 20));
  }
}

/// A tool installed by [ToolForge]; serves its spec from the def.
class ForgedTool implements Tool {
  ForgedTool({required this.def, required this.forge});

  final ForgedToolDef def;
  final ToolForge forge;

  @override
  ToolSpec get spec => ToolSpec(
    name: def.name,
    description: def.description,
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'high',
    timeoutSec: 30,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final ProcessResult? result;
    try {
      result = await forge.execute(def, args);
    } catch (e) {
      return ToolResult(callId: '', content: 'gagal: $e', isError: true);
    }
    if (result == null) {
      return const ToolResult(
        callId: '',
        content: 'sandbox tidak tersedia (fail-closed)',
        isError: true,
      );
    }
    final out = (result.stdout ?? '').toString().trim();
    final err = (result.stderr ?? '').toString().trim();
    if (result.exitCode != 0) {
      final parts = [
        if (err.isNotEmpty) err,
        if (out.isNotEmpty) out,
      ];
      return ToolResult(
        callId: '',
        content:
            parts.isEmpty ? 'exit ${result.exitCode}' : parts.join('\n'),
        isError: true,
      );
    }
    return ToolResult(callId: '', content: out.isEmpty ? 'OK' : out);
  }
}

/// tool_forge — create a typed tool at runtime with mandatory
/// contract tests; the tool is installed only when all tests pass.
class ToolForgeTool implements Tool {
  ToolForgeTool({
    required this.forge,
    required this.hasTool,
    required this.registerTool,
  });

  final ToolForge forge;

  /// Registry view used to reject name collisions.
  final bool Function(String name) hasTool;

  /// Installs the forged tool into the registry.
  final void Function(Tool tool) registerTool;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'tool_forge',
    description:
        'Buat tool baru saat runtime. command dijalankan di sandbox '
        'dengan argumen tool dikirim sebagai JSON di argumen terakhir. '
        'Tool hanya terpasang jika semua uji kontrak lulus.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Nama tool.'},
        'description': {
          'type': 'string',
          'description': 'Deskripsi tool (maks 300 karakter).',
        },
        'command': {
          'type': 'string',
          'description': 'Executable + argumen, dipisah spasi.',
        },
        'tests': {
          'type': 'array',
          'description':
              'Uji kontrak: {input: {...}, expect_contains?: string, '
              'expect_exit0?: bool}.',
        },
      },
      'required': ['name', 'description', 'command', 'tests'],
    },
    risk: 'high',
    timeoutSec: 120,
  );

  static const List<String> _badChars = [
    ' ',
    ';',
    '&',
    '|',
    '<',
    '>',
    '`',
    r'$',
    '"',
    "'",
    '\\',
  ];

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final name = (args['name'] as String?)?.trim() ?? '';
    final description = (args['description'] as String?)?.trim() ?? '';
    final command = (args['command'] as String?)?.trim() ?? '';
    final rawTests = args['tests'];
    if (!RegExp(r'^[a-z][a-z0-9_]{2,30}$').hasMatch(name)) {
      return const ToolResult(
        callId: '',
        content: 'name harus cocok pola ^[a-z][a-z0-9_] 3-31 karakter',
        isError: true,
      );
    }
    if (hasTool(name) || forge.isInstalled(name)) {
      return ToolResult(
        callId: '',
        content: 'nama sudah dipakai: $name',
        isError: true,
      );
    }
    if (description.isEmpty || description.length > 300) {
      return const ToolResult(
        callId: '',
        content: 'description wajib 1-300 karakter',
        isError: true,
      );
    }
    final argv = command
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (argv.isEmpty || argv.length > 8) {
      return const ToolResult(
        callId: '',
        content: 'command wajib 1-8 kata (executable + argumen)',
        isError: true,
      );
    }
    for (final part in argv) {
      if (_badChars.any(part.contains)) {
        return const ToolResult(
          callId: '',
          content: 'command memuat karakter terlarang',
          isError: true,
        );
      }
    }
    if (rawTests is! List || rawTests.isEmpty || rawTests.length > 10) {
      return const ToolResult(
        callId: '',
        content: 'tests wajib array 1-10 uji kontrak',
        isError: true,
      );
    }
    final tests = <ForgeTest>[];
    for (final item in rawTests) {
      if (item is! Map) {
        return const ToolResult(
          callId: '',
          content: 'setiap uji harus objek {input, ...}',
          isError: true,
        );
      }
      final input = item['input'];
      if (input is! Map) {
        return const ToolResult(
          callId: '',
          content: 'input uji wajib objek',
          isError: true,
        );
      }
      final expectContains = item['expect_contains']?.toString() ?? '';
      final rawExit0 = item['expect_exit0'];
      final expectExit0 = rawExit0 is bool ? rawExit0 : true;
      final expect = expectContains.trim();
      tests.add(ForgeTest(
        input: Map<String, dynamic>.from(input),
        expectContains: expect.isEmpty ? null : expect,
        expectExit0: expectExit0,
      ));
    }
    final def = ForgedToolDef(
      name: name,
      description: description,
      command: argv,
      tests: tests,
    );
    final failure = await forge.runContractTests(def);
    if (failure != null) {
      return ToolResult(
        callId: '',
        content: 'Kontrak gagal — tool TIDAK dipasang: $failure',
        isError: true,
      );
    }
    final tool = ForgedTool(def: def, forge: forge);
    try {
      registerTool(tool);
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'gagal memasang: $e',
        isError: true,
      );
    }
    forge.markInstalled(def);
    return ToolResult(
      callId: '',
      content: 'OK tool "$name" terpasang (${tests.length} uji lulus)',
    );
  }
}
