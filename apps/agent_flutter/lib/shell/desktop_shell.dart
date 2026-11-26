import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../ui/theme.dart';
import '../ui/tiko_mark.dart';

/// Wide-layout shell (desktop / wide browser): flat navigation rail on the
/// left, workspace content on the right. Destinations come from the shared
/// route map so every platform shows the same navigation domain.
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.child,
    this.pendingApprovals = 0,
    this.entries = kAppRoutes,
  });

  final AppRoute selected;
  final ValueChanged<AppRoute> onSelect;
  final Widget child;

  /// Destinasi aktif - difilter per mode Simple/Advanced (GUI-P2-01).
  final List<AppRouteInfo> entries;

  /// Jumlah approval pending (GUI-P0-06): ditampilkan sebagai badge pada
  /// destinasi Approvals agar state lintas client terlihat di nav.
  final int pendingApprovals;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 248,
          child: _Sidebar(
            entries: entries,
            selected: selected,
            pendingApprovals: pendingApprovals,
            onSelect: onSelect,
          ),
        ),
        VerticalDivider(width: 1, color: context.simpulBorder),
        Expanded(child: child),
      ],
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.entries,
    required this.selected,
    required this.pendingApprovals,
    required this.onSelect,
  });

  final List<AppRouteInfo> entries;
  final AppRoute selected;
  final int pendingApprovals;
  final ValueChanged<AppRoute> onSelect;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool toolsExpanded = true;

  @override
  void didUpdateWidget(covariant _Sidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected &&
        widget.entries.any((entry) => entry.route == widget.selected) &&
        !const {'Workspace', 'Agents'}.contains(
          widget.entries
              .firstWhere((entry) => entry.route == widget.selected)
              .section,
        )) {
      toolsExpanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    const primarySections = {'Workspace', 'Agents'};
    final primary = widget.entries
        .where((entry) => primarySections.contains(entry.section))
        .toList();
    final tools = widget.entries
        .where((entry) => !primarySections.contains(entry.section))
        .toList();
    return Material(
      color: context.simpulPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.simpulAccent,
                    borderRadius: BorderRadius.circular(SimpulTheme.radius),
                  ),
                  child: const Center(child: TikoMark(size: 23)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tiko Agent',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        'Agent workspace',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.simpulMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(
                    context,
                    'Workspace',
                    primary,
                    filter: (e) => e.section == 'Workspace',
                  ),
                  _section(
                    context,
                    'Agents',
                    primary,
                    filter: (e) => e.section == 'Agents',
                  ),
                  const Divider(height: 24),
                  if (toolsExpanded) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                      child: Text(
                        'Explore',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: context.simpulMuted,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    _section(
                      context,
                      'Knowledge',
                      tools,
                      filter: (e) => e.section == 'Knowledge',
                    ),
                    _section(
                      context,
                      'Connections',
                      tools,
                      filter: (e) => e.section == 'Connections',
                    ),
                    _section(
                      context,
                      'Control',
                      tools,
                      filter: (e) => e.section == 'Control',
                    ),
                    _section(
                      context,
                      'Settings',
                      tools,
                      filter: (e) => e.section == 'Settings',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<AppRouteInfo> all, {
    required bool Function(AppRouteInfo) filter,
  }) {
    final entries = all.where(filter).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: context.simpulMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        for (final entry in entries)
          ListTile(
            dense: true,
            selected: entry.route == widget.selected,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
            ),
            leading: _icon(entry),
            title: Text(entry.navigationLabel),
            onTap: () => widget.onSelect(entry.route),
          ),
      ],
    );
  }

  Widget _icon(AppRouteInfo entry) {
    final icon = Icon(entry.icon, size: 19);
    if (entry.route == AppRoute.approvals && widget.pendingApprovals > 0) {
      return Badge(label: Text('${widget.pendingApprovals}'), child: icon);
    }
    return icon;
  }
}
