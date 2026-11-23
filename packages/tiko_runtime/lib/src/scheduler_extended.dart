// Fase F5 (docs/15 §6) — otonomi scheduling di sisi runtime: probe watcher
// URL, digest proaktif harian deterministik, dan suntik konteks antar-job.
// Part dari library tiko_runtime (import dart:async/dart:convert/dart:io
// sudah ada di tiko_runtime.dart).
part of 'tiko_runtime.dart';

/// F5 — prefix prompt job digest proaktif harian (ala ChatGPT Pulse/Hermes
/// research digest). Handler runtime membangun digest deterministik dari
/// state nyata (kanban + riset + job) — tanpa turn LLM.
const String digestPromptPrefix = '[DIGEST]';

bool isDigestJobPrompt(String prompt) => prompt.trimLeft().startsWith(
      digestPromptPrefix,
    );

/// F5 — jalankan probe URL watcher: GET read-only, timeout 10s, scheme
/// http(s), tanpa kredensial, body cap 64 KB. Fingerprint = status + panjang
/// + checksum FNV-1a — stabilitas terhadap trailing whitespace tidak dijamin;
/// cukup untuk deteksi perubahan konten halaman monitor sederhana.
Future<WatchProbeResult> runWatchProbe(WatchProbe probe) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(probe.url));
      // Jangan ikuti cookie/kredensial — watcher hanya butuh status+body.
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decodeStream(
        res.cast<List<int>>().take(64 * 1024),
      ).timeout(const Duration(seconds: 5));
      return WatchProbeResult(
        fingerprint:
            'http:${res.statusCode}:${body.length}:${fnv1aHex(body)}',
        ok: res.statusCode >= 200 && res.statusCode < 400,
        detail: 'status ${res.statusCode}, ${body.length} byte',
      );
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    return WatchProbeResult(
      fingerprint: 'error',
      ok: false,
      detail: 'probe gagal: $e',
      error: '$e',
    );
  }
}

/// F5 — bangun blok konteks dari output terakhir job-jobs sumber
/// (fail-soft: id tidak dikenal/berkas hilang dilompati dengan catatan).
String buildJobContextBlock(
  Job job, {
  required String? Function(String jobId) outputFor,
  required DateTime? Function(String jobId) atFor,
}) {
  if (job.contextFrom.isEmpty) return '';
  final lines = <String>['[Konteks otomatis dari job lain — read-only:'];
  for (final srcId in job.contextFrom) {
    final text = outputFor(srcId);
    if (text == null) {
      lines.add('- job $srcId: belum ada output tercatat');
      continue;
    }
    final at = atFor(srcId);
    final stamp = at == null ? '' : ' (${at.toIso8601String()})';
    lines.add('- job $srcId$stamp:\n${text.split('\n').map((l) => '  $l').join('\n')}');
  }
  lines.add('Gunakan konteks di atas bila relevan; jangan kutip ulang panjang.]');
  return lines.join('\n');
}

extension TikoRuntimeSchedulerF5 on TikoRuntime {
  /// F5 — digest harian deterministik dari state nyata runtime:
  /// kanban (hitungan status + doing teratas), riset terakhir (maks 3),
  /// dan kesehatan scheduler (job gagal beruntun). Tanpa turn LLM;
  /// hasil dikirim via channel milik job seperti digest riset.
  Future<String> buildDailyDigest() async {
    final now = DateTime.now().toUtc();
    final lines = <String>[
      '📰 Digest harian — ${now.toIso8601String().substring(0, 10)}',
    ];

    // Kanban (best-effort).
    try {
      final board = KanbanBoard(p.join(dataDir, 'kanban.json'));
      final cards = await board.list();
      final byState = <KanbanState, int>{};
      final doing = <String>[];
      for (final card in cards) {
        byState[card.state] = (byState[card.state] ?? 0) + 1;
        if (card.state == KanbanState.doing && doing.length < 3) {
          doing.add(card.title);
        }
      }
      final counts = [
        for (final e in byState.entries) '${e.value} ${e.key.name}',
      ].join(', ');
      lines
        ..add('')
        ..add('Kanban: ${counts.isEmpty ? 'kosong' : counts}');
      for (final t in doing) {
        lines.add('- doing: $t');
      }
    } catch (e) {
      lines.add('Kanban: tidak tersedia ($e)');
    }

    // Riset terakhir (maks 3).
    try {
      final runs = researchRunStore.runs;
      if (runs.isNotEmpty) {
        lines
          ..add('')
          ..add('Riset terakhir:');
        for (final r in runs.take(3)) {
          final q = r.question.length > 60
              ? '${r.question.substring(0, 59)}…'
              : r.question;
          lines.add('- [$r.status] $q (${r.reportName})');
        }
      } else {
        lines.add('Riset terakhir: belum ada');
      }
    } catch (_) {
      lines.add('Riset terakhir: tidak tersedia');
    }

    // Kesehatan scheduler.
    final jobs = this.jobs.all;
    final failing = jobs.where((j) => j.failureStreak > 0).toList()
      ..sort((a, b) => b.failureStreak.compareTo(a.failureStreak));
    final today = <Job>[];
    for (final j in jobs) {
      if (!j.enabled || j.paused) continue;
      final next = j.nextRun;
      if (next.isAfter(now.subtract(const Duration(seconds: 1))) &&
          next.isBefore(now.add(const Duration(hours: 24)))) {
        today.add(j);
      }
    }
    lines
      ..add('')
      ..add('Scheduler: ${jobs.length} job (${today.length} berjalan ≤24 jam)');
    for (final j in failing.take(3)) {
      lines.add('- gagal ${j.failureStreak}x: ${j.id} (${j.lastError ?? ''})');
    }
    if (failing.isEmpty) {
      lines.add('- semua job sehat');
    }
    return lines.join('\n');
  }
}

/// F5 — tool `schedule_digest`: pasang digest proaktif harian ke channel
/// milik sesi pemanggil (medium risk, seperti schedule_research).
class ScheduleDigestTool implements Tool {
  ScheduleDigestTool(this.scheduler);

  final Future<Job> Function({
    required String cron,
    required String timezone,
    required String channel,
    required String userKey,
  }) scheduler;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'schedule_digest',
        description:
            'F5 — pasang digest proaktif harian: ringkasan kanban, riset '
            'terakhir, dan kesehatan job dikirim berkala ke channel ini '
            '(tanpa turn LLM, deterministik).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'cron': {
              'type': 'string',
              'description': 'Default "0 8 * * *" (08:00 harian).',
            },
            'timezone': {
              'type': 'string',
              'description': 'Zona IANA; default UTC.',
            },
          },
        },
        risk: 'medium',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cron = ((args['cron'] as String?) ?? '0 8 * * *').trim();
    final timezone = ((args['timezone'] as String?) ?? 'UTC').trim();
    try {
      final job = await scheduler(
        cron: cron,
        timezone: timezone,
        channel: ctx.session.channel,
        userKey: ctx.session.userKey,
      );
      return ToolResult(
        callId: '',
        content: 'Digest harian terjadwal id=${job.id} '
            'cron=${job.cron} tz=${job.timezone} '
            'channel=${job.channel}\n'
            'next_run=${job.nextRun.toIso8601String()}',
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'schedule_digest gagal: $e',
        isError: true,
      );
    }
  }
}
