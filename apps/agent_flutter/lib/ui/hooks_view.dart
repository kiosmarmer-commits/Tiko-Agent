import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Hooks manager (SETTINGS-HOOKS): melihat hook aktif, menambah/mengubah
/// webhook atau script, statistik sukses/gagal, dan menguji hook — lewat
/// REST `GET/POST/PATCH/DELETE /v1/hooks*`.
class HooksPage extends StatefulWidget {
  const HooksPage({
    super.key,
    required this.snapshot,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.onAdd,
    this.onUpdate,
    this.onDelete,
    this.onTest,
  });

  final HooksSnapshot? snapshot;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Body berbentuk [HookRuleInfo.toPayload]; mengembalikan Future yang
  /// selesai bila mutasi sukses (error dilempar ke pemanggil halaman).
  final Future<void> Function(Map<String, dynamic> body)? onAdd;
  final Future<void> Function(int index, Map<String, dynamic> body)? onUpdate;
  final Future<void> Function(int index)? onDelete;
  final Future<Map<String, dynamic>> Function(int index)? onTest;

  @override
  State<HooksPage> createState() => _HooksPageState();
}

class _HooksPageState extends State<HooksPage> {
  int _testingIndex = -1;

  HookStatInfo? _statFor(HooksSnapshot snapshot, int index, String target) =>
      snapshot.stats['hooks[$index]:$target'];

  Future<void> _test(BuildContext context, int index) async {
    final callback = widget.onTest;
    if (callback == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    setState(() => _testingIndex = index);
    try {
      final result = await callback(index);
      final results = result['results'] as List? ?? const [];
      final failed = results
          .whereType<Map>()
          .where((r) => r['ok'] != true)
          .map((r) => '${r['target']}: ${r['error']}')
          .toList();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: failed.isEmpty ? okColor : failColor,
        content: Text(failed.isEmpty
            ? 'Test hook #$index berhasil (${results.length} target)'
            : 'Test hook #$index gagal: ${failed.join('; ')}'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal test hook #$index: $e'),
      ));
    } finally {
      if (mounted) setState(() => _testingIndex = -1);
    }
  }

  Future<void> _delete(BuildContext context, int index) async {
    final callback = widget.onDelete;
    if (callback == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus hook?'),
        content: Text('Hook #$index akan dihapus dari config dan runtime.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await callback(index);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: okColor,
        content: Text('Hook #$index dihapus'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal hapus hook #$index: $e'),
      ));
    }
  }

