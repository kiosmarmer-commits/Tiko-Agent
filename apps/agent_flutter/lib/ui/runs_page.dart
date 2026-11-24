import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Run-inspector (GUI-P2-04): snapshot turn agent aktif + riwayat terbaru
/// dengan langkah tool per run — read-only via `GET /v1/runs`. Dibawahnya
/// DAG run team Fase C (E5) — read-only via `GET /v1/teams/runs`.
class RunsPage extends StatelessWidget {
  const RunsPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
    this.teamRuns,
  });

  final RunsSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;

  /// Laporan run team (`BotTeamStore.listRunReports`); null = belum dimuat.
  final List<Map<String, dynamic>>? teamRuns;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final total = snap == null ? 0 : snap.active.length + snap.recent.length;
    return Column(
      children: [
        PageHeader(
          title: 'Runs',
          subtitle: snap == null
              ? 'Inspeksi turn agent: aktif, langkah tool, subagent'
              : '${snap.active.length} aktif · ${snap.recent.length} riwayat'
                  '${snap.truncated ? '(terpotong)' : ''} · $total run',
          online: online,
          trailing: onRefresh == null
              ? null
              : IconButton(
                  onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (surfaceSection != null) surfaceSection!,
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: !hasContent(snap, teamRuns)
              ? Center(
                  child: Text(
                      snap == null
                          ? 'Belum ada snapshot \u2014 tekan refresh.'
                          : 'Belum ada run terekam.',
                      style: TextStyle(color: context.simpulMuted)),
                )
              : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        if (snap != null && snap.active.isNotEmpty) ...[
                          _SectionLabel('AKTIF'),
                          for (final run in snap.active)
                            _RunTile(run: run, active: true),
                        ],
                        if (snap != null && snap.recent.isNotEmpty) ...[
                          _SectionLabel('RIWAYAT'),
                          for (final run in snap.recent)
                            _RunTile(run: run, active: false),
                        ],
                        if (snap?.cost != null) ...[
                          _SectionLabel(
                              'BIAYA/TOKEN (${snap!.cost!.days} HARI)'),
                          _CostCard(summary: snap.cost!),
                        ],
                        if (teamRuns != null) ...[
                          _SectionLabel('RUN TEAM (Fase C)'),
                          if (teamRuns!.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: Text('Belum ada run tim terekam.',
                                  style: TextStyle(
                                      color: context.simpulMuted)),
                            ),
                          for (final report in teamRuns!)
                            _TeamRunTile(report: report),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }
}

/// Bila kedua sumber kosong (turn & team run) → halaman menampilkan empty
/// state; run-team section tampil walau snapshot turn kosong/nnull.
bool hasContent(RunsSnapshot? snap, List<Map<String, dynamic>>? teamRuns) =>
    (snap != null && (snap.active.isNotEmpty || snap.recent.isNotEmpty)) ||
    (teamRuns != null && teamRuns.isNotEmpty) ||
    (snap?.cost != null && snap!.cost!.totalTurns > 0);

class _CostCard extends StatelessWidget {
  const _CostCard({required this.summary});

  final CostSummary summary;

  String _successRate(int success, int turns) =>
      turns == 0 ? '-' : '${((success / turns) * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${summary.totalTurns} turn · ${summary.totalTokensUsed} token · '
                '${summary.totalToolCalls} tool · sukses '
                '${_successRate(summary.totalSuccess, summary.totalTurns)}',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          if (summary.buckets.isEmpty)
            Text('Belum ada aktivitas dalam jendela ${summary.days} hari.',
                style: TextStyle(color: context.simpulMuted, fontSize: 12))
          else
            Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FlexColumnWidth(1.5),
                2: FlexColumnWidth(2),
                3: FlexColumnWidth(1.5),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(
                      color: context.simpulMuted.withValues(alpha: 0.08)),
                  children: const [
                    _CostHeader('CHART'),
                    _CostHeader('TURN'),
                    _CostHeader('TOKEN'),
                    _CostHeader('SUKSES'),
                  ],
                ),
                for (final b in summary.buckets.take(10))
                  TableRow(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(b.key,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text('${b.turns}'),
                    Text('${b.tokensUsed}'),
                    Text(_successRate(b.success, b.turns)),
                  ]),
              ],
            ),
        ],
      ),
    );
  }
}

