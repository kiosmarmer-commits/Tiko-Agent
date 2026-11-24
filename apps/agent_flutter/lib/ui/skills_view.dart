import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Skills Manager (GUI-P1-03): list + feedback + lifecycle gate
/// (evaluate/approve/rollback) di atas `GET/POST /v1/skills/*`, satu sumber
/// data dengan web UI. Feedback hanya aktif untuk status trial/approved
/// sesuai gate `RuntimeSkillApi.recordFeedback`; feedback tidak pernah
/// mempromosikan skill (telemetry only pada metrik).
class SkillsPage extends StatefulWidget {
  const SkillsPage({
    super.key,
    required this.skills,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
    this.onFeedback,
    this.onEvaluate,
    this.onApprove,
    this.onRollback,
    this.onLoadHistory,
  });

  final List<SkillItem> skills;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;
  final Future<bool> Function(String slug, bool positive)? onFeedback;
  final Future<SkillGateOutcome> Function(String slug)? onEvaluate;
  final Future<SkillGateOutcome> Function(String slug)? onApprove;
  final Future<SkillGateOutcome> Function(String slug)? onRollback;
  final Future<List<SkillHistoryEntry>> Function(String slug)? onLoadHistory;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  String _query = '';

  List<SkillItem> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.skills;
    return widget.skills
        .where((s) =>
            s.slug.toLowerCase().contains(q) ||
            s.name.toLowerCase().contains(q) ||
            s.status.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final skills = _filtered;
    return Column(
      children: [
        PageHeader(
          title: 'Skills',
          subtitle: '${widget.skills.length} skill \u00b7 lifecycle & feedback',
          online: widget.online,
          trailing: widget.onRefresh == null
              ? null
              : IconButton(
                  onPressed: widget.onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (widget.surfaceSection != null) widget.surfaceSection!,
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child:
                Text(widget.error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Saring slug, nama, atau status\u2026',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: skills.isEmpty
              ? Center(
                  child: Text(_query.isEmpty ? 'Belum ada skill terdaftar.' : 'Tidak ada skill yang cocok.',
                      style: TextStyle(color: context.simpulMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: skills.length,
                  itemBuilder: (context, i) {
                    final skill = skills[i];
                    return _SkillCard(
                      skill: skill,
                      onFeedback: widget.onFeedback,
                      onLifecycleAction: _runLifecycleAction,
                      onOpenDetail: () => _openDetail(context, skill),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _runLifecycleAction(
    BuildContext context,
    String action,
    SkillItem skill,
  ) async {
    final Future<SkillGateOutcome> Function(String)? callback = switch (action) {
      'evaluate' => widget.onEvaluate,
      'approve' => widget.onApprove,
      'rollback' => widget.onRollback,
      _ => null,
    };
    if (callback == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    try {
      final outcome = await callback(skill.slug);
      await widget.onLoadHistory?.call(skill.slug);
      messenger.showSnackBar(SnackBar(
        backgroundColor: outcome.ok ? okColor : failColor,
        content: Text(
          outcome.ok
              ? '${skill.slug}: ${outcome.stage} OK${outcome.message.isEmpty ? '' : ' \u2014 ${outcome.message}'}'
              : '${skill.slug}: gagal \u2014 ${outcome.message}',
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal $action ${skill.slug}: $e'),
      ));
    }
  }

  Future<void> _openDetail(BuildContext context, SkillItem skill) async {
    final history = await widget.onLoadHistory?.call(skill.slug) ?? const <SkillHistoryEntry>[];
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(skill.name.isEmpty ? skill.slug : skill.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                _StatusChip(status: skill.status),
              ],
            ),
            if (skill.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(skill.description,
                  style: TextStyle(color: context.simpulMuted, fontSize: 13)),
            ],
            const SizedBox(height: 8),
            Text(
              [
                'v${skill.version}',
                if (skill.approvedBy != null) 'disetujui oleh ${skill.approvedBy}',
                if (skill.triggers.isNotEmpty) 'triggers: ${skill.triggers.join(', ')}',
                if (skill.tools.isNotEmpty) 'tools: ${skill.tools.join(', ')}',
              ].join(' \u00b7 '),
              style: TextStyle(color: context.simpulMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text(
              'Uses ${skill.uses} \u00b7 sukses ${(skill.successRate * 100).toStringAsFixed(0)}% \u00b7 \ud83d\udc4d ${skill.positive} \u00b7 \ud83d\udc4e ${skill.negative}',
            ),
            const SizedBox(height: 12),
            Text('Riwayat gate ${skill.slug}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Belum ada riwayat gate.',
                    style: TextStyle(color: context.simpulMuted, fontSize: 12)),
              )
            else
              for (final entry in history)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entry.action == 'eval_failed' ? Icons.warning_amber_outlined : Icons.gavel_outlined,
                    color: entry.action == 'eval_failed'
                        ? context.simpulWarn
                        : context.simpulAccent,
                  ),
                  title: Text('${entry.action} \u00b7 ${entry.actor}'),
                  subtitle: Text(
                    [entry.at, if (entry.reason != null) entry.reason!].join(' \u00b7 '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.skill,
    required this.onFeedback,
    required this.onLifecycleAction,
    required this.onOpenDetail,
  });

  final SkillItem skill;
  final Future<bool> Function(String slug, bool positive)? onFeedback;
  final void Function(BuildContext, String, SkillItem) onLifecycleAction;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
        border: Border.all(color: context.simpulBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpenDetail,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    skill.slug,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                _StatusChip(status: skill.status),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              'v${skill.version}',
              'uses ${skill.uses}',
              '\ud83d\udc4d ${skill.positive}',
              '\ud83d\udc4e ${skill.negative}',
              'sukses ${(skill.successRate * 100).toStringAsFixed(0)}%',
            ].join(' \u00b7 '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          if (skill.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                skill.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.simpulMuted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: skill.feedbackAllowed
                    ? 'Feedback \ud83d\udc4d untuk ${skill.slug}'
                    : 'Feedback hanya untuk skill trial/approved',
                onPressed: onFeedback == null
                    ? null
                    : (skill.feedbackAllowed
                        ? () => onFeedback!(skill.slug, true)
                        : null),
                icon: const Icon(Icons.thumb_up_outlined, size: 18),
              ),
              IconButton(
                tooltip: skill.feedbackAllowed
                    ? 'Feedback \ud83d\udc4e untuk ${skill.slug}'
                    : 'Feedback hanya untuk skill trial/approved',
                onPressed: onFeedback == null
                    ? null
                    : (skill.feedbackAllowed
                        ? () => onFeedback!(skill.slug, false)
                        : null),
                icon: const Icon(Icons.thumb_down_outlined, size: 18),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'Aksi lifecycle',
                onSelected: (action) =>
                    onLifecycleAction(context, action, skill),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                      value: 'evaluate',
                      child: Text('Evaluate (scan + golden)')),
                  if (skill.status != 'approved' && skill.status != 'retired')
                    const PopupMenuItem(
                        value: 'approve',
                        child: Text('Approve (promosikan)')),
                  if (skill.status == 'approved')
                    const PopupMenuItem(
                        value: 'rollback', child: Text('Rollback ke draft')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'approved' => context.simpulSuccess,
      'trial' => context.simpulInfo,
      'retired' => context.simpulMuted,
      _ => context.simpulWarn,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
