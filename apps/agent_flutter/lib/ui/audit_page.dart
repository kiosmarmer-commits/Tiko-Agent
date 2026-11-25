import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Audit query browser (GUI-P1-11): filter entri audit runtime
/// (tool/session/risk/verdict/taint) dan pagination — read-only via
/// `GET /v1/audit`. entri sudah teredaksi server-side.
class AuditPage extends StatefulWidget {
  const AuditPage({
    super.key,
    required this.result,
    required this.online,
    required this.loading,
    this.error,
    this.onQuery,
    this.onRefresh,
    this.onNext,
    this.pageSize = 50,
  });

  final AuditQueryResult? result;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function(Map<String, String> filters)? onQuery;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onNext;
  final int pageSize;

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final _tool = TextEditingController();
  final _session = TextEditingController();
  String _risk = '';
  String _verdict = '';
  bool _taintOnly = false;

  static const _riskOptions = ['', 'low', 'medium', 'high'];
  static const _verdictOptions = ['', 'allow', 'approve', 'deny', 'sanitize'];

  Map<String, String> _filters() => {
        if (_tool.text.trim().isNotEmpty) 'tool': _tool.text.trim(),
        if (_session.text.trim().isNotEmpty) 'session': _session.text.trim(),
        if (_risk.isNotEmpty) 'risk': _risk,
        if (_verdict.isNotEmpty) 'verdict': _verdict,
        if (_taintOnly) 'taint': 'true',
      };

  void _submit() {
    widget.onQuery?.call(_filters());
  }

  @override
  void dispose() {
    _tool.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    return Column(
      children: [
        PageHeader(
          title: 'Audit',
          subtitle: result == null
              ? 'Query entri audit runtime (lebih detail dari ringkasan Security)'
              : '${result.total} entri cocok \u00b7 menampilkan '
                  '${result.entries.length}',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onQuery != null)
                IconButton(
                    tooltip: 'Cari',
                    onPressed: _submit, icon: const Icon(Icons.search)),
              if (widget.onRefresh != null)
                IconButton(
                    tooltip: 'Muat ulang',
                    onPressed: widget.onRefresh, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        if (widget.loading) StatusViews.loadingBanner(context),
        if (widget.error != null)
            StatusViews.errorBanner(context, widget.error!),
        _FilterBar(
          tool: _tool,
          session: _session,
          risk: _risk,
          verdict: _verdict,
          taintOnly: _taintOnly,
          riskOptions: _riskOptions,
          verdictOptions: _verdictOptions,
          onRisk: (v) => setState(() => _risk = v),
          onVerdict: (v) => setState(() => _verdict = v),
          onTaintOnly: (v) => setState(() => _taintOnly = v),
          onSubmit: _submit,
        ),
        Expanded(
          child: result == null
              ? StatusViews.empty(context, message: 'Belum ada query audit \u2014 tekan cari.')
              : result.entries.isEmpty
                  ? StatusViews.empty(context, message: 'Tidak ada entri yang cocok.')
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: result.entries.length +
                          (widget.onNext != null &&
                                  result.entries.length >= widget.pageSize
                              ? 1
                              : 0),
                      itemBuilder: (context, index) {
                        if (index >= result.entries.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: FilledButton.tonal(
                              onPressed: widget.onNext,
                              child: const Text('Muat selanjutnya'),
                            ),
                          );
                        }
                        return _AuditTile(entry: result.entries[index]);
                      },
                    ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.tool,
    required this.session,
    required this.risk,
    required this.verdict,
    required this.taintOnly,
    required this.riskOptions,
    required this.verdictOptions,
    required this.onRisk,
    required this.onVerdict,
    required this.onTaintOnly,
    required this.onSubmit,
  });

  final TextEditingController tool;
  final TextEditingController session;
  final String risk;
  final String verdict;
  final bool taintOnly;
  final List<String> riskOptions;
  final List<String> verdictOptions;
  final ValueChanged<String> onRisk;
  final ValueChanged<String> onVerdict;
  final ValueChanged<bool> onTaintOnly;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                child: TextField(
                  controller: tool,
                  decoration: const InputDecoration(
                      hintText: 'tool (mis. shell)', isDense: true),
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: session,
                  decoration: const InputDecoration(
                      hintText: 'session (mis. web:default)', isDense: true),
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              DropdownButton<String>(
                value: risk,
                onChanged: (v) => onRisk(v ?? ''),
                items: [
                  for (final o in riskOptions)
                    DropdownMenuItem(
                        value: o,
                        child: Text(o.isEmpty ? 'risk semua' : o,
                            style: const TextStyle(fontSize: 12))),
                ],
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: verdict,
                onChanged: (v) => onVerdict(v ?? ''),
                items: [
                  for (final o in verdictOptions)
                    DropdownMenuItem(
                        value: o,
                        child: Text(o.isEmpty ? 'verdict semua' : o,
                            style: const TextStyle(fontSize: 12))),
                ],
              ),
              const Spacer(),
              Text('taint saja',
                  style: TextStyle(
                      fontSize: 12, color: context.simpulMuted)),
              Checkbox(value: taintOnly, onChanged: (v) => onTaintOnly(v ?? false)),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: onSubmit,
                child: const Text('Cari', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final danger = entry.verdict == 'deny' || entry.taint;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
          Row(
            children: [
              Expanded(
                child: Text(entry.tool,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text(entry.risk,
                  style: TextStyle(
                      fontSize: 11,
                      color: entry.risk == 'high'
                          ? context.simpulDanger
                          : context.simpulMuted)),
              const SizedBox(width: 8),
              Text(entry.verdict,
                  style: TextStyle(fontSize: 11, color: context.simpulMuted)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${entry.ts} \u00b7 ${entry.session}'
            '${entry.durationMs == null ? '' : ' \u00b7 ${entry.durationMs}ms'}'
            '${entry.taint ? ' \u00b7 TAINT' : ''}',
            style: TextStyle(color: context.simpulMuted, fontSize: 11),
          ),
          if (entry.args.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              entry.args.entries
                  .take(6)
                  .map((e) => '${e.key}: ${e.value}')
                  .join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.simpulMuted, fontSize: 11),
            ),
          ],
          if (entry.result != null) ...[
            const SizedBox(height: 4),
            Text(entry.result!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.simpulMuted, fontSize: 11)),
          ],
          if (entry.error != null) ...[
            const SizedBox(height: 4),
            Text('error: ${entry.error}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.simpulDanger, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}
