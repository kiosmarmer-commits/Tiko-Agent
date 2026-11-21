import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'markdown_view.dart';

/// D1 GenUI — merender pesan asisten yang memuat blok ```genui menjadi
/// widget Flutter nyata. Segmen teks biasa tetap dirender sebagai teks
/// pilih-salin; blok yang tidak valid dibiarkan sebagai teks (fail-closed).
class GenUiMessageView extends StatelessWidget {
  const GenUiMessageView({super.key, required this.text, this.onAction});

  final String text;

  /// Dipanggil saat pengguna menekan tombol action atau mengirim form.
  /// `values` berisi nilai form (untuk action tombol polos: map kosong).
  final void Function(String actionId, Map<String, dynamic> values)? onAction;

  @override
  Widget build(BuildContext context) {
    final segments = splitGenUiSegments(text);
    final children = <Widget>[];
    for (final segment in segments) {
      if (segment is GenUiSpec) {
        children.add(GenUiView(spec: segment, onAction: onAction));
      } else if ((segment as String).trim().isNotEmpty) {
        children.add(TikoMarkdownView(text: segment));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }
}

/// Merender satu [GenUiSpec] menjadi widget.
class GenUiView extends StatefulWidget {
  const GenUiView({super.key, required this.spec, this.onAction});

  final GenUiSpec spec;
  final void Function(String actionId, Map<String, dynamic> values)? onAction;

  @override
  State<GenUiView> createState() => _GenUiViewState();
}

class _GenUiViewState extends State<GenUiView> {
  @override
  Widget build(BuildContext context) {
    try {
      return _buildNode(context, widget.spec.root);
    } on FormatException catch (e) {
      // Fail-closed: kerusakan tak terduga dirender sebagai pesan, bukan UI
      // setengah jadi.
      return Text(
        'genui: spesifikasi tidak dapat dirender (${e.message})',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    } catch (_) {
      return Text(
        'genui: spesifikasi tidak dapat dirender',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
  }

  Widget _buildNode(BuildContext context, GenUiNode node) {
    switch (node.type) {
      case 'section':
        final children = (node.data['children'] as List<GenUiNode>)
            .map((c) => _buildNode(context, c))
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              node.data['title'] as String,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              children[i],
            ],
          ],
        );
      case 'text':
        final style = node.data['style'] as String;
        final base = Theme.of(context).textTheme.bodyMedium;
        return SelectableText(
          node.data['text'] as String,
          style: switch (style) {
            'heading' =>
              Theme.of(context).textTheme.titleLarge?.copyWith(height: 1.3),
            'mono' => const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.4),
            _ => base?.copyWith(height: 1.4),
          },
        );
      case 'metric':
        final delta = node.data['delta'] as num?;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              node.data['label'] as String,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor),
            ),
            const SizedBox(width: 8),
            Text(
              node.data['value'].toString(),
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (delta != null) ...[
              const SizedBox(width: 6),
              Icon(
                delta >= 0 ? Icons.trending_up : Icons.trending_down,
                size: 16,
                color: delta >= 0 ? Colors.green : Colors.red,
              ),
            ],
          ],
        );
      case 'chart':
        return _buildChart(context, node);
      case 'form':
        return _GenUiForm(
          node: node,
          onSubmit: (values) =>
              widget.onAction?.call(node.data['id'] as String, values),
        );
      case 'actions':
        final buttons = node.data['buttons'] as List<Map<String, dynamic>>;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final b in buttons)
              b['style'] == 'danger'
                  ? OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor:
                            Theme.of(context).colorScheme.error,
                      ),
                      onPressed: () =>
                          widget.onAction?.call(b['id'] as String, const {}),
                      child: Text(b['label'] as String),
                    )
                  : FilledButton(
                      onPressed: () =>
                          widget.onAction?.call(b['id'] as String, const {}),
                      child: Text(b['label'] as String),
                    ),
          ],
        );
      case 'divider':
        return const Divider();
      default:
        // Parser menjamin tipe dikenal; jalur ini hanya pertahanan ekstra.
        return Text('genui: tipe tidak dikenal (${node.type})');
    }
  }

  Widget _buildChart(BuildContext context, GenUiNode node) {
    final points =
        (node.data['points'] as List<Map<String, dynamic>>).cast<Map<String, dynamic>>();
    final maxVal = points
        .map((p) => (p['value'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    final minVal = points
        .map((p) => (p['value'] as num).toDouble())
        .reduce((a, b) => a < b ? a : b);
    final span = (maxVal - minVal).abs() < 0.0001 ? 1.0 : maxVal - minVal;

    if (node.data['chart'] == 'line') {
      return SizedBox(
        height: 120,
        width: double.infinity,
        child: CustomPaint(
          painter: _LineChartPainter(
            values: points.map((p) => (p['value'] as num).toDouble()).toList(),
            min: minVal,
            span: span,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in points)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    p['label'].toString(),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: ((p['value'] as num).toDouble() - minVal) / span,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  p['value'].toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GenUiForm extends StatefulWidget {
  const _GenUiForm({required this.node, required this.onSubmit});

  final GenUiNode node;
  final void Function(Map<String, dynamic> values) onSubmit;

  @override
  State<_GenUiForm> createState() => _GenUiFormState();
}

class _GenUiFormState extends State<_GenUiForm> {
  final _controllers = <String, TextEditingController>{};
  final _values = <String, String>{};
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    for (final f in widget.node.data['fields'] as List<Map<String, dynamic>>) {
      final name = f['name'] as String;
      _controllers[name] =
          TextEditingController(text: f['initial'] as String? ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.node.data['title'] as String?;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) Text(title, style: Theme.of(context).textTheme.titleSmall),
          for (final f in widget.node.data['fields'] as List<Map<String, dynamic>>)
            _buildField(context, f),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () {
              if (_formKey.currentState?.validate() ?? false) {
                widget.onSubmit(Map<String, String>.from(_values));
              }
            },
            child: const Text('Kirim'),
          ),
        ],
      ),
    );
  }

  Widget _buildField(BuildContext context, Map<String, dynamic> f) {
    final name = f['name'] as String;
    final label = f['label'] as String;
    switch (f['kind'] as String) {
      case 'select':
        final options = (f['options'] as List).cast<String>();
        return DropdownButtonFormField<String>(
          decoration: InputDecoration(labelText: label),
          initialValue:
              _values[name] ?? (options.contains(_controllers[name]?.text) ? _controllers[name]!.text : null),
          items: [
            for (final o in options)
              DropdownMenuItem<String>(value: o, child: Text(o)),
          ],
          onChanged: (v) => setState(() => _values[name] = v ?? ''),
          validator: (v) =>
              (v == null || v.isEmpty) ? '$label wajib dipilih' : null,
        );
      case 'number':
        return TextFormField(
          controller: _controllers[name],
          decoration: InputDecoration(labelText: label),
          keyboardType: TextInputType.number,
          onChanged: (v) => _values[name] = v,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return '$label wajib diisi';
            if (num.tryParse(v.trim()) == null) return '$label harus angka';
            return null;
          },
        );
      case 'text':
      default:
        return TextFormField(
          controller: _controllers[name],
          decoration: InputDecoration(labelText: label),
          onChanged: (v) => _values[name] = v,
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? '$label wajib diisi' : null,
        );
    }
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.values,
    required this.min,
    required this.span,
    required this.color,
  });

  final List<double> values;
  final double min;
  final double span;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - (values[i] - min) / span * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.values.length != values.length;
}
