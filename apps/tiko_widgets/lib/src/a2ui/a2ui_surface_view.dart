import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

/// Merender hasil apply sejumlah pesan A2UI menjadi satu tampilan surface
/// (pola yang dipakai chat inline: pesan tool diubah fence, host mengekstrak
/// dan mem-parse sebelum masuk sini).
class A2uiSurfaceStreamView extends StatefulWidget {
  const A2uiSurfaceStreamView({super.key, required this.messages, this.onAction});

  final List<A2uiMessage> messages;
  final void Function(
          String surfaceId, String actionName, Map<String, dynamic> payload)?
      onAction;

  @override
  State<A2uiSurfaceStreamView> createState() => _A2uiSurfaceStreamViewState();
}

class _A2uiSurfaceStreamViewState extends State<A2uiSurfaceStreamView> {
  A2uiSurfaceSet _set = A2uiSurfaceSet();

  @override
  void initState() {
    super.initState();
    _applyMessages();
  }

  @override
  void didUpdateWidget(A2uiSurfaceStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) _applyMessages();
  }

  void _applyMessages() {
    // Apply ke set scratch dulu (atomik): kegagalan di tengah batch tidak
    // menyisakan surface setengah jadi — dirender kartu error (fail-closed).
    final scratch = A2uiSurfaceSet();
    try {
      scratch.apply(widget.messages);
      _set = scratch;
    } on FormatException {
      _set = A2uiSurfaceSet();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_set.surfaces.isEmpty) {
      return const _ErrorCard(
        message: 'surface tidak dapat dirender (pesan tidak valid)',
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final surface in _set.surfaces.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: A2uiSurfaceView(
              surface: surface,
              onAction: widget.onAction,
            ),
          ),
      ],
    );
  }
}

/// Merender satu [A2uiSurface] (komponen tervalidasi + data model).
class A2uiSurfaceView extends StatelessWidget {
  const A2uiSurfaceView({super.key, required this.surface, this.onAction});

  final A2uiSurface surface;
  final void Function(
          String surfaceId, String actionName, Map<String, dynamic> payload)?
      onAction;

  dynamic _resolve(dynamic value) {
    if (value is Map && value.containsKey('@path')) {
      dynamic node = surface.dataModel;
      for (final segment in (value['@path'].toString())
          .split('/')
          .where((s) => s.isNotEmpty)) {
        if (node is Map && node.containsKey(segment)) {
          node = node[segment];
        } else {
          return null;
        }
      }
      return node;
    }
    return value;
  }


  @override
  Widget build(BuildContext context) {
    final root = surface.components['root'];
    if (root == null) {
      return const _ErrorCard(message: 'surface tanpa komponen root');
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: _buildComponent(context, surface.components, root),
    );
  }

