part of 'tiko_runtime.dart';

// Fase E5 — surface A2UI bawaan dari run riset (Fase D). Fold generator
// murni di sini supaya scheduler/REST hanya memanggil + ingest; keluaran
// tetap tervalidasi parseA2uiMessages (fail-closed whitelist yang sama).

/// Perkiraan batas teks komponen A2UI (sumber kebenaran tetap di
/// `agent_a2ui.dart); dipakai untuk memotong teks sebelum parse.
const int _researchSurfaceMaxText = 4000;

/// Membangun pesan `createSurface` ringkasan satu run riset: heading
/// pertanyaan, metric status/token/panggilan tool, daftar query (caption),
/// laporan (mono), dan catatan error bila gagal. Murni & deterministik —
/// pemanggil menjalankan [parseA2uiMessages]/[A2uiSurfaceSet.apply] untuk
/// validasi penuh (fungsi ini hanya jaga batas & sanitasi id).
List<A2uiMessage> researchRunSurfaceMessages(ResearchRunRecord r) {
  final safeRunId =
      r.runId.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');
  var suffix = safeRunId;
  if (suffix.length > 54) suffix = suffix.substring(0, 54);
  final surfaceId = 'research-$suffix';

  String clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  final question = clip(r.question.trim().isEmpty ? '(kosong)' : r.question, 120);
  final components = <Map<String, Object>>[
    {
      'id': 'root',
      'component': 'Column',
      'children': [
        'head',
        'm-status',
        'm-tokens',
        'm-tools',
        for (var i = 0; i < r.queries.length && i < 6; i++) 'q$i',
        'rep',
        if (r.error != null && r.error!.trim().isNotEmpty) 'err',
      ],
    },
    {
      'id': 'head',
      'component': 'Text',
      'variant': 'heading',
      'text': 'Riset: $question',
    },
    {
      'id': 'm-status',
      'component': 'Metric',
      'label': 'Status',
      'value': r.status,
      if (r.status == 'failed') 'tone': 'error',
    },
    {
      'id': 'm-tokens',
      'component': 'Metric',
      'label': 'Token',
      'value': r.tokensUsed,
    },
    {
      'id': 'm-tools',
      'component': 'Metric',
      'label': 'Panggilan tool',
      'value': r.toolCallCount,
    },
    for (var i = 0; i < r.queries.length && i < 6; i++)
      {
        'id': 'q$i',
        'component': 'Text',
        'variant': 'caption',
        'text': clip('${i + 1}. ${r.queries[i]}', 200),
      },
    {
      'id': 'rep',
      'component': 'Text',
      'variant': 'mono',
      'text': clip('data/research/reports/${r.reportName}', 200),
    },
  ];

  final err = r.error?.trim() ?? '';
  if (err.isNotEmpty) {
    components.add({
      'id': 'err',
      'component': 'Text',
      'variant': 'body',
      'text': clip('Gagal: $err', _researchSurfaceMaxText),
    });
  }

  final envelope = <String, dynamic>{
    'version': '1.0',
    'createSurface': {
      'surfaceId': surfaceId,
      'components': components,
    },
  };
  return parseA2uiMessages(envelope);
}
