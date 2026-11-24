import 'dart:convert';

import 'package:agent_core/agent_core.dart';

/// render_a2ui (Fase E) — agen menghasilkan UI A2UI v1.0 yang aman.
///
/// Input `{ "messages": [ ...envelope A2UI v1.0... ] }`. Tool memvalidasi
/// fail-closed lewat [parseA2uiMessages]; pesan valid dikembalikan sebagai
/// blok fenced ```a2ui sehingga host mana pun (Flutter, web, CLI) bisa
/// merendernya dari teks chat tanpa perubahan protokol. Pesan tidak valid
/// ditolak dengan pesan kesalahan — agen bisa memperbaikinya lalu memanggil
/// ulang. Alias lama `render_ui` (grammar genui) tetap terdaftar terpisah
/// dan tidak diubah.
class RenderA2uiTool implements Tool {
  const RenderA2uiTool();

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'render_a2ui',
        description:
            'Render antarmuka interaktif untuk pengguna (A2UI v1.0). Kirim '
            '{"messages": [ ... ]} berisi envelope A2UI v1.0: createSurface, '
            'updateComponents, updateDataModel, deleteSurface. Komponen flat '
            'per id dengan whitelist Tiko: Row, Column, Card, Divider, Text, '
            'Image, Icon, Button, TextField, CheckBox, ChoicePicker, Slider, '
            'DateTimeInput, Metric, Chart, KanbanCard. createSurface wajib '
            'tepat satu komponen id "root". Maksimal 24 pesan, 120 komponen '
            'per surface, depth 8, teks 4000 karakter, 8 aksi per surface. '
            'Gunakan untuk dashboard, kartu status, form input, tabel, atau '
            'wizard — bukan pengganti jawaban teks. Beri surfaceId prefix '
            'page.<halaman>. (halaman: tasks, bots, automation, runs, skills, '
            'security) agar surface tampil di halaman GUI tersebut.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'messages': {
              'type': 'array',
              'description':
                  'Daftar envelope A2UI v1.0 (JSON array atau JSONL string).',
            },
          },
          'required': ['messages'],
        },
        risk: 'medium',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final raw = args['messages'];
    if (raw == null) {
      return const ToolResult(
        callId: '',
        content: 'a2ui: "messages" wajib diisi',
        isError: true,
      );
    }
    final List<A2uiMessage> messages;
    try {
      messages = parseA2uiMessages(raw);
    } on FormatException catch (e) {
      return ToolResult(
        callId: '',
        content:
            '${e.message}. Perbaiki pesan lalu panggil render_a2ui ulang.',
        isError: true,
      );
    }
    final jsonl = messages.map((m) => jsonEncode(m.toJson())).join('\n');
    final surfaces = messages.map((m) => m.surfaceId).toSet().join(', ');
    return ToolResult(
      callId: '',
      content: 'UI dirender untuk pengguna (${messages.length} pesan, '
          'surface: $surfaces):\n\n```a2ui\n$jsonl\n```',
    );
  }
}