  Widget _buildComponent(
    BuildContext context,
    Map<String, A2uiComponent> pool,
    A2uiComponent node,
  ) {
    final p = node.properties;
    switch (node.type) {
      case 'Row':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: _buildChildren(context, pool, node),
        );
      case 'Column':
        return Column(
          crossAxisAlignment:
              p['align'] == 'center' || p['align'] == 'end'
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: _buildChildren(context, pool, node),
        );
      case 'Card':
        final child = node.childId != null ? pool[node.childId] : null;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: child == null
                ? const SizedBox.shrink()
                : _buildComponent(context, pool, child),
          ),
        );
      case 'Divider':
        return const Divider();
      case 'Text':
        final text = _resolve(p['text'])?.toString() ?? '';
        final theme = Theme.of(context).textTheme;
        return SelectableText(
          text,
          style: switch (p['variant']) {
            'heading' => theme.titleLarge,
            'caption' => theme.bodySmall,
            'mono' => const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.4),
            _ => theme.bodyMedium?.copyWith(height: 1.4),
          },
        );
      case 'Icon':
        return Icon(_iconFor(p['name']?.toString() ?? 'info'));
      case 'Image':
        final src = p['src']?.toString() ?? '';
        return src.startsWith('http')
            ? const Icon(Icons.image_not_supported_outlined)
            : const SizedBox.shrink();
      case 'Button':
        final action = node.action;
        final label =
            _resolve(p['label'])?.toString() ?? (action?.name ?? 'Aksi');
        final variant = p['variant']?.toString() ?? 'primary';
        final danger = variant == 'danger';
        final button = danger
            ? FilledButton(
                style: FilledButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: action == null
                    ? null
                    : () => onAction?.call(
                        surface.surfaceId, action.name, action.payload),
                child: Text(label),
              )
            : FilledButton.tonal(
                onPressed: action == null
                    ? null
                    : () => onAction?.call(
                        surface.surfaceId, action.name, action.payload),
                child: Text(label),
              );
        return button;
      case 'TextField':
        return _A2uiTextField(
          label: _resolve(p['label'])?.toString() ?? '',
          initial: _resolve(p['value'])?.toString() ?? '',
          multiline: p['variant'] == 'multiline',
        );
      case 'CheckBox':
        return _A2uiCheckBox(
          label: _resolve(p['label'])?.toString() ?? '',
          initial: _resolve(p['value']) == true,
        );
      case 'ChoicePicker':
        return _A2uiChoicePicker(
          label: _resolve(p['label'])?.toString() ?? '',
          options: (p['options'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[],
          initial: _resolve(p['value'])?.toString(),
        );
      case 'Slider':
        return _A2uiSlider(
          label: _resolve(p['label'])?.toString() ?? '',
          min: (p['min'] as num?)?.toDouble() ?? 0,
          max: (p['max'] as num?)?.toDouble() ?? 100,
          initial: ((p['value'] as num?) ?? p['min'] as num? ?? 0).toDouble(),
        );
      case 'DateTimeInput':
        return _A2uiDateTimeInput(
          label: _resolve(p['label'])?.toString() ?? '',
        );
      case 'Metric':
        return _buildMetric(context, p);
      case 'Chart':
        return _buildChart(context, p);
      case 'KanbanCard':
        return _buildKanbanCard(context, p);
      default:
        return _ErrorCard(message: 'komponen tidak didukung (${node.type})');
    }
  }

  List<Widget> _buildChildren(
    BuildContext context,
    Map<String, A2uiComponent> pool,
    A2uiComponent node,
  ) {
    final out = <Widget>[];
    for (final ref in node.childIds) {
      final child = pool[ref];
      if (child == null) continue;
      out.add(_buildComponent(context, pool, child));
    }
    if (node.childId != null) {
      final child = pool[node.childId!];
      if (child != null) out.add(_buildComponent(context, pool, child));
    }
    return out;
  }

  Widget _buildMetric(BuildContext context, Map<String, dynamic> p) {
    final delta = p['delta'] as num?;
    final tone = p['tone']?.toString();
    final color = tone == 'error'
        ? Theme.of(context).colorScheme.error
        : tone == 'primary'
            ? Theme.of(context).colorScheme.primary
            : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          p['label']?.toString() ?? '',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).hintColor),
        ),
        const SizedBox(width: 8),
        Text(
          _resolve(p['value'])?.toString() ?? '',
          style: (Theme.of(context).textTheme.headlineSmall ?? const TextStyle())
              .copyWith(fontWeight: FontWeight.bold, color: color),
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
  }

  Widget _buildChart(BuildContext context, Map<String, dynamic> p) {
    final points =
        (p['points'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (points.isEmpty) return const SizedBox.shrink();
    final maxVal = points
        .map((x) => (x['value'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    final minVal = points
        .map((x) => (x['value'] as num).toDouble())
        .reduce((a, b) => a < b ? a : b);
    final span = (maxVal - minVal).abs() < 0.0001 ? 1.0 : maxVal - minVal;

    final kind = p['kind']?.toString() ?? 'bar';
    if (kind == 'line' || kind == 'area') {
      final values =
          points.map((x) => (x['value'] as num).toDouble()).toList();
      return SizedBox(
        height: 120,
        width: double.infinity,
        child: CustomPaint(
          painter: kind == 'area'
              ? _A2uiAreaPainter(
                  values: values,
                  min: minVal,
                  span: span,
                  color: Theme.of(context).colorScheme.primary,
                )
              : _A2uiLinePainter(
                  values: values,
                  min: minVal,
                  span: span,
                  color: Theme.of(context).colorScheme.primary,
                ),
        ),
      );
    }
    if (kind == 'donut') {
      final values =
          points.map((x) => (x['value'] as num).toDouble()).toList();
      return SizedBox(
        height: 140,
        child: Row(
          children: [
            SizedBox(
              width: 120,
              height: 140,
              child: CustomPaint(
                painter: _A2uiDonutPainter(
                  values: values,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final x in points)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${x['label']} · ${x['value']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final x in points)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    x['label'].toString(),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: ((x['value'] as num).toDouble() - minVal) / span,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  x['value'].toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildKanbanCard(BuildContext context, Map<String, dynamic> p) {
    final status = p['status']?.toString() ?? 'todo';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(
              switch (status) {
                'done' => Icons.check_circle_outline,
                'doing' => Icons.autorenew,
                _ => Icons.radio_button_unchecked,
              },
              size: 18,
              color: status == 'done'
                  ? Colors.green
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p['title']?.toString() ?? '',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              status,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _A2uiTextField extends StatefulWidget {
  const _A2uiTextField({
    required this.label,
    required this.initial,
    required this.multiline,
  });

  final String label;
  final String initial;
  final bool multiline;

  @override
  State<_A2uiTextField> createState() => _A2uiTextFieldState();
}

class _A2uiTextFieldState extends State<_A2uiTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      maxLines: widget.multiline ? 3 : 1,
      decoration: InputDecoration(
        labelText: widget.label.isEmpty ? null : widget.label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _A2uiCheckBox extends StatefulWidget {
  const _A2uiCheckBox({required this.label, required this.initial});

  final String label;
  final bool initial;

  @override
  State<_A2uiCheckBox> createState() => _A2uiCheckBoxState();
}

class _A2uiCheckBoxState extends State<_A2uiCheckBox> {
  late bool _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(widget.label),
      value: _value,
      onChanged: (v) => setState(() => _value = v ?? false),
    );
  }
}

class _A2uiChoicePicker extends StatefulWidget {
  const _A2uiChoicePicker({
    required this.label,
    required this.options,
    this.initial,
  });

  final String label;
  final List<Map<String, dynamic>> options;
  final String? initial;

  @override
  State<_A2uiChoicePicker> createState() => _A2uiChoicePickerState();
}

class _A2uiChoicePickerState extends State<_A2uiChoicePicker> {
  String? _value;

  @override
  Widget build(BuildContext context) {
    final groupValue = _value ?? widget.initial;
    return RadioGroup<String>(
      groupValue: groupValue,
      onChanged: (v) => setState(() => _value = v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.label.isNotEmpty) Text(widget.label),
          for (final o in widget.options)
            RadioListTile<String>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(o['label']?.toString() ?? ''),
              value: o['value']?.toString() ?? '',
            ),
        ],
      ),
    );
  }
}

class _A2uiSlider extends StatefulWidget {
  const _A2uiSlider({
    required this.label,
    required this.min,
    required this.max,
    required this.initial,
  });

  final String label;
  final double min;
  final double max;
  final double initial;

  @override
  State<_A2uiSlider> createState() => _A2uiSliderState();
}

class _A2uiSliderState extends State<_A2uiSlider> {
  late double _value = widget.initial.clamp(widget.min, widget.max).toDouble();

  @override
  Widget build(BuildContext context) {
    final max = widget.max > widget.min ? widget.max : widget.min + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${widget.label} (${_value.toStringAsFixed(0)})'),
        Slider(
          min: widget.min,
          max: max,
          divisions: (max - widget.min).clamp(1, 100).round(),
          value: _value.clamp(widget.min, max).toDouble(),
          onChanged: (v) => setState(() => _value = v),
        ),
      ],
    );
  }
}

class _A2uiDateTimeInput extends StatelessWidget {
  const _A2uiDateTimeInput({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.event_outlined),
        title: Text(label.isEmpty ? 'Waktu' : label),
        subtitle: const Text('belum diatur'),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      'a2ui: $message',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
  }
}

IconData _iconFor(String name) => switch (name) {
      'mail' => Icons.mail_outline,
      'wifi' => Icons.wifi,
      'cpu' => Icons.memory,
      'disk' => Icons.storage,
      'check' => Icons.check,
      'warning' => Icons.warning_amber_outlined,
      'error' => Icons.error_outline,
      'info' => Icons.info_outline,
      'settings' => Icons.settings_outlined,
      'search' => Icons.search,
      'star' => Icons.star_outline,
      'person' => Icons.person_outline,
      'home' => Icons.home_outlined,
      'folder' => Icons.folder_outlined,
      'download' => Icons.download_outlined,
      'refresh' => Icons.refresh,
      _ => Icons.circle,
    };

class _A2uiLinePainter extends CustomPainter {
  _A2uiLinePainter({
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
  bool shouldRepaint(covariant _A2uiLinePainter oldDelegate) =>
      oldDelegate.values.length != values.length;
}

/// Area chart: isian di bawah kurva + garis atas (warisan _A2uiLinePainter).
class _A2uiAreaPainter extends CustomPainter {
  _A2uiAreaPainter({
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
    canvas.drawPath(
        path..
          lineTo(size.width, size.height)..lineTo(0, size.height)..close(),
        Paint()
          ..color = color.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _A2uiAreaPainter oldDelegate) =>
      oldDelegate.values.length != values.length;
}

/// Donut chart: bagian proporsional terhadap |value| (min 1 segmen tetap
/// digambar bila total 0); warna: primary + gradasi hue sederhana.
class _A2uiDonutPainter extends CustomPainter {
  _A2uiDonutPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius =
        (size.height < size.width ? size.height : size.width) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final total = values.fold(0.0, (a, b) => a + b.abs());
    final stroke = (radius * 0.25).clamp(6.0, 18.0);
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);
    if (total <= 0) {
      canvas.drawArc(rect, 0, 6.2832, false,
          Paint()
            ..color = Colors.grey.shade300
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);
      return;
    }
    var start = -3.14159 / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = 6.2832 * values[i].abs() / total;
      final hue = (HSLColor.fromColor(color).hue + i * 47.0) % 360;
      final segment = HSLColor.fromAHSL(
              1, hue, 0.6, (HSLColor.fromColor(color).lightness + i * 0.05) % 1.0)
          .toColor();
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = segment
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _A2uiDonutPainter oldDelegate) =>
      oldDelegate.values.length != values.length;
}

/// Merender satu surface dari bentuk snapshot REST (`/v1/surfaces/<id>`):
/// komponen flat wire + data model di-parse ulang secara fail-closed —
/// record yang di-opa/tampered akan jatuh ke kartu error, bukan crash.
class A2uiSurfaceRecordView extends StatelessWidget {
  const A2uiSurfaceRecordView({super.key, required this.record, this.onAction});

  final Map<String, dynamic> record;

  final void Function(
          String surfaceId, String actionName, Map<String, dynamic> payload)?
      onAction;

  @override
  Widget build(BuildContext context) {
    try {
      final surfaceId = record['surfaceId']?.toString() ?? '';
      final rawComponents = record['components'];
      if (surfaceId.isEmpty || rawComponents is! List || rawComponents.isEmpty) {
        return const _ErrorCard(message: 'record surface tidak lengkap');
      }
      final set = A2uiSurfaceSet();
      set.apply(parseA2uiMessages({
        'version': a2uiVersion,
        'createSurface': {
          'surfaceId': surfaceId,
          if (record['catalogId'] is String) 'catalogId': record['catalogId'],
          'components': rawComponents,
          if (record['dataModel'] is Map) 'dataModel': record['dataModel'],
        },
      }));
      final surface = set.surface(surfaceId);
      if (surface == null) {
        return const _ErrorCard(message: 'surface tidak dapat dirender');
      }
      return A2uiSurfaceView(surface: surface, onAction: onAction);
    } on FormatException catch (error) {
      return _ErrorCard(
          message: 'surface tidak dapat dirender: ${error.message}');
    } catch (error) {
      return _ErrorCard(message: 'surface tidak dapat dirender: $error');
    }
  }
}