  Future<void> _openForm(BuildContext context, {int? index}) async {
    final existing = index == null ? null : widget.snapshot!.rules[index];
    final Future<void> Function(Map<String, dynamic> body)? callback =
        index == null ? widget.onAdd : (b) => widget.onUpdate!(index, b);
    if (callback == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    final rule = await showDialog<HookRuleInfo>(
      context: context,
      builder: (_) => _HookFormDialog(existing: existing),
    );
    if (rule == null) return;
    try {
      await callback(rule.toPayload());
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: okColor,
        content: Text(index == null
            ? 'Hook ${rule.event} ditambahkan'
            : 'Hook #$index diperbarui'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal menyimpan hook: $e'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return Column(
      children: [
        PageHeader(
          title: 'Hooks',
          subtitle: snapshot == null
              ? 'Event hooks webhook/script'
              : '${snapshot.rules.length} hook aktif \u00b7 '
                  '${snapshot.stats.values.fold<int>(0, (a, s) => a + s.fires)} fire \u00b7 '
                  '${snapshot.stats.values.fold<int>(0, (a, s) => a + s.failures)} gagal',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onAdd != null)
                IconButton(
                  key: const Key('hooks-add'),
                  tooltip: 'Tambah hook',
                  onPressed: () => _openForm(context),
                  icon: const Icon(Icons.add),
                ),
              if (widget.onRefresh != null)
                IconButton(
                  key: const Key('hooks-refresh'),
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
            child: Text(widget.error!,
                style: TextStyle(color: context.simpulDanger)),
          ),
        Expanded(
          child: snapshot == null
              ? Center(
                  child: Text('Belum ada data hooks.',
                      style: TextStyle(color: context.simpulMuted)),
                )
              : snapshot.rules.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(SimpulTheme.xl),
                          decoration: BoxDecoration(
                            color: context.simpulPanel,
                            borderRadius:
                                BorderRadius.circular(SimpulTheme.radiusSmall),
                            border: Border.all(color: context.simpulBorder),
                          ),
                          child: Column(
                            children: [
                              Icon(Icons.bolt_outlined,
                                  size: 32, color: context.simpulMuted),
                              const SizedBox(height: SimpulTheme.m),
                              Text('Belum ada hook terpasang.',
                                  style:
                                      TextStyle(color: context.simpulMuted)),
                              Text(
                                'Tambahkan webhook atau script untuk event '
                                'seperti `model.switched`, atau `*`.',
                                style: TextStyle(
                                    color: context.simpulMuted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        for (var i = 0; i < snapshot.rules.length; i++)
                          _HookCard(
                            key: Key('hook-card-$i'),
                            index: i,
                            rule: snapshot.rules[i],
                            statWebhook: _statFor(snapshot, i, 'webhook'),
                            statScript: _statFor(snapshot, i, 'script'),
                            testing: _testingIndex == i,
                            onEdit: () => _openForm(context, index: i),
                            onDelete: () => _delete(context, i),
                            onTest: () => _test(context, i),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _HookCard extends StatelessWidget {
  const _HookCard({
    super.key,
    required this.index,
    required this.rule,
    this.statWebhook,
    this.statScript,
    this.onEdit,
    this.onDelete,
    this.onTest,
    this.testing = false,
  });

  final int index;
  final HookRuleInfo rule;
  final HookStatInfo? statWebhook;
  final HookStatInfo? statScript;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onTest;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final stat = statWebhook ?? statScript;
    final hasFailures = (statWebhook?.failures ?? 0) +
            (statScript?.failures ?? 0) >
        0;
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
              const Icon(Icons.bolt_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  rule.event,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              IconButton(
                key: Key('hook-test-$index'),
                tooltip: 'Test hook',
                onPressed: onTest,
                icon: testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_outlined, size: 18),
              ),
              IconButton(
                key: Key('hook-edit-$index'),
                tooltip: 'Ubah hook',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              IconButton(
                key: Key('hook-delete-$index'),
                tooltip: 'Hapus hook',
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline,
                    size: 18, color: context.simpulDanger),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (rule.webhookUrl != null)
                _TargetChip(label: 'webhook', detail: rule.webhookUrl!),
              if (rule.script != null)
                _TargetChip(label: 'script', detail: rule.script!),
              _TargetChip(label: 'timeout', detail: '${rule.timeoutSec}s'),
            ],
          ),
          if (rule.env.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'env: ${rule.env.keys.join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.simpulMuted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              _StatText(
                label: 'fire',
                value: stat?.fires ?? 0,
                color: context.simpulMuted,
              ),
              const SizedBox(width: 16),
              _StatText(
                label: 'gagal',
                value: (statWebhook?.failures ?? 0) +
                    (statScript?.failures ?? 0),
                color: hasFailures
                    ? context.simpulDanger
                    : context.simpulMuted,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  stat?.lastError != null
                      ? '${stat!.lastError} (${stat.lastAt ?? ''})'
                      : stat?.lastAt != null
                          ? 'terakhir: ${stat!.lastAt}'
                          : 'belum pernah fire',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: stat?.lastError != null
                        ? context.simpulDanger
                        : context.simpulMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.simpulAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label \u00b7 $detail',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.simpulAccent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatText extends StatelessWidget {
  const _StatText({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: TextStyle(fontSize: 11, color: color),
    );
  }
}

class _HookFormDialog extends StatefulWidget {
  const _HookFormDialog({this.existing});

  final HookRuleInfo? existing;

  @override
  State<_HookFormDialog> createState() => _HookFormDialogState();
}

class _HookFormDialogState extends State<_HookFormDialog> {
  late final TextEditingController _event;
  late final TextEditingController _target;
  late final TextEditingController _timeout;
  late final TextEditingController _env;
  bool _webhook = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _event = TextEditingController(text: existing?.event ?? '');
    _webhook = existing == null || existing.webhookUrl != null;
    _target = TextEditingController(
        text: existing == null
            ? ''
            : (_webhook ? existing.webhookUrl ?? '' : existing.script ?? ''));
    _timeout = TextEditingController(
        text: existing == null ? '30' : '${existing.timeoutSec}');
    _env = TextEditingController(
        text: existing == null
            ? ''
            : existing.env.entries.map((e) => '${e.key}=${e.value}').join('\n'));
  }

  @override
  void dispose() {
    _event.dispose();
    _target.dispose();
    _timeout.dispose();
    _env.dispose();
    super.dispose();
  }

  HookRuleInfo? _submit() {
    final event = _event.text.trim();
    final target = _target.text.trim();
    if (event.isEmpty || target.isEmpty) {
      setState(() => _error = 'Event dan target wajib diisi');
      return null;
    }
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout < 1 || timeout > 120) {
      setState(() => _error = 'Timeout 1-120 detik');
      return null;
    }
    final env = <String, String>{};
    for (final line in _env.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) {
        setState(() => _error = 'Env harus format KEY=VALUE per baris');
        return null;
      }
      env[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
    }
    return HookRuleInfo(
      event: event,
      webhookUrl: _webhook ? target : null,
      script: _webhook ? null : target,
      timeoutSec: timeout,
      env: env,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null
          ? 'Tambah hook'
          : 'Ubah hook ${widget.existing!.event}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('hook-form-event'),
              controller: _event,
              decoration: const InputDecoration(
                labelText: 'Event',
                hintText: 'model.switched atau *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: SimpulTheme.m),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Webhook')),
                ButtonSegment(value: false, label: Text('Script')),
              ],
              selected: {_webhook},
              onSelectionChanged: (selection) =>
                  setState(() => _webhook = selection.first),
            ),
            const SizedBox(height: SimpulTheme.m),
            TextField(
              key: const Key('hook-form-target'),
              controller: _target,
              decoration: InputDecoration(
                labelText: _webhook ? 'URL webhook' : 'Path script',
                hintText: _webhook
                    ? 'https://contoh.com/hook'
                    : 'scripts/notify.sh',
                border: const OutlineInputBorder(),
                helperText: _webhook
                    ? 'Hanya http/https'
                    : 'Path relatif workspace, tanpa ../ atau ~',
              ),
            ),
            const SizedBox(height: SimpulTheme.m),
            TextField(
              key: const Key('hook-form-timeout'),
              controller: _timeout,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Timeout (detik)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: SimpulTheme.m),
            TextField(
              key: const Key('hook-form-env'),
              controller: _env,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Env (opsional)',
                hintText: 'API_KEY=xxx',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: SimpulTheme.m),
              Text(_error!, style: TextStyle(color: context.simpulDanger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          key: const Key('hook-form-save'),
          onPressed: () {
            final rule = _submit();
            if (rule != null) Navigator.pop(context, rule);
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
