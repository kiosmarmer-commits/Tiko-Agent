import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../ui/theme.dart';

/// Narrow-layout shell (Android / narrow browser): bottom navigation bar with
/// the primary routes plus a "More" entry selecting [onSelect] with `null`.
/// Destinations come from the shared route map.
class MobileShell extends StatelessWidget {
  const MobileShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.child,
  });

  /// Currently selected primary route, or `null` when the More page is open.
  final AppRoute? selected;
  final ValueChanged<AppRoute?> onSelect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = kMobilePrimaryRoutes;
    final moreIndex = primary.length;
    final currentIndex =
        selected == null ? moreIndex : primary.indexWhere((e) => e.route == selected!);
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
                icon: Icon(entry.icon),
                label: entry.label,
              ),
            const NavigationDestination(
              icon: Icon(Icons.more_horiz),
              label: kMobileMoreLabel,
            ),
          ],
        ),
      ],
    );
  }
}
