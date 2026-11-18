
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Provider & Model Manager (GUI-P1-05): daftar provider chat + health
/// circuit breaker, mapping tier router, dan override `/model` per sesi —
/// paritas dengan command `/model` di chat, lewat REST
/// `GET /v1/providers` + `POST /v1/providers/session`.
class ProviderManagerPage extends StatefulWidget {
  const ProviderManagerPage({
    super.key,
    required this.snapshot,
    required this.availableSessions,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onSetSessionProvider,
  });

  final ProvidersSnapshot? snapshot;
  final List<String> availableSessions;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// [sessionId] + argumen provider (id atau `default`). False bila provider
  /// tidak dikenal.
  final Future<bool> Function(String sessionId, String providerArg)?
      onSetSessionProvider;

  @override
  State<ProviderManagerPage> createState() => _ProviderManagerPageState();
}

class _ProviderManagerPageState extends State<ProviderManagerPage> {
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return Column(
      children: [
        PageHeader(
          title: 'Providers',
          subtitle: snapshot == null
              ? 'Provider & model'
              : '${snapshot.providers.length} provider \u00b7 '
                  'default: ${snapshot.defaultId ?? '-'} \u00b7 '
                  '${snapshot.sessionOverrides.length} override sesi',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onSetSessionProvider != null)
                IconButton(
                  tooltip: 'Set override sesi',
                  onPressed: () => _openOverrideDialog(context),
                  icon: const Icon(Icons.add),
                ),
              if (widget.onRefresh != null)
                IconButton(
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child:
                Text(widget.error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: snapshot == null
              ? Center(
                  child: Text('Belum ada data provider.',
                      style: TextStyle(color: context.simpulMuted)),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    ...snapshot.providers.map(
                        (p) => _ProviderCard(provider: p, isDefault: p.id == snapshot.defaultId)),
                    if (snapshot.tiers.isNotEmpty)
                      _SectionCard(
                        title: 'Tier routing',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final e in snapshot.tiers.entries)
                              Text('tier ${e.key} \u2192 ${e.value}',
                                  style: TextStyle(
                                      color: context.simpulMuted,
                                      fontSize: 12)),
                          ],
                        ),
                      ),
                    _SectionCard(
                      title:
                          'Override sesi (${snapshot.sessionOverrides.length})',
                      child: snapshot.sessionOverrides.isEmpty
                          ? Text(
                              'Tidak ada override \u2014 semua sesi memakai provider default router.',
                              style: TextStyle(
                                  color: context.simpulMuted, fontSize: 12),
                            )
                          : Column(
                              children: [
                                for (final e
                                    in snapshot.sessionOverrides.entries)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.model_training,
                                        size: 18),
                                    title: Text(e.key),
                                    subtitle: Text('override \u2192 ${e.value}'),
                                    trailing: widget.onSetSessionProvider == null
                                        ? null
                                        : TextButton(
                                            onPressed: () =>
                                                _setProvider(e.key, 'default'),
                                            child: const Text('Reset default'),
                                          ),
                                  ),
                              ],
                            ),
                    ),
                    if (widget.availableSessions.isNotEmpty)
                      _SectionCard(
                        title: 'Sesi yang bisa di-override',
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (final session in widget.availableSessions)
                              if (!snapshot.sessionOverrides
                                  .containsKey(session))
                                ActionChip(
                                  label: Text(session, style: const TextStyle(fontSize: 12)),
                                  onPressed: widget.onSetSessionProvider == null
                                      ? null
                                      : () => _openOverrideDialog(context,
                                          initialSession: session),
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

  Future<void> _openOverrideDialog(BuildContext context,
      {String? initialSession}) async {
    final snapshot = widget.snapshot;
    if (snapshot == null) return;
    final setter = widget.onSetSessionProvider;
    if (setter == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;

    final sessionController = TextEditingController(
        text: initialSession ??
            (widget.availableSessions.isEmpty ? '' : widget.availableSessions.first));
    String providerArg = snapshot.defaultId ?? 'default';
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set override sesi'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: sessionController,
                decoration: const InputDecoration(
                  labelText: 'Session id',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: providerArg,
                decoration: const InputDecoration(
                  labelText: 'Provider',
                  border: OutlineInputBorder(),
                ),
                items: [
                  if (snapshot.defaultId != null)
                    DropdownMenuItem(
                        value: 'default',
                        child: Text('default (${snapshot.defaultId})')),
                  for (final p in snapshot.providers)
                    DropdownMenuItem(
                        value: p.id,
                        child: Text(p.id == snapshot.defaultId
                            ? '${p.id} (default)'
                            : p.id)),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => providerArg = v);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final session = sessionController.text.trim();
              if (session.isEmpty) return;
              Navigator.of(dialogContext).pop((session, providerArg));
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final (session, arg) = result;
    try {
      final ok = await setter(session, arg);
      messenger.showSnackBar(SnackBar(
        backgroundColor: ok ? okColor : failColor,
        content: Text(ok
            ? (arg == 'default'
                ? 'Sesi $session kembali memakai provider default.'
                : 'Sesi $session memakai provider: $arg.')
            : 'Provider $arg tidak dikenal.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal set provider sesi $session: $e'),
      ));
    }
  }

  Future<void> _setProvider(String sessionId, String arg) async {
    final setter = widget.onSetSessionProvider;
    if (setter == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    try {
      final ok = await setter(sessionId, arg);
      messenger.showSnackBar(SnackBar(
        backgroundColor: ok ? okColor : failColor,
        content: Text(ok
            ? 'Sesi $sessionId kembali memakai provider default.'
            : 'Gagal mereset sesi $sessionId.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal mereset sesi $sessionId: $e'),
      ));
    }
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.provider, required this.isDefault});

  final ProviderItem provider;
  final bool isDefault;

  @override
  Widget build(BuildContext context) {
    final health = provider.health;
    final phaseColor = switch (health?.phase) {
      'closed' => context.simpulSuccess,
      'half_open' => context.simpulWarn,
      'open' => context.simpulDanger,
      _ => context.simpulMuted,
    };
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
              Expanded(
                child: Text(
                  provider.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              if (isDefault)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: phaseColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('default',
                      style: TextStyle(
                          color: context.simpulAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: phaseColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(health?.phase ?? 'unknown',
                    style: TextStyle(
                        color: phaseColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              'tools ${provider.toolCalling ? '\u2713' : '\u2717'}',
              'vision ${provider.vision ? '\u2713' : '\u2717'}',
              'streaming ${provider.streaming ? '\u2713' : '\u2717'}',
              if (provider.maxContext > 0)
                'context ${provider.maxContext}',
            ].join(' \u00b7 '),
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          if (health != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                'sukses ${health.successes}',
                'gagal ${health.failures}',
                'latensi ${health.lastLatencyMs.toStringAsFixed(0)}ms',
                if (health.lastError != null) 'error terakhir ada',
              ].join(' \u00b7 '),
              style: TextStyle(color: context.simpulMuted, fontSize: 12),
            ),
            if (health.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  health.lastError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: context.simpulDanger,
                      fontSize: 12),
                ),
              ),
          ],
        ],
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
