
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Plugin & Tools Manager (GUI-P1-06): status plugin + capability consent
/// (grant/revoke paritas `/plugin consent`), katalog tool registry host
/// (read-only), dan status server MCP — lewat REST `GET /v1/plugins` +
/// `POST /v1/plugins/consent`.
class PluginManagerPage extends StatefulWidget {
  const PluginManagerPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onConsent,
  });

  final PluginsToolsSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// [plugin] + [action] (`grant`/`revoke`); mengembalikan pesan server atau
  /// melempar error bila gagal.
  final Future<String> Function(String plugin, String action)? onConsent;

  @override
  State<PluginManagerPage> createState() => _PluginManagerPageState();
}

class _PluginManagerPageState extends State<PluginManagerPage> {
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final pendingCount =
        snapshot?.plugins.where((p) => p.pending).length ?? 0;
    return Column(
      children: [
        PageHeader(
          title: 'Plugins',
          subtitle: snapshot == null
              ? 'Plugin, tools, MCP'
              : '${snapshot.plugins.length} plugin ($pendingCount menunggu consent) '
                  '\u00b7 ${snapshot.tools.length} tools \u00b7 '
                  '${snapshot.mcp?.configured.length ?? 0} server MCP',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onRefresh != null)
                IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
        if (widget.loading) StatusViews.loadingBanner(context),
        if (widget.error != null)
            StatusViews.errorBanner(context, widget.error!),
        Expanded(
          child: snapshot == null
              ? StatusViews.empty(context, message: 'Belum ada data plugin.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    ...snapshot.plugins.map(
                        (p) => _PluginCard(plugin: p, onConsent: widget.onConsent)),
                    _SectionCard(
                      title: 'Tools terdaftar (${snapshot.tools.length})',
                      child: snapshot.tools.isEmpty
                          ? Text(
                              'Registry host kosong.',
                              style: TextStyle(
                                  color: context.simpulMuted, fontSize: 12),
                            )
                          : Column(
                              children: [
                                for (final t in snapshot.tools)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(t.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500)),
                                        ),
                                        _RiskBadge(risk: t.risk),
                                      ],
                                    ),
                                    subtitle: Text(
                                      t.description.isEmpty
                                          ? 'timeout ${t.timeoutSec}s'
                                          : '${t.description} \u00b7 timeout ${t.timeoutSec}s',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: context.simpulMuted,
                                          fontSize: 11),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    _SectionCard(
                      title: 'Server MCP (${snapshot.mcp?.configured.length ?? 0})',
                      child: (snapshot.mcp?.configured.isEmpty ?? true)
                          ? Text(
                              'Tidak ada server MCP dikonfigurasi.',
                              style: TextStyle(
                                  color: context.simpulMuted, fontSize: 12),
                            )
                          : Column(
                              children: [
                                for (final server in snapshot.mcp!.configured)
                                  _McpTile(server: server, mcp: snapshot.mcp!),
                              ],
                            ),
                    ),
                    if (snapshot.events.isNotEmpty)
                      _SectionCard(
                        title: 'Event plugin terakhir',
                        child: Column(
                          children: [
                            for (final e in snapshot.events)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  '${e.plugin} \u00b7 ${e.hook}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: e.error != null
                                    ? Text(e.error!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: context.simpulDanger,
                                            fontSize: 11))
                                    : (e.detail == null
                                        ? null
                                        : Text(e.detail!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: context.simpulMuted,
                                                fontSize: 11))),
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

class _PluginCard extends StatelessWidget {
  const _PluginCard({required this.plugin, this.onConsent});

  final PluginItem plugin;
  final Future<String> Function(String plugin, String action)? onConsent;

  Future<void> _submit(BuildContext context, String action) async {
    final callback = onConsent;
    if (callback == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    try {
      final message = await callback(plugin.id, action);
      messenger.showSnackBar(SnackBar(
        backgroundColor: okColor,
        content: Text(message),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal consent $action untuk ${plugin.id}: $e'),
      ));
    }
  }

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
          Row(
            children: [
              const Icon(Icons.extension_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plugin.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              _StatusBadge(plugin: plugin),
            ],
          ),
          if (plugin.granted.isNotEmpty || plugin.requested.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final p in plugin.granted)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.simpulSuccess.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('ok\u00b7$p',
                        style: TextStyle(
                            color: context.simpulSuccess, fontSize: 11)),
                  ),
                for (final p in plugin.requested.where((p) =>
                    !plugin.granted.contains(p)))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.simpulWarn.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('diminta\u00b7$p',
                        style: TextStyle(
                            color: context.simpulWarn, fontSize: 11)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              if (onConsent != null) ...[
                if (plugin.pending)
                  FilledButton(
                    onPressed: () => _submit(context, 'grant'),
                    child: const Text('Setujui'),
                  )
                else
                  TextButton(
                    onPressed: () => _submit(context, 'revoke'),
                    child: const Text('Cabut consent'),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.plugin});

  final PluginItem plugin;

  @override
  Widget build(BuildContext context) {
    final (label, color) = plugin.pending
        ? ('menunggu consent', context.simpulWarn)
        : (plugin.registered ? 'terdaftar' : 'tidak aktif',
            plugin.registered ? context.simpulSuccess : context.simpulMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.risk});

  final String risk;

  @override
  Widget build(BuildContext context) {
    final color = switch (risk) {
      'low' => context.simpulSuccess,
      'medium' => context.simpulWarn,
      _ => context.simpulDanger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(risk,
          style: TextStyle(color: color, fontSize: 10)),
    );
  }
}

class _McpTile extends StatelessWidget {
  const _McpTile({required this.server, required this.mcp});

  final McpServerInfo server;
  final McpStatusInfo mcp;

  @override
  Widget build(BuildContext context) {
    final status = mcp.loader
        .where((s) => '${s['id']}' == server.id)
        .toList()
        .firstOrNull;
    final statusLabel = '${status?['status'] ?? (server.enabled ? 'unknown' : 'disabled')}';
    final statusColor = switch (statusLabel) {
      'ready' => context.simpulSuccess,
      'failed' || 'invalid' => context.simpulDanger,
      'disabled' || 'empty' => context.simpulMuted,
      _ => context.simpulWarn,
    };
    final detail = '${status?['detail'] ?? ''}';
    final tools = status?['tools'];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${server.id} (${server.type})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(statusLabel,
                style: TextStyle(color: statusColor, fontSize: 10)),
          ),
        ],
      ),
      subtitle: Text(
        [
          'risk ${server.risk}',
          if (tools is num) 'tools ${tools.toInt()}',
          if (detail.isNotEmpty) detail,
          if (server.allow.isNotEmpty) 'allow ${server.allow.join(",")}',
        ].join(' \u00b7 '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.simpulMuted, fontSize: 11),
      ),
    );
  }
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
