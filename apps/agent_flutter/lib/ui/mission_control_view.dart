import 'dart:async';

import 'package:flutter/material.dart';

import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Daftar state run/node yang dianggap aktif (boleh dibatalkan).
const _activeNodeStates = {'running', 'pending'};

String _statusLabel(String s) {
  switch (s) {
    case 'planning':
      return 'MERENCANAKAN';
    case 'running':
      return 'BERJALAN';
    case 'cancelling':
      return 'MEMBATALKAN';
    case 'cancelled':
      return 'DIBATALKAN';
    case 'finished':
      return 'SELESAI';
    case 'failed':
      return 'GAGAL';
    case 'ok':
      return 'OK';
    case 'pending':
      return 'ANTRI';
    default:
      return s.toUpperCase();
  }
}

Color _statusColor(BuildContext context, String s) {
  final scheme = Theme.of(context).colorScheme;
  switch (s) {
    case 'ok':
    case 'finished':
      return Colors.green.shade700;
    case 'failed':
      return scheme.error;
    case 'cancelled':
    case 'cancelling':
      return Colors.orange.shade700;
    case 'running':
      return scheme.primary;
    default:
      return scheme.outline;
  }
}

/// Mission Control (Hermes S16): dashboard live run orkestra bot tim.
/// Polling `GET /v1/teams/runs/live` + tombol Stop per-run
/// (`POST /v1/teams/runs/cancel` — kooperatif). Pemantauannesia polling
/// dimiliki pemanggil via [autoRefresh] supaya test deterministik.
class MissionControlView extends StatefulWidget {
  const MissionControlView({
    super.key,
    required this.online,
    this.runs,
    this.loading = false,
    this.error,
    this.onRefresh,
    this.onCancelRun,
    this.autoRefresh = true,
  });

  final bool online;

  /// Snapshot live run; null = belum dimuat.
  final List<Map<String, dynamic>>? runs;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;
  final Future<bool> Function(String runId)? onCancelRun;
  final bool autoRefresh;

  bool get _hasContent => runs != null && runs!.isNotEmpty;

  @override
  State<MissionControlView> createState() => _MissionControlViewState();
}

class _MissionControlViewState extends State<MissionControlView> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (widget.autoRefresh) {
      _poll = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted) widget.onRefresh?.call();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _cancel(String runId) async {
    final ok = await widget.onCancelRun?.call(runId) ?? false;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Sinyal stop dikirim ke run $runId'
            : 'Run $runId tidak ditemukan atau sudah selesai'),
      ),
    );
    unawaited(widget.onRefresh?.call());
  }

  @override
  Widget build(BuildContext context) {
    final runs = widget.runs;
    final active = runs?.where(_isActiveRun).length ?? 0;
    final title = active > 0 ? '$active run aktif' : 'Tidak ada run aktif';
    return Column(
      children: [
        PageHeader(
          title: 'Mission Control',
          subtitle: title,
          online: widget.online,
          trailing: widget.onRefresh == null
              ? null
              : IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
        ),
        if (widget.loading) StatusViews.loadingBanner(context),
        if (widget.error != null) StatusViews.errorBanner(context, widget.error!),
        Expanded(
          child: !widget._hasContent
              ? StatusViews.empty(
                  context,
                  message: widget.runs == null
                      ? 'Belum ada snapshot \u2014 tekan refresh. Jalankan tim dari halaman Bots atau CLI `tiko team run`.'
                      : 'Belum ada run tim aktif/terekam.',
                )
              : RefreshIndicator(
                  onRefresh: () async => await widget.onRefresh?.call(),
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      for (final run in runs!)
                        _RunCard(
                          run: run,
                          onCancel: _cancel,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  static bool _isActiveRun(Map<String, dynamic> run) {
    final status = run['status'] as String? ?? '';
    if (status == 'running' || status == 'cancelling' || status == 'planning') {
      return true;
    }
    final nodes = run['nodes'] as List<dynamic>? ?? const [];
    return nodes.any((n) =>
        n is Map && _activeNodeStates.contains(n['status'] as String? ?? ''));
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, required this.onCancel});

  final Map<String, dynamic> run;
  final Future<void> Function(String runId) onCancel;

  bool get _runActive {
    final status = run['status'] as String? ?? '';
    return status == 'running' || status == 'cancelling' || status == 'planning';
  }

  @override
  Widget build(BuildContext context) {
    final runId = run['run_id'] as String? ?? '?';
    final status = run['status'] as String? ?? '';
    final nodes = (run['nodes'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((n) => Map<String, dynamic>.from(n))
        .toList();
    final doneCount = nodes
        .where((n) => n['status'] == 'ok' || n['status'] == 'failed')
        .length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        run['goal'] as String? ?? '(tanpa tujuan)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'run_id $runId \u00b7 tim ${run['team_id'] ?? 'adhoc'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(status: status),
              ],
            ),
            if (nodes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Progress: $doneCount/${nodes.length} node selesai',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              for (final node in nodes) _NodeTile(node: node),
            ],
            if (_runActive) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: 'Stop (kooperatif)',
                  child: OutlinedButton.icon(
                    onPressed: status == 'cancelling'
                        ? null
                        : () => onCancel(runId),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _statusColor(context, status).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == 'running' || status == 'planning') ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: _statusColor(context, status),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            _statusLabel(status),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: _statusColor(context, status),
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node});

  final Map<String, dynamic> node;

  String _duration() {
    final started = DateTime.tryParse(
        node['started_at'] as String? ?? '');
    final finished = DateTime.tryParse(
        node['finished_at'] as String? ?? '');
    if (started == null || finished == null) return '';
    final ms = finished.difference(started).inMilliseconds;
    return ms >= 1000 ? ' ${(ms / 1000).toStringAsFixed(1)}s' : ' ${ms}ms';
  }

  @override
  Widget build(BuildContext context) {
    final status = node['status'] as String? ?? 'pending';
    final outputTail = node['output_tail'] as String?;
    final error = node['error'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (status) {
              'ok' => Icons.check_circle,
              'failed' => Icons.cancel,
              'running' => Icons.autorenew,
              'cancelled' => Icons.stop_circle_outlined,
              _ => Icons.radio_button_unchecked,
            },
            size: 16,
            color: _statusColor(context, status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${node['id']} \u00b7 ${node['agent'] is String && (node['agent'] as String).isNotEmpty ? node['agent'] : 'tanpa agent'}'
                  '${_duration()}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (error != null && error.isNotEmpty)
                  Text(
                    error,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                if (outputTail != null && outputTail.isNotEmpty)
                  Text(
                    outputTail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
