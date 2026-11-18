import 'package:flutter/material.dart';

/// Single route map (GUI-P0-01): desktop rail, mobile bottom bar and the
/// mobile More page all derive their destinations from [kAppRoutes] so labels
/// and structure cannot drift between Android, desktop and web.
enum AppRoute { chat, dashboard, approvals, sessions, tasks, skills, bots, providers, plugins, channels, automations, security, memory, events, logs, settings }

class AppRouteInfo {
  const AppRouteInfo(
    this.route,
    this.label,
    this.icon, {
    this.primaryOnMobile = true,
  });

  final AppRoute route;
  final String label;
  final IconData icon;

  /// Primary routes appear in the mobile bottom navigation bar; the rest are
  /// grouped under the mobile "More" entry.
  final bool primaryOnMobile;
}

const List<AppRouteInfo> kAppRoutes = [
  AppRouteInfo(AppRoute.chat, 'Chat', Icons.chat_bubble_outline),
  AppRouteInfo(AppRoute.dashboard, 'Dashboard', Icons.dashboard_outlined),
  AppRouteInfo(AppRoute.approvals, 'Approvals', Icons.verified_user_outlined),
  AppRouteInfo(AppRoute.sessions, 'Sessions', Icons.forum_outlined),
  AppRouteInfo(
    AppRoute.tasks,
    'Tasks',
    Icons.view_kanban_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.skills,
    'Skills',
    Icons.auto_awesome_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.bots,
    'Bots',
    Icons.smart_toy_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.providers,
    'Providers',
    Icons.route_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.plugins,
    'Plugins',
    Icons.extension_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.channels,
    'Channels',
    Icons.hub_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.automations,
    'Automation',
    Icons.schedule_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.security,
    'Security',
    Icons.security_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.memory,
    'Memory',
    Icons.memory_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.events,
    'Events',
    Icons.bolt_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.logs,
    'Logs',
    Icons.article_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.settings,
    'Settings',
    Icons.settings_outlined,
    primaryOnMobile: false,
  ),
];

const String kMobileMoreLabel = 'More';

extension AppRoutePresentation on AppRoute {
  AppRouteInfo get info =>
      kAppRoutes.firstWhere((entry) => entry.route == this);

  String get label => info.label;
  IconData get icon => info.icon;
  bool get primaryOnMobile => info.primaryOnMobile;
}

/// Primary destinations in mobile bottom-bar order, followed by the More
/// entry that groups the remaining routes.
List<AppRouteInfo> get kMobilePrimaryRoutes =>
    kAppRoutes.where((entry) => entry.primaryOnMobile).toList();
