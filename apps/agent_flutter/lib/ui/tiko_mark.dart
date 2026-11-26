import 'package:flutter/material.dart';

/// Small, shared Tiko mark used by the app shell and chat empty state.
class TikoMark extends StatelessWidget {
  const TikoMark({super.key, this.size = 22, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _TikoMarkPainter(color));
}

class _TikoMarkPainter extends CustomPainter {
  const _TikoMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 14;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.65 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final nodes = <Offset>[
      const Offset(7, 2.5),
      const Offset(3.5, 6),
      const Offset(7, 6),
      const Offset(10.5, 6),
      const Offset(7, 11.5),
    ].map((point) => Offset(point.dx * scale, point.dy * scale)).toList();

    for (final index in const [(0, 2), (1, 2), (2, 3), (2, 4)]) {
      canvas.drawLine(nodes[index.$1], nodes[index.$2], stroke);
    }
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final node in nodes) {
      canvas.drawCircle(node, 1.25 * scale, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _TikoMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
