import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../ui/theme.dart';

/// Wide-layout shell (desktop / wide browser): navigation rail on the left,
/// workspace content on the right. Destinations come from the shared route
/// map so every platform shows the same navigation domain.
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.child,
    this.pendingApprovals = 0,
  });

  final AppRoute selected;
  final ValueChanged<AppRoute> onSelect;
  final Widget child;

  /// Jumlah approval pending (GUI-P0-06): ditampilkan sebagai badge pada
  /// destinasi Approvals agar state lintas client terlihat di nav.
  final int pendingApprovals;

  @override
  Widget build(BuildContext context) {
    final selectedIndex =
        kAppRoutes.indexWhere((entry) => entry.route == selected);
    return Row(
      children: [
        NavigationRail(
          backgroundColor: context.simpulPanel,
          selectedIndex: selectedIndex.clamp(0, kAppRoutes.length - 1),
          onDestinationSelected: (i) => onSelect(kAppRoutes[i].route),
          labelType: NavigationRailLabelType.all,
          destinations: [
            for (final entry in kAppRoutes)
              NavigationRailDestination(
                icon: _navIcon(entry, pendingApprovals),
                label: Text(entry.label),
              ),
          ],
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
