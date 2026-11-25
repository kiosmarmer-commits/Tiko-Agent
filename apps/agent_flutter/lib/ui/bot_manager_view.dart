
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

final RegExp _botIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

/// Bot/Agent Manager (GUI-P1-04): CRUD profil bot persisten + binding sesi
/// di atas `GET/POST/PATCH/DELETE /v1/bots*`. Satu sumber data dengan web UI
/// (BotStore di tiko_runtime). Sesu yang bisa di-bind diambil dari daftar
/// sesi via [availableSessions].
class BotsPage extends StatefulWidget {
  const BotsPage({
    super.key,
    required this.bots,
    required this.bindings,
    required this.availableSessions,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
    this.onCreate,
    this.onUpdate,
    this.onDelete,
    this.onBind,
    this.onUnbind,
  });

  final List<BotProfileItem> bots;
  final Map<String, String> bindings;
  final List<String> availableSessions;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;
  final Future<void> Function(Map<String, dynamic> body)? onCreate;
  final Future<void> Function(String id, Map<String, dynamic> body)? onUpdate;
  final Future<bool> Function(String id)? onDelete;
  final Future<bool> Function(String botId, String sessionId)? onBind;
  final Future<bool> Function(String botId, String sessionId)? onUnbind;

  @override
  State<BotsPage> createState() => _BotsPageState();
}

class _BotsPageState extends State<BotsPage> {
  String _query = '';

