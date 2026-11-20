import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../ui/theme.dart';

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
    final selectedIndex = entries.indexWhere(
      (entry) => entry.route == selected,
    );
    // Perkiraan tinggi rail dengan label di bawah ikon; dipakai sebagai
    // tinggi intrinsik ketika tinggi jendela tidak memadai agar rail dapat
    // discroll, bukan overflow.
    final railHeight = 96.0 + entries.length * 88;
    final rail = NavigationRail(
      backgroundColor: Colors.transparent,
      selectedIndex: selectedIndex.clamp(0, entries.length - 1),
      onDestinationSelected: (i) => onSelect(entries[i].route),
      labelType: NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.simpulAccent,
                borderRadius: BorderRadius.circular(SimpulTheme.radius),
              ),
              child: const Icon(
                Icons.smart_toy_outlined,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tiko',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: context.simpulMuted,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
      destinations: [
        for (final entry in entries)
          NavigationRailDestination(
            icon: _navIcon(entry, pendingApprovals),
            label: Text(entry.label),
          ),
      ],
    );
    return Row(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight >= railHeight) return rail;
            return SingleChildScrollView(
              child: SizedBox(height: railHeight, child: rail),
            );
          },
        ),
        VerticalDivider(width: 1, color: context.simpulBorder),
        Expanded(child: child),
      ],
    );
  }

  static Widget _navIcon(AppRouteInfo entry, int pendingApprovals) {
    final icon = Icon(entry.icon);
    if (entry.route == AppRoute.approvals && pendingApprovals > 0) {
      return Badge(label: Text('$pendingApprovals'), child: icon);
    }
    return icon;
  }
}
