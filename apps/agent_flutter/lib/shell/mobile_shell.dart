import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../ui/theme.dart';

/// Narrow-layout shell (Android / narrow browser): three daily destinations
/// plus a "More" entry selecting [onSelect] with `null`.
/// Destinations come from the shared route map.
class MobileShell extends StatelessWidget {
  const MobileShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.child,
    this.pendingApprovals = 0,
    this.approvalStatusUnavailable = false,
    this.entries = kAppRoutes,
  });

  /// Currently selected primary route, or `null` when the More page is open.
  final AppRoute? selected;
  final ValueChanged<AppRoute?> onSelect;
  final Widget child;

  /// Jumlah approval pending (GUI-P0-06): badge pada More saat Approvals
  /// bukan destinasi primer. Saat status tidak tersedia, More menampilkan !.
  final int pendingApprovals;
  final bool approvalStatusUnavailable;

  /// Destinasi aktif — difilter per mode Simple/Advanced (GUI-P2-01).
  final List<AppRouteInfo> entries;

  @override
  Widget build(BuildContext context) {
    final primary = mobilePrimaryRoutes(entries);
    final moreIndex = primary.length;
    final currentIndex = selected == null
        ? moreIndex
        : primary.indexWhere((e) => e.route == selected!);
    return Column(
      children: [
        Expanded(child: child),
        NavigationBar(
          backgroundColor: context.simpulPanel,
          selectedIndex: currentIndex.clamp(0, moreIndex),
          onDestinationSelected: (i) {
            if (i >= primary.length) {
              onSelect(null);
            } else {
              onSelect(primary[i].route);
            }
          },
          destinations: [
            for (final entry in primary)
              NavigationDestination(
                icon: _navIcon(entry, pendingApprovals),
                label: entry.navigationLabel,
              ),
            NavigationDestination(
              icon: approvalStatusUnavailable
                  ? const Badge(
                      label: Text('!'),
                      child: Icon(Icons.more_horiz),
                    )
                  : pendingApprovals > 0
                  ? Badge(
                      label: Text('$pendingApprovals'),
                      child: const Icon(Icons.more_horiz),
                    )
                  : const Icon(Icons.more_horiz),
              label: kMobileMoreLabel,
            ),
          ],
        ),
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
