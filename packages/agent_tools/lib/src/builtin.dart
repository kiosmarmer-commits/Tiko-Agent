import 'dart:io';

import 'package:agent_calc/agent_calc.dart';
import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import 'grep.dart';
import 'probe.dart';
import 'ssrf.dart';
import 'web_search.dart';
import 'path_safety.dart';
import 'sandbox.dart';
import 'readability.dart';

/// Built-in tools for M1 (complete set for DoD).
List<Tool> createBuiltinTools({
  String? workspaceRoot,
  SsrfGuard? ssrf,
  String searxngBaseUrl = 'http://127.0.0.1:8080',
  bool enableWebSearch = true,
  SandboxRunner? sandbox,
}) {
  final root = workspaceRoot ?? Directory.current.path;
  final guard = ssrf ?? SsrfGuard();
  return [
    DatetimeTool(),
    CalcTool(),
    ListDirTool(workspaceRoot: root),
    GrepTool(workspaceRoot: root),
    ProbeTool(workspaceRoot: root),
    ReadFileTool(workspaceRoot: root),
    WriteFileTool(workspaceRoot: root),
    ShellTool(
      sandbox:
          sandbox ?? SandboxRunner(kind: SandboxKind.none, workspacePath: root),
    ),
    WebFetchTool(ssrf: guard),
    if (enableWebSearch)
      WebSearchTool(searxngBaseUrl: searxngBaseUrl, ssrf: guard),
  ];
}

class DatetimeTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
    name: 'datetime',
    description: 'Dapatkan tanggal dan waktu saat ini dalam UTC (ISO-8601).',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(
      callId: '',
      content: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

/// Kalkulator eksak berbasis agent_calc (CALC-ARC-04): evaluator yang
/// sama dengan direct command tiko calc (satu sumber kebenaran).
class CalcTool implements Tool {
  CalcTool({this.limits = CalcLimits.defaults});

  final CalcLimits limits;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'calc',
    description: 'Hitung ekspresi matematika secara eksak. WAJIB dipakai '
        'untuk semua aritmetika bukan-trivial (perkalian besar, desimal, '
        'persen, pangkat, akar). Mendukung format Indonesia: '
        '1.500.000,50 ; 2 juta ; 5rb ; 15% dari 2 juta.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': 'Ekspresi, mis. (2+3)*4 atau 15% dari 2 juta',
        },
        'scale': {
          'type': 'integer',
          'description': 'Digit desimal hasil pembagian/akar (0-50).',
        },
        'rounding': {
          'type': 'string',
          'enum': ['half_even', 'half_up', 'down', 'up', 'floor', 'ceiling'],
          'description': 'Mode pembulatan (default half_even).',
        },
        'locale': {
          'type': 'string',
          'enum': ['id', 'en'],
          'description': 'Format angka input (default id).',
        },
      },
      'required': ['expression'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final expression = (args['expression'] as String?)?.trim() ?? '';
    if (expression.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'expression kosong',
        isError: true,
      );
    }
    var scale = (args['scale'] as num?)?.toInt() ?? 12;
    if (scale < 0) scale = 0;
    if (scale > 50) scale = 50;
    final roundingName = args['rounding'] as String? ?? 'half_even';
    final locale = args['locale'] as String? ?? 'id';
    final RoundingMode rounding;
    try {
      rounding = RoundingMode.fromName(roundingName);
    } on FormatException catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    }
    final result = CalcEngine(limits: limits).evaluate(
      expression,
      scale: scale,
      rounding: rounding,
      locale: locale,
    );
    return ToolResult(
      callId: '',
      content: result.toJsonText(),
      isError: !result.ok,
    );
  }
}
