import 'package:flutter/material.dart';

import '../data/models.dart';
import 'theme.dart';

/// Multi-pane workspace (GUI-P2-03): pada layar lebar, chat ditampilkan
/// berdampingan dengan pane sesi (kiri) dan pane inspector (kanan) agar
/// multitasking tanpa berpindah halaman. Data tetap berasal dari API runtime
/// yang sama; layout ini murni preferensi tampilan.

class SessionsPane extends StatelessWidget {
  const SessionsPane({
    super.key,
    required this.sessions,
    required this.current,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onSelect,
  });

  final List<SessionSummary> sessions;
  final String current;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;
  final void Function(String id)? onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(right: BorderSide(color: context.simpulBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PaneHeader(
            title: 'Sessions',
            online: online,
            actions: [
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Muat ulang sesi',
                ),
            ],
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: context.simpulDanger),
              ),
            ),
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Text(
                      'Belum ada sesi.',
                      style: TextStyle(color: context.simpulMuted),
                    ),
                  )
                : Material(
                    color: Colors.transparent,
                    child: ListView(
                      children: [
                        for (final session in sessions)
                          ListTile(
                            dense: true,
                            selected: session.id == current,
                            leading: const Icon(
                              Icons.chat_bubble_outline,
                              size: 18,
                            ),
                            title: Text(
                              session.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${session.channel.isEmpty ? 'internal' : session.channel}'
                              ' \u00b7 ${session.turns} turn',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.simpulMuted,
                                fontSize: 11,
                              ),
                            ),
                            onTap: onSelect == null
                                ? null
                                : () => onSelect!(session.id),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class InspectorPane extends StatefulWidget {
  const InspectorPane({
    super.key,
    required this.runsSnapshot,
    required this.runsLoading,
    required this.runsError,
    required this.artifactsListing,
    required this.artifactsError,
    required this.online,
    this.onLoadRuns,
    this.onLoadArtifacts,
    this.onOpenArtifactFile,
    this.onClose,
  });

  final RunsSnapshot? runsSnapshot;
  final bool runsLoading;
  final String? runsError;
  final ArtifactsListing? artifactsListing;
  final String? artifactsError;
  final bool online;
  final VoidCallback? onLoadRuns;
  final VoidCallback? onLoadArtifacts;
  final void Function(String path)? onOpenArtifactFile;
  final VoidCallback? onClose;

  @override
  State<InspectorPane> createState() => _InspectorPaneState();
}

class _InspectorPaneState extends State<InspectorPane> {
  bool _showRuns = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(left: BorderSide(color: context.simpulBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PaneHeader(
            title: 'Inspector',
            online: widget.online,
            actions: [
              if (_showRuns && widget.onLoadRuns != null)
                IconButton(
                  onPressed: widget.onLoadRuns,
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Muat ulang runs',
                ),
              ToggleButtons(
                isSelected: [_showRuns, !_showRuns],
                onPressed: (index) {
                  final showRuns = index == 0;
                  if (showRuns == _showRuns) return;
                  setState(() => _showRuns = showRuns);
                  if (!showRuns) {
                    widget.onLoadArtifacts?.call();
                  } else {
                    widget.onLoadRuns?.call();
                  }
                },
                borderRadius: BorderRadius.circular(8),
                constraints: const BoxConstraints(minHeight: 30, minWidth: 30),
                textStyle: const TextStyle(fontSize: 11),
                children: const [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('Runs'),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('Files'),
                  ),
                ],
              ),
              if (widget.onClose != null)
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Tutup inspector',
                ),
            ],
          ),
          if (_showRuns)
            Expanded(child: _runsBody(context))
          else
            Expanded(child: _artifactsBody(context)),
        ],
      ),
    );
  }

  Widget _runsBody(BuildContext context) {
    final snap = widget.runsSnapshot;
    final children = <Widget>[
      if (widget.runsError != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            widget.runsError!,
            style: TextStyle(color: context.simpulDanger),
          ),
        ),
      if (widget.runsLoading) const LinearProgressIndicator(minHeight: 2),
    ];
    final entries = [
      ...?snap?.active.map((r) => MapEntry(r, true)),
      ...?snap?.recent.map((r) => MapEntry(r, false)),
    ];
    if (snap == null) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Belum ada snapshot \u2014 tekan muat ulang.',
            style: TextStyle(color: context.simpulMuted),
          ),
        ),
      );
    } else if (entries.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Belum ada run terekam.',
            style: TextStyle(color: context.simpulMuted),
          ),
        ),
      );
    } else {
      for (final entry in entries) {
        children.add(_RunTileCompact(run: entry.key, active: entry.value));
      }
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(children: children),
    );
  }

  Widget _artifactsBody(BuildContext context) {
    final listing = widget.artifactsListing;
    if (widget.artifactsError != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          widget.artifactsError!,
          style: TextStyle(color: context.simpulDanger),
        ),
      );
    }
    if (listing == null || listing.files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Belum ada file artifacts yang dimuat.',
          style: TextStyle(color: context.simpulMuted),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: ListView(
        children: [
          if (listing.truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                'Daftar terpotong \u2014 buka halaman Artifacts.',
                style: TextStyle(color: context.simpulMuted),
              ),
            ),
          for (final file in listing.files)
            ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(
                file.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${file.bytes} B \u00b7 ${file.modified}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.simpulMuted, fontSize: 11),
              ),
              onTap: widget.onOpenArtifactFile == null
                  ? null
                  : () => widget.onOpenArtifactFile!(file.path),
            ),
        ],
      ),
    );
  }
}

class _RunTileCompact extends StatelessWidget {
  const _RunTileCompact({required this.run, required this.active});
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: context.simpulBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    run.input.isEmpty ? '(tanpa input)' : run.input,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${run.session} \u00b7 ${run.steps.length} langkah'
              '${run.tokensUsed > 0 ? ' \u00b7 ${run.tokensUsed} token' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.simpulMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.title,
    required this.online,
    this.actions = const [],
  });
  final String title;
  final bool online;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.simpulBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
          Icon(
            online ? Icons.circle : Icons.circle_outlined,
            size: 10,
            color: online ? context.simpulSuccess : context.simpulMuted,
          ),
          for (final action in actions) ...[const SizedBox(width: 4), action],
        ],
      ),
    );
  }
}