class _CostHeader extends StatelessWidget {
  const _CostHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: context.simpulMuted)),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: context.simpulMuted)),
      );
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run, required this.active});
  final RunEntry run;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final danger = (!active && run.success == false) || run.error != null;
    final badgeColor = active
        ? context.simpulInfo
        : danger
            ? context.simpulDanger
            : context.simpulSuccess;
    final badgeText = active
        ? 'RUNNING'
        : run.state == 'error'
            ? 'ERROR'
            : (run.success == false ? 'GAGAL' : 'SELESAI');
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Text(run.input.isEmpty ? '(tanpa input)' : run.input,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${run.session} \u00b7 ${run.channel}'
        '${run.subagent && run.parent != null ? ' \u00b7 subagent dari ${run.parent}' : ''}'
        ' \u00b7 ${run.steps.length} langkah'
        '${run.tokensUsed > 0 ? ' \u00b7 ${run.tokensUsed} token' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.simpulMuted, fontSize: 12),
      ),
      leading: run.subagent
          ? const Icon(Icons.account_tree_outlined)
          : const Icon(Icons.play_circle_outline),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(badgeText,
            style: TextStyle(
                color: badgeColor,
                fontSize: 10,
                fontWeight: FontWeight.w700)),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(run.answer == null && run.error == null
              ? 'Jawaban/kesalahan belum ada.'
              : (run.error ?? run.answer ?? '')),
        ),
        if (run.steps.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Tidak ada panggilan tool dalam run ini.',
                style: TextStyle(color: context.simpulMuted)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Langkah tool ${run.steps.length}:',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.simpulMuted)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: context.simpulPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.simpulBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final step in run.steps)
                        Text(
                          '${step.isError ? '\u00d7' : '\u2713'} ${step.tool} '
                          '[${step.verdict}] ${step.durationMs}ms',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: step.isError
                                ? context.simpulDanger
                                : context.simpulSuccess,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// E5 — DAG view run team: laporan orkestrasi Fase C (`/v1/teams/runs`)
/// dirender read-only; ketuk untuk membuka DAG rencana per task.
class _TeamRunTile extends StatelessWidget {
  const _TeamRunTile({required this.report});

  final Map<String, dynamic> report;

  @override
  Widget build(BuildContext context) {
    final success = report['success'] == true;
    final badgeColor = success ? context.simpulSuccess : context.simpulDanger;
    final plan = (report['plan'] as List? ?? const []).length;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.account_tree_outlined),
      title: Text(
        report['goal']?.toString().isEmpty ?? true
            ? '(tanpa tujuan)'
            : report['goal'].toString(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${report['run_id'] ?? '-'} · rencana $plan tugas · '
        '${report['tokens_used'] ?? 0} token',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.simpulMuted, fontSize: 12),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          success ? 'SUKSES' : 'GAGAL',
          style: TextStyle(
              color: badgeColor, fontSize: 10, fontWeight: FontWeight.w700),
        ),
      ),
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (sheetContext) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            maxChildSize: 0.95,
            builder: (sheetContext, controller) => _TeamRunDagSheet(
              report: report,
              scrollController: controller,
            ),
          ),
        );
      },
    );
  }
}

class _TeamRunDagSheet extends StatelessWidget {
  const _TeamRunDagSheet({required this.report, required this.scrollController});

