import 'package:flutter/material.dart';

/// Single route map (GUI-P0-01): desktop rail, mobile bottom bar and the
/// mobile More page all derive their destinations from [kAppRoutes] so labels
/// and structure cannot drift between Android, desktop and web.
enum AppRoute {
  chat,
  dashboard,
  approvals,
  surfaces,
  sessions,
  tasks,
  skills,
  bots,
  providers,
  plugins,
  channels,
  automations,
  security,
  audit,
  artifacts,
  runs,
  memory,
  events,
  logs,
  settings,
}

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
  AppRouteInfo(
    AppRoute.surfaces,
    'Surface',
    Icons.web_asset_outlined,
    primaryOnMobile: false,
  ),
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
    AppRoute.audit,
    'Audit',
    Icons.receipt_long_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.artifacts,
    'Artifacts',
    Icons.folder_copy_outlined,
    primaryOnMobile: false,
  ),
  AppRouteInfo(
    AppRoute.runs,
    'Runs',
    Icons.play_circle_outline,
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

/// GUI-P2-01: Simple mode keeps the everyday control center (chat, satu
/// halaman status, approval, sesi, tasks, memory, settings); modul teknis
/// (skills, bots, providers, tools/MCP/plugins, channels, automation,
/// security, audit, artifacts, runs, events, logs, graf/editor) hanya
/// muncul pada Advanced mode. Kemampuan runtime tidak berubah — ini murni
/// progressive disclosure di layer navigasi.
const Set<AppRoute> kSimpleRoutes = {
  AppRoute.chat,
  AppRoute.dashboard,
  AppRoute.approvals,
  AppRoute.sessions,
  AppRoute.tasks,
  AppRoute.memory,
  AppRoute.settings,
};

/// Route map yang terlihat sesuai mode: [advanced] = false hanya
/// menyisakan [kSimpleRoutes] dalam urutan [kAppRoutes].
List<AppRouteInfo> visibleRoutes({required bool advanced}) => advanced
    ? kAppRoutes
    : kAppRoutes.where((entry) => kSimpleRoutes.contains(entry.route)).toList();

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

/// Variant yang menghormati mode Simple/Advanced (GUI-P2-01) — shell mobile
/// memakai ini agar bottom bar selalu konsisten dengan daftar route aktif.
List<AppRouteInfo> mobilePrimaryRoutes(List<AppRouteInfo> entries) =>
    entries.where((entry) => entry.primaryOnMobile).toList();
