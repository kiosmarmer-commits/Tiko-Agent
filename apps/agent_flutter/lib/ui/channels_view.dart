
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Channels setup (GUI-P1-07): status channel gateway aktif + nama variabel
/// env yang mengonfigurasinya — read-only, parity `doctor`/startup log.
/// Perubahan setup dilakukan via env daemon + restart (config immutable
/// runtime); GUI hanya membantu melihat channel mana yang hidup dan env
/// apa yang mengaturnya (tanpa nilai rahasia).
class ChannelsPage extends StatelessWidget {
  const ChannelsPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
  });

  final ChannelsSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    final activeCount = snapshot?.channels.where((c) => c.active).length ?? 0;
    return Column(
      children: [
        PageHeader(
          title: 'Channels',
          subtitle: snapshot == null
              ? 'Status channel gateway'
              : '${snapshot.channels.length} channel \u00b7 $activeCount aktif '
                  '\u00b7 setup via env + restart',
          online: online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onRefresh != null)
                IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: onRefresh, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        if (loading) StatusViews.loadingBanner(context),
        if (error != null)
            StatusViews.errorBanner(context, error!, onRetry: onRefresh),
        Expanded(
          child: snapshot == null
              ? StatusViews.empty(context, message: 'Belum ada data channel.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    _SectionCard(
                      title: 'Setup',
                      child: Text(
                        'Channel dikonfigurasi lewat variabel environment '
                        'saat daemon start (telegram/discord/email/whatsapp/'
                        'slack/signal/matrix/openai). GUI bersifat read-only: '
                        'ubah env lalu restart daemon untuk menerapkan.',
                        style: TextStyle(
                            color: context.simpulMuted, fontSize: 12),
                      ),
                    ),
                    ...snapshot.channels.map((c) => _ChannelCard(channel: c)),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel});

  final ChannelInfo channel;

  @override
  Widget build(BuildContext context) {
    final color = channel.active
        ? context.simpulSuccess
        : context.simpulMuted;
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
              Icon(_iconFor(channel.channel), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.channel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(channel.active ? 'aktif' : 'nonaktif',
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (channel.env.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in channel.env)
                  Text('env $e',
                      style: TextStyle(
                          color: context.simpulMuted, fontSize: 11)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(String channel) => switch (channel) {
        'telegram' => Icons.send_outlined,
        'discord' => Icons.forum_outlined,
        'email' || 'imap' => Icons.alternate_email,
        'whatsapp' => Icons.chat_outlined,
        'slack' => Icons.workspaces_outlined,
        'signal' => Icons.wifi_tethering_outlined,
        'matrix' => Icons.grid_view_outlined,
        'openai' => Icons.api_outlined,
        'http' => Icons.public_outlined,
        _ => Icons.more_horiz,
      };
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