  final Map<String, dynamic> report;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final tasks = teamRunPlanTasks(report);
    final danger = context.simpulDanger;
    final success = context.simpulSuccess;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'DAG run ${report['run_id'] ?? '-'}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${report['goal'] ?? '-'} · rencana: '
            '${report['plan_source'] ?? '-'}',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              controller: scrollController,
              children: [
                if (tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Rencana DAG tidak tersedia pada laporan ini.',
                      style: TextStyle(color: context.simpulMuted),
                    ),
                  )
                else
                  for (final task in tasks) ...[
                    Padding(
                      padding: EdgeInsets.only(left: task.level * 24.0),
                      child: Row(
                        children: [
                          Text(
                            task.level == 0 ? '\u25cf' : '\u2514\u2500',
                            style: TextStyle(
                              fontSize: 12,
                              color: task.ok == null
                                  ? context.simpulMuted
                                  : task.ok == true
                                      ? success
                                      : danger,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            task.id,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (task.agentId != null &&
                              task.agentId!.isNotEmpty)
                            Text(
                              task.agentId!,
                              style: TextStyle(
                                fontSize: 11,
                                color: context.simpulInfo,
                              ),
                            ),
                          const Spacer(),
                          if (task.ok != null)
                            Text(
                              task.ok == true ? 'ok' : 'gagal',
                              style: TextStyle(
                                fontSize: 11,
                                color: task.ok == true ? success : danger,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(
                          left: task.level * 24.0 + 20, bottom: 2),
                      child: Text(
                        task.prompt,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: context.simpulMuted, fontSize: 12),
                      ),
                    ),
                    if (task.dependsOn.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(
                            left: task.level * 24.0 + 20, bottom: 6),
                        child: Text(
                          'depends: ${task.dependsOn.join(', ')}',
                          style: TextStyle(
                              color: context.simpulMuted,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                      ),
                  ],
                const Divider(height: 24),
                Text('Sintesis',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.simpulMuted)),
                const SizedBox(height: 4),
                Text(
                  (report['synthesis'] as String?)?.trim().isEmpty ?? true
                      ? '(synthesis kosong)'
                      : report['synthesis'].toString(),
                ),
                if (report['review'] != null &&
                    (report['review'] as String).trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Review',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.simpulMuted)),
                  const SizedBox(height: 4),
                  Text(report['review'].toString()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Satu baris task DAG (terurai dari laporan run team).
class TeamRunPlanTask {
  TeamRunPlanTask({
    required this.id,
    required this.prompt,
    required this.agentId,
    required this.dependsOn,
    required this.level,
    this.ok,
  });

  final String id;
  final String prompt;
  final String? agentId;
  final List<String> dependsOn;

  /// Kedalaman dependensi (0 = tanpa depends_on) — untuk indentasi pohon.
  final int level;

  /// null = task belum dieksekusi / tidak ada node record.
  final bool? ok;
}

/// Mengurai `plan` + `nodes` dari laporan run team menjadi barisan task
/// terurut level DAG (lalu urut rencana). Membersih prompt pendek & aman
/// terhadap laporan korup (fail-closed: task tanpa id dilompati).
List<TeamRunPlanTask> teamRunPlanTasks(Map<String, dynamic> report) {
  final plan = (report['plan'] as List? ?? const []);
  final deps = <String, List<String>>{};
  final order = <String>[];
  for (final raw in plan) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty || order.contains(id)) continue;
    order.add(id);
    deps[id] = [
      for (final d in (raw['depends_on'] as List? ?? const []))
        if (d.toString().isNotEmpty) d.toString(),
    ];
  }
  bool? statusOf(String id) {
    for (final n in (report['nodes'] as List? ?? const [])) {
      if (n is! Map) continue;
      if (n['node_id']?.toString() == id) return n['ok'] == true;
    }
    return null;
  }

  final tasks = <TeamRunPlanTask>[];
  for (final id in order) {
    Map? spec;
    for (final raw in plan) {
      if (raw is Map && raw['id']?.toString() == id) spec = raw;
    }
    final dependsOn = deps[id] ?? const <String>[];
    tasks.add(
      TeamRunPlanTask(
        id: id,
        prompt:
            (spec?['prompt']?.toString() ?? '').trim(),
        agentId: spec?['agent_id']?.toString(),
        dependsOn: dependsOn,
        level: _dagLevel(id, deps),
        ok: statusOf(id),
      ),
    );
  }
  tasks.sort((a, b) {
    final c = a.level.compareTo(b.level);
    return c != 0 ? c : order.indexOf(a.id).compareTo(order.indexOf(b.id));
  });
  return tasks;
}

int _dagLevel(String id, Map<String, List<String>> deps,
    {Set<String>? visiting}) {
  final direct = deps[id];
  if (direct == null || direct.isEmpty) return 0;
  final seen = visiting ?? <String>{};
  if (!seen.add(id)) return 0;
  var max = -1;
  for (final dep in direct) {
    if (!deps.containsKey(dep)) continue;
    final l = _dagLevel(dep, deps, visiting: seen);
    if (l > max) max = l;
  }
  return max + 1;
}
