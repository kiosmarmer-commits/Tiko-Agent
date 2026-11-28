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
  smartHome,
  automations,
  security,
  audit,
  artifacts,
  runs,
  mission,
  memory,
  events,
  logs,
  hooks,
  settings,
}

class AppRouteInfo {
  const AppRouteInfo(
    this.route,
    this.label,
    this.icon, {
    this.primaryOnMobile = true,
    this.section = 'Workspace',
    this.shortLabel,
  });

  final AppRoute route;
  final String label;
  final IconData icon;

  /// Primary routes appear in the mobile bottom navigation bar; the rest are
  /// grouped under the mobile "More" entry.
  final bool primaryOnMobile;

  /// Presentation group used by the compact desktop sidebar. This does not
  /// change route identity or runtime behaviour.
  final String section;

  /// Short label for narrow navigation surfaces. The full [label] remains
  /// available in page headers, menus and accessibility labels.
  final String? shortLabel;

  String get navigationLabel => shortLabel ?? label;
}

const List<AppRouteInfo> kAppRoutes = [
  AppRouteInfo(
    AppRoute.chat,
    'Chat',
    Icons.chat_bubble_outline,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.dashboard,
    'Workspace',
    Icons.dashboard_outlined,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.approvals,
    'Approvals',
    Icons.verified_user_outlined,
    primaryOnMobile: false,
    section: 'Agents',
  ),
  AppRouteInfo(
    AppRoute.surfaces,
    'Interactive UI',
    Icons.web_asset_outlined,
    primaryOnMobile: false,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.sessions,
    'Chat history',
    Icons.forum_outlined,
    primaryOnMobile: false,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.tasks,
    'Tasks',
    Icons.view_kanban_outlined,
    primaryOnMobile: false,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.skills,
    'Skills',
    Icons.auto_awesome_outlined,
    primaryOnMobile: false,
    section: 'Knowledge',
  ),
  AppRouteInfo(
    AppRoute.bots,
    'Bots',
    Icons.smart_toy_outlined,
    primaryOnMobile: false,
    section: 'Agents',
  ),
  AppRouteInfo(
    AppRoute.providers,
    'Models & providers',
    Icons.route_outlined,
    primaryOnMobile: false,
    section: 'Connections',
  ),
  AppRouteInfo(
    AppRoute.plugins,
    'Extensions',
    Icons.extension_outlined,
    primaryOnMobile: false,
    section: 'Connections',
  ),
  AppRouteInfo(
    AppRoute.channels,
    'Messaging channels',
    Icons.hub_outlined,
    primaryOnMobile: false,
    section: 'Connections',
  ),
  AppRouteInfo(
    AppRoute.smartHome,
    'Smart home',
    Icons.home_outlined,
    primaryOnMobile: false,
    section: 'Connections',
  ),
  AppRouteInfo(
    AppRoute.automations,
    'Automations',
    Icons.schedule_outlined,
    primaryOnMobile: false,
    section: 'Agents',
  ),
  AppRouteInfo(
    AppRoute.security,
    'Security',
    Icons.security_outlined,
    primaryOnMobile: false,
    section: 'Control',
  ),
  AppRouteInfo(
    AppRoute.audit,
    'Security activity',
    Icons.receipt_long_outlined,
    primaryOnMobile: false,
    section: 'Control',
  ),
  AppRouteInfo(
    AppRoute.artifacts,
    'Files & outputs',
    Icons.folder_copy_outlined,
    primaryOnMobile: false,
    section: 'Workspace',
  ),
  AppRouteInfo(
    AppRoute.runs,
    'Activity',
    Icons.play_circle_outline,
    primaryOnMobile: true,
    section: 'Agents',
  ),
  AppRouteInfo(
    AppRoute.mission,
    'Team runs',
    Icons.hub_outlined,
    primaryOnMobile: false,
    section: 'Agents',
  ),
  AppRouteInfo(
    AppRoute.memory,
    'Memory',
    Icons.memory_outlined,
    primaryOnMobile: false,
    section: 'Knowledge',
  ),
  AppRouteInfo(
    AppRoute.events,
    'Events',
    Icons.bolt_outlined,
    primaryOnMobile: false,
    section: 'Control',
  ),
  AppRouteInfo(
    AppRoute.logs,
    'Logs',
    Icons.article_outlined,
    primaryOnMobile: false,
    section: 'Control',
  ),
  AppRouteInfo(
    AppRoute.hooks,
    'Event rules',
    Icons.webhook_outlined,
    primaryOnMobile: false,
    section: 'Settings',
  ),
  AppRouteInfo(
    AppRoute.settings,
    'Settings',
    Icons.settings_outlined,
    primaryOnMobile: false,
    section: 'Settings',
  ),
];

const String kMobileMoreLabel = 'More';

/// GUI-P2-01: Simple mode keeps the everyday control center (chat, workspace,
/// activity, approval, history, tasks, memory, settings); modul teknis
/// (skills, bots, providers, tools/MCP/plugins, channels, automation,
/// security, audit, artifacts, team runs, events, logs, graf/editor) hanya
/// muncul pada Advanced mode. Kemampuan runtime tidak berubah — ini murni
/// progressive disclosure di layer navigasi.
const Set<AppRoute> kSimpleRoutes = {
  AppRoute.chat,
  AppRoute.dashboard,
  AppRoute.runs,
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
