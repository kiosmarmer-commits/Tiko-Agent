
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Security Center (GUI-P1-10): konsolidasi status keamanan runtime —
/// safe mode/panic, sandbox, state kredensial, consent plugin, token
/// anomaly (E1), anomali rate, growth guard, dan ringkasan audit terakhir.
/// Semua read-only via `GET /v1/security`; tanpa nilai rahasia.
class SecurityPage extends StatelessWidget {
  const SecurityPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
  });

  final SecuritySnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    return Column(
      children: [
        PageHeader(
          title: 'Security',
          subtitle: snapshot == null
              ? 'Status keamanan runtime'
              : '${_statusLabel(snapshot)} \u00b7 '
                  '${snapshot.plugins.length} plugin \u00b7 '
                  '${snapshot.activeSessions} sesi aktif',
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
        if (surfaceSection != null) surfaceSection!,
        if (loading) StatusViews.loadingBanner(context),
        if (error != null)
            StatusViews.errorBanner(context, error!),
        Expanded(
          child: snapshot == null
              ? StatusViews.empty(context, message: 'Belum ada data keamanan.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    _SafetyCard(snapshot: snapshot),
                    _TokenAnomalyCard(snapshot: snapshot),
                    _PluginConsentsCard(plugins: snapshot.plugins),
                    _GuardCard(snapshot: snapshot),
                    _AuditCard(
                      total: snapshot.auditTotal,
                      recent: snapshot.auditRecent,
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  String _statusLabel(SecuritySnapshot snapshot) {
    if (snapshot.panic) return 'PANIC';
    if (snapshot.safeMode) return 'safe mode';
    return 'normal';
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard({required this.snapshot});

  final SecuritySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final danger = snapshot.panic || snapshot.stopRequested;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
        border: Border.all(
          color: danger ? context.simpulDanger : context.simpulBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Safety',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _Pill(
                label: snapshot.safeMode ? 'safe mode ON' : 'safe mode OFF',
                status: snapshot.safeMode,
              ),
              if (snapshot.panic)
                const _Pill(label: 'PANIC aktif', status: false),
              if (snapshot.stopRequested)
                const _Pill(label: 'stop request aktif', status: false),
              _Pill(label: 'sandbox ${snapshot.sandbox}', status: true),
              _Pill(
                label: snapshot.sealedStorage
                    ? 'kredensial terenkripsi at-rest'
                    : 'kredensial plaintext (chmod 600)',
                status: snapshot.sealedStorage,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Sesi aktif: ${snapshot.activeSessions}',
              style: TextStyle(color: context.simpulMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _TokenAnomalyCard extends StatelessWidget {
  const _TokenAnomalyCard({required this.snapshot});

  final SecuritySnapshot snapshot;

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
          const Text('Token anomaly (E1)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            snapshot.tokenAnomalyEnabled
                ? 'Detektor aktif \u00b7 karantina hari ini '
                    '${snapshot.quarantinesToday}/${snapshot.maxQuarantinesPerDay} '
                    'skill dengan lonjakan token (baseline statistik per skill)'
                : 'Detektor nonaktif (opt-in via config security.token_anomaly)',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          if (snapshot.tokenSkillStats.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...snapshot.tokenSkillStats.map(
              (s) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${s.slug}: ${s.samples} sampel baseline',
                  style: TextStyle(color: context.simpulMuted, fontSize: 11),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PluginConsentsCard extends StatelessWidget {
  const _PluginConsentsCard({required this.plugins});

  final List<SecurityPluginItem> plugins;

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
          const Text('Plugin & consent',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          if (plugins.isEmpty)
            Text('Tidak ada plugin terdaftar.',
                style: TextStyle(color: context.simpulMuted, fontSize: 12))
          else
            ...plugins.map(
              (plugin) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(plugin.id,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      plugin.pending
                          ? 'menunggu consent'
                          : plugin.registered
                              ? '${plugin.grantedCount} izin'
                              : 'tidak terdaftar',
                      style: TextStyle(
                        color: plugin.pending
                            ? context.simpulWarn
                            : context.simpulMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GuardCard extends StatelessWidget {
  const _GuardCard({required this.snapshot});

  final SecuritySnapshot snapshot;

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
          const Text('Guard & rate',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            'PromptGuard: ${snapshot.guardBlockedTurns} turn diblokir, '
            '${snapshot.guardSanitizedTurns} turn disanitasi (sejak start) \u00b7 '
            'rate anomaly: >${snapshot.rateMaxEvents} pesan/'
            '${snapshot.rateWindowSec}s per user dianggap anomali',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.total, required this.recent});

  final int total;
  final List<Map<String, dynamic>> recent;

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
          Text('Audit terakhir ($total entri di memori)',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          if (recent.isEmpty)
            Text('Belum ada entri audit.',
                style: TextStyle(color: context.simpulMuted, fontSize: 12))
          else
            ...recent.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${entry['ts'] ?? '-'} \u00b7 ${entry['tool'] ?? '-'} \u00b7 '
                  'risk ${entry['risk'] ?? '-'} \u00b7 ${entry['verdict'] ?? '-'}'
                  '${entry['session'] == null ? '' : ' \u00b7 ${entry['session']}'}',
                  style: TextStyle(color: context.simpulMuted, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.status});

  final String label;
  final bool status;

  @override
  Widget build(BuildContext context) {
    final color = status ? context.simpulSuccess : context.simpulMuted;
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
