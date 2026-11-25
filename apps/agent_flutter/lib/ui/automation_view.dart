
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Automation / Cron CRUD (GUI-P1-09): kelola cron job scheduler durabel
/// via REST `GET/POST /v1/jobs`, `PATCH/DELETE /v1/jobs/:id`,
/// `POST /v1/jobs/:id/run`. Job disimpan di `jobs.json` oleh daemon dan
/// dieksekusi scheduler internal (tick ~20s) — konsisten dengan tool
/// `schedule_job`/`cancel_job`.
class AutomationPage extends StatefulWidget {
  const AutomationPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
    this.onCreate,
    this.onUpdate,
    this.onDelete,
    this.onRunNow,
  });

  final JobsSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;

  /// Body create: cron + prompt (wajib), channel/user_key/missed_policy/
  /// timezone (opsional). Melempar ApiError bila ditolak daemon (400).
  final Future<void> Function(Map<String, dynamic> body)? onCreate;

  /// PATCH parsial (enabled/prompt/cron/...); mengembalikan job terbaru.
  final Future<void> Function(String id, Map<String, dynamic> body)? onUpdate;

  /// false bila id asing.
  final Future<bool> Function(String id)? onDelete;

  /// null bila id asing atau job sedang delivery-pending.
  final Future<JobInfo?> Function(String id)? onRunNow;

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  String? _busyId;

  Future<void> _runAction(Future<void> Function() action, String failureLabel) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$failureLabel: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final activeCount = snapshot?.jobs.where((j) => j.enabled).length ?? 0;
    return Column(
      children: [
        PageHeader(
          title: 'Automation',
          subtitle: snapshot == null
              ? 'Cron job scheduler daemon'
              : '${snapshot.jobs.length} job \u00b7 $activeCount aktif \u00b7 '
                  'disimpan durabel di jobs.json',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onCreate != null && widget.online)
                IconButton(
                  tooltip: 'Buat job baru',
                  onPressed: () => _showCreateDialog(context),
                  icon: const Icon(Icons.add),
                ),
              if (widget.onRefresh != null)
                IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: widget.onRefresh, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        if (widget.surfaceSection != null) widget.surfaceSection!,
        if (widget.loading) StatusViews.loadingBanner(context),
        if (widget.error != null)
            StatusViews.errorBanner(context, widget.error!),
        Expanded(
          child: snapshot == null
              ? StatusViews.empty(context, message: 'Belum ada data job.')
              : snapshot.jobs.isEmpty
                  ? ListView(
                      children: [
                        _GuideCard(
                          child: Text(
                            'Belum ada job terjadwal. Buat cron (mis. 0 9 * * *) '
                            'dan prompt; daemon menjalankan prompt pada jadwal '
                            'persetujuan lewat kredensial siapa pun. Klik ikon + '
                            'untuk membuat job pertama.',
                            style: TextStyle(
                                color: context.simpulMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        _GuideCard(
                          child: Text(
                            'Job adalah prompt terjadwal yang berjalan pada '
                            'scheduler daemon (tick \u2248 20 detik). missed_policy '
                            'menentukan perilaku saat daemon mati: skip tidak '
                            'mengirim ulang, run_once menjalankan sekali setelah '
                            'hidup, catch_up mengejar semua jadwal terlewat.',
                            style: TextStyle(
                                color: context.simpulMuted, fontSize: 12),
                          ),
                        ),
                        ...snapshot.jobs.map(
                          (j) => _JobCard(
                            job: j,
                            busy: _busyId == j.id,
                            onToggle: widget.onUpdate == null
                                ? null
                                : (enabled) => _runAction(
                                      () async {
                                        setState(() => _busyId = j.id);
                                        await widget.onUpdate!(
                                            j.id, {'enabled': enabled});
                                        await widget.onRefresh?.call();
                                      },
                                      'Gagal mengubah job',
                                    ),
                            onDelete: widget.onDelete == null
                                ? null
                                : () => _confirmDelete(context, j),
                            onRunNow: widget.onRunNow == null
                                ? null
                                : () => _runAction(
                                      () async {
                                        setState(() => _busyId = j.id);
                                        final result = await widget.onRunNow!(j.id);
                                        if (result == null) {
                                          throw StateError(
                                              'job tidak ditemukan atau sedang '
                                              'delivery-pending');
                                        }
                                        await widget.onRefresh?.call();
                                      },
                                      'Gagal memicu job',
                                    ),
                          ),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final cronController = TextEditingController();
    final promptController = TextEditingController();
    final channelController = TextEditingController(text: 'http');
    final timezoneController = TextEditingController(text: 'UTC');
    final formKey = GlobalKey<FormState>();
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Buat cron job'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: cronController,
                  decoration: const InputDecoration(
                    labelText: 'Cron (5 field)',
                    hintText: '*/5 * * * *',
                  ),
                  validator: (value) =>
                      value == null || value.trim().length < 9
                          ? 'wajib ekspresi cron 5 field'
                          : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: promptController,
                  maxLines: 3,
                  maxLength: 10000,
                  decoration: const InputDecoration(
                    labelText: 'Prompt',
                    hintText: 'Ringkas berita teknologi hari ini',
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'prompt wajib diisi'
                          : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: channelController,
                  decoration: const InputDecoration(
                    labelText: 'Channel (default http)',
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'channel wajib diisi'
                          : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: timezoneController,
                  decoration: const InputDecoration(
                    labelText: 'Timezone IANA (default UTC)',
                    hintText: 'Asia/Jakarta',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.of(context, rootNavigator: true).pop({
                'cron': cronController.text.trim(),
                'prompt': promptController.text.trim(),
                'channel': channelController.text.trim(),
                'timezone': timezoneController.text.trim().isEmpty
                    ? 'UTC'
                    : timezoneController.text.trim(),
              });
            },
            child: const Text('Buat'),
          ),
        ],
      ),
    );
    if (created == null || widget.onCreate == null) return;
    await _runAction(
      () async {
        await widget.onCreate!(created);
        await widget.onRefresh?.call();
      },
      'Gagal membuat job',
    );
  }

  Future<void> _confirmDelete(BuildContext context, JobInfo job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus job?'),
        content: Text('Job "${job.id}" beserta jadwalnya dihapus permanen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true || widget.onDelete == null) return;
    await _runAction(
      () async {
        final ok = await widget.onDelete!(job.id);
        if (!ok) throw StateError('job tidak ditemukan');
        await widget.onRefresh?.call();
      },
      'Gagal menghapus job',
    );
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({required this.child});

  final Widget child;

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
      child: child,
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    this.busy = false,
    this.onToggle,
    this.onDelete,
    this.onRunNow,
  });

  final JobInfo job;
  final bool busy;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onDelete;
  final VoidCallback? onRunNow;

  String _formatTime(String iso) {
    final parsed = DateTime.tryParse(iso)?.toUtc();
    if (parsed == null) return iso.isEmpty ? '-' : iso;
    final duration = parsed.difference(DateTime.now().toUtc());
    if (duration.inSeconds < 0) {
      final ago = -duration;
      return 'terlewat ${_formatDuration(ago)} lalu';
    }
    return 'dalam ${_formatDuration(duration)}';
  }

  String _formatDuration(Duration duration) {
    if (duration.inDays > 0) return '${duration.inDays}h';
    if (duration.inHours > 0) return '${duration.inHours}j ${duration.inMinutes % 60}m';
    if (duration.inMinutes > 0) return '${duration.inMinutes}m';
    return '${duration.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final enabledColor =
        job.enabled ? context.simpulSuccess : context.simpulMuted;
    final deliveryColor = switch (job.deliveryState) {
      'delivered' => context.simpulSuccess,
      'pending' => context.simpulWarn,
      'failed' => context.simpulDanger,
      _ => context.simpulMuted,
    };
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
          Row(
            children: [
              const Icon(Icons.schedule_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.prompt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              if (onToggle != null)
                Switch(
                  value: job.enabled,
                  onChanged: busy ? null : onToggle,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'cron ${job.cron} \u00b7 ${job.timezone} \u00b7 missed ${job.missedPolicy}',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'channel ${job.channel} \u00b7 user ${job.userKey}',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'next ${_formatTime(job.nextRun)}'
            '${job.lastRun == null ? '' : ' \u00b7 terakhir ${_formatTime(job.lastRun!)}'}',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: enabledColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(job.enabled ? 'ON' : 'OFF',
                    style: TextStyle(
                        color: enabledColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: deliveryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('delivery ${job.deliveryState}',
                    style: TextStyle(
                        color: deliveryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (onRunNow != null)
                TextButton.icon(
                  onPressed: busy ? null : onRunNow,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Run now'),
                ),
              const Spacer(),
              if (onDelete != null)
                TextButton.icon(
                  onPressed: busy ? null : onDelete,
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: context.simpulDanger),
                  label: Text('Hapus',
                      style: TextStyle(color: context.simpulDanger)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