  List<BotProfileItem> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.bots;
    return widget.bots
        .where((b) =>
            b.id.toLowerCase().contains(q) ||
            b.name.toLowerCase().contains(q) ||
            (b.model ?? '').toLowerCase().contains(q))
        .toList();
  }

  int _boundCount(String botId) => widget.bindings.values
      .where((bot) => bot == botId)
      .length;

  @override
  Widget build(BuildContext context) {
    final bots = _filtered;
    return Column(
      children: [
        PageHeader(
          title: 'Bots',
          subtitle:
              '${widget.bots.length} bot \u00b7 CRUD & binding sesi',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onCreate != null)
                IconButton(
                  tooltip: 'Buat bot baru',
                  onPressed: () => _openCreateDialog(context),
                  icon: const Icon(Icons.add),
                ),
              if (widget.onRefresh != null)
                IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
        if (widget.surfaceSection != null) widget.surfaceSection!,
        if (widget.loading) StatusViews.loadingBanner(context),
        if (widget.error != null)
            StatusViews.errorBanner(context, widget.error!),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Saring id, nama, atau model\u2026',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: bots.isEmpty
              ? StatusViews.empty(
                  context,
                  message: _query.isEmpty
                      ? 'Belum ada bot. Buat bot pertama lewat tombol +'
                      : 'Tidak ada bot yang cocok.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: bots.length,
                  itemBuilder: (context, i) {
                    final bot = bots[i];
                    return _BotCard(
                      bot: bot,
                      boundCount: _boundCount(bot.id),
                      onEdit: widget.onUpdate == null
                          ? null
                          : () => _openEditDialog(context, bot),
                      onDelete: widget.onDelete == null
                          ? null
                          : () => _confirmDelete(context, bot),
                      onBindings: widget.onBind == null || widget.onUnbind == null
                          ? null
                          : () => _openBindingsSheet(context, bot),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openCreateDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _BotDialog(),
    );
    if (created == null || widget.onCreate == null) return;
    try {
      await widget.onCreate!(created);
      messenger.showSnackBar(SnackBar(
        backgroundColor: okColor,
        content: Text('Bot ${created['id']} dibuat.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal membuat bot: $e'),
      ));
    }
  }

  Future<void> _openEditDialog(BuildContext context, BotProfileItem bot) async {
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _BotDialog(existing: bot),
    );
    if (updated == null || widget.onUpdate == null) return;
    try {
      await widget.onUpdate!(bot.id, updated);
      messenger.showSnackBar(SnackBar(
        backgroundColor: okColor,
        content: Text('Bot ${bot.id} diperbarui.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal memperbarui ${bot.id}: $e'),
      ));
    }
  }

  Future<void> _confirmDelete(BuildContext context, BotProfileItem bot) async {
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus bot ${bot.id}?'),
        content: Text(
          'Profil dihapus dan semua sesi yang ter-bind ke ${bot.id} akan '
          'dilepas. Tindakan ini tidak bisa dibatalkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true || widget.onDelete == null) return;
    try {
      final ok = await widget.onDelete!(bot.id);
      messenger.showSnackBar(SnackBar(
        backgroundColor: ok ? okColor : failColor,
        content: Text(ok ? 'Bot ${bot.id} dihapus.' : 'Bot ${bot.id} tidak ditemukan.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: failColor,
        content: Text('Gagal menghapus ${bot.id}: $e'),
      ));
    }
  }

  Future<void> _openBindingsSheet(BuildContext context, BotProfileItem bot) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          shrinkWrap: true,
          children: [
            Text('Binding sesi \u2014 ${bot.name.isEmpty ? bot.id : bot.name}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...widget.availableSessions.map((session) {
              final boundBot = widget.bindings[session];
              final boundToThis = boundBot == bot.id;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  boundToThis
                      ? Icons.link
                      : boundBot != null
                          ? Icons.link_off
                          : Icons.circle_outlined,
                  color: boundToThis
                      ? context.simpulSuccess
                      : boundBot != null
                          ? context.simpulMuted
                          : context.simpulAccent,
                ),
                title: Text(session),
                subtitle: Text(
                  boundToThis
                      ? 'ter-bind ke bot ini'
                      : boundBot != null
                          ? 'ter-bind ke $boundBot'
                          : 'belum ter-bind',
                ),
                trailing: boundToThis
                    ? TextButton(
                        onPressed: () async {
                          final ok = await widget.onUnbind!(bot.id, session);
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                          _reportBinding(bot.id, session, bind: false, ok: ok);
                        },
                        child: const Text('Unbind'),
                      )
                    : (boundBot == null
                        ? TextButton(
                            onPressed: () async {
                              final ok = await widget.onBind!(bot.id, session);
                              if (sheetContext.mounted) {
                                Navigator.of(sheetContext).pop();
                              }
                              _reportBinding(bot.id, session, bind: true, ok: ok);
                            },
                            child: const Text('Bind'),
                          )
                        : null),
              );
            }),
            if (widget.availableSessions.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Belum ada sesi yang bisa di-bind.',
                  style: TextStyle(color: context.simpulMuted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _reportBinding(String botId, String session,
      {required bool bind, required bool ok}) {
    final messenger = ScaffoldMessenger.of(context);
    final okColor = context.simpulSuccess;
    final failColor = context.simpulDanger;
    messenger.showSnackBar(SnackBar(
      backgroundColor: ok ? okColor : failColor,
      content: Text(
        ok
            ? (bind
                ? '$session ter-bind ke $botId.'
                : '$session dilepas dari $botId.')
            : 'Gagal ${bind ? 'bind' : 'unbind'} $session ${bind ? 'ke' : 'dari'} $botId.',
      ),
    ));
  }
}

class _BotCard extends StatelessWidget {
  const _BotCard({
    required this.bot,
    required this.boundCount,
    this.onEdit,
    this.onDelete,
    this.onBindings,
  });

  final BotProfileItem bot;
  final int boundCount;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onBindings;

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
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bot.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Text(bot.id,
                  style: TextStyle(color: context.simpulMuted, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (bot.model != null && bot.model!.isNotEmpty) bot.model!,
              'allowlist ${bot.toolAllowlist.length} tool',
              '$boundCount sesi ter-bind',
              if (bot.greeting.isNotEmpty) 'greeting ada',
            ].join(' \u00b7 '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
          if (bot.persona.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                bot.persona,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.simpulMuted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: 'Binding sesi',
                onPressed: onBindings,
                icon: const Icon(Icons.link, size: 18),
              ),
              IconButton(
                tooltip: 'Edit profil',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Hapus bot',
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline,
                    size: 18, color: context.simpulDanger),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Dialog Create/Edit bot: id (create only, divalidasi regex sama dengan
/// BotProfile.isValidId), name, model, greeting, persona multiline, dan
/// tool_allowlist comma-separated.
class _BotDialog extends StatefulWidget {
  const _BotDialog({this.existing});

  final BotProfileItem? existing;

  @override
  State<_BotDialog> createState() => _BotDialogState();
}

class _BotDialogState extends State<_BotDialog> {
  late final TextEditingController _id =
      TextEditingController(text: widget.existing?.id ?? '');
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _model =
      TextEditingController(text: widget.existing?.model ?? '');
  late final TextEditingController _greeting =
      TextEditingController(text: widget.existing?.greeting ?? '');
  late final TextEditingController _persona =
      TextEditingController(text: widget.existing?.persona ?? '');
  late final TextEditingController _allowlist = TextEditingController(
      text: widget.existing?.toolAllowlist.join(', ') ?? '');

  String? _idError;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _model.dispose();
    _greeting.dispose();
    _persona.dispose();
    _allowlist.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _submit() {
    final id = _id.text.trim();
    final name = _name.text.trim();
    var valid = true;
    if (widget.existing == null && !_botIdPattern.hasMatch(id)) {
      setState(() => _idError =
          'Huruf kecil/angka, "-" atau "_", mulai huruf/angka, maks 64.');
      valid = false;
    }
    if (name.isEmpty) valid = false;
    if (!valid) return null;
    final body = <String, dynamic>{
      'name': name,
      'persona': _persona.text.trim(),
      'greeting': _greeting.text.trim(),
    };
    final model = _model.text.trim();
    body['model'] = model.isEmpty ? null : model;
    if (widget.existing == null) body['id'] = id;
    final tools = _allowlist.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    body['tool_allowlist'] = tools;
    return body;
  }

  @override
  Widget build(BuildContext context) {
    final isCreate = widget.existing == null;
    return AlertDialog(
      title: Text(isCreate ? 'Buat bot baru' : 'Edit bot ${widget.existing!.id}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCreate)
              TextField(
                controller: _id,
                decoration: InputDecoration(
                  labelText: 'id',
                  hintText: 'helper',
                  errorText: _idError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_idError != null) setState(() => _idError = null);
                },
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Text('id: ${widget.existing!.id}',
                    style: TextStyle(color: context.simpulMuted, fontSize: 12)),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nama',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Model (opsional)',
                hintText: 'kosongkan untuk memakai model default',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _greeting,
              decoration: const InputDecoration(
                labelText: 'Greeting (opsional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _persona,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Persona (opsional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _allowlist,
              decoration: const InputDecoration(
                labelText: 'Tool allowlist (pisah koma)',
                hintText: 'read_file, shell',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            final body = _submit();
            if (body != null) Navigator.of(context).pop(body);
          },
          child: Text(isCreate ? 'Buat' : 'Simpan'),
        ),
      ],
    );
  }
}
