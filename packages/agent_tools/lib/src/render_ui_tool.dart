import 'dart:convert';

import 'package:agent_core/agent_core.dart';

/// render_ui (D1) — agen menghasilkan antarmuka generatif yang aman.
///
/// Input adalah spesifikasi GenUI (grammar tertutup: section/text/metric/
/// chart/form/actions/divider). Tool memvalidasi fail-closed; spesifikasi
/// valid dikembalikan sebagai blok fenced ```genui sehingga host mana pun
/// (Flutter, web, CLI) bisa merendernya dari teks chat tanpa perubahan
/// protokol. Spesifikasi tidak valid ditolak dengan pesan kesalahan — agen
/// bisa memperbaikinya dan memanggil ulang.
class RenderUiTool implements Tool {
  const RenderUiTool();

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'render_ui',
    description:
        'Render antarmuka interaktif untuk pengguna (D1 GenUI). Sediakan '
        'spesifikasi JSON dengan tipe node terbatas: section, text, metric, '
        'chart (bar|line), form (text|number|select), actions, divider. '
        'Maksimal 100 node, depth 8. Gunakan untuk dashboard, ringkasan '
        'bergrafik, atau formulir input — bukan pengganti jawaban teks.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'spec': {
          'type': 'object',
          'description': 'Spesifikasi GenUI (pohon node).',
        },
      },
      'required': ['spec'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final spec = args['spec'];
    if (spec == null) {
      return const ToolResult(
        callId: '',
        content: 'genui: "spec" wajib diisi',
        isError: true,
      );
    }
    final GenUiSpec parsed;
    try {
      parsed = GenUiSpec.parse(spec);
    } on FormatException catch (e) {
      return ToolResult(
        callId: '',
        content:
            '${e.message}. Perbaiki spesifikasi lalu panggil render_ui ulang.',
        isError: true,
      );
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(parsed.toJson());
    return ToolResult(
      callId: '',
      content: 'UI dirender untuk pengguna:\n\n```genui\n$encoded\n```',
    );
  }
}
