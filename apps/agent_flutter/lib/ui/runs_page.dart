import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Run-inspector (GUI-P2-04): snapshot turn agent aktif + riwayat terbaru
/// dengan langkah tool per run — read-only via `GET /v1/runs`.
class RunsPage extends StatelessWidget {
  const RunsPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
  });

  final RunsSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

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
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: snap == null
              ? Center(
                  child: Text('Belum ada snapshot \u2014 tekan refresh.',
                      style: TextStyle(color: context.simpulMuted)),
                )
              : (snap.active.isEmpty && snap.recent.isEmpty)
                  ? Center(
                      child: Text('Belum ada run terekam.',
                          style: TextStyle(color: context.simpulMuted)),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        if (snap.active.isNotEmpty) ...[
                          _SectionLabel('AKTIF'),
                          for (final run in snap.active)
                            _RunTile(run: run, active: true),
                        ],
                        if (snap.recent.isNotEmpty) ...[
                          _SectionLabel('RIWAYAT'),
                          for (final run in snap.recent)
                            _RunTile(run: run, active: false),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }
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
