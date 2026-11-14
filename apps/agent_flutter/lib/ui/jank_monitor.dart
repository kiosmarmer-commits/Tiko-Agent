import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

/// Frame-time recorder and jank detector (NFR-O01, developer mode).
///
/// Collects recent frame build+raster times via the scheduler timings
/// callback; a frame is "jank" when it exceeds two vsync budgets (>34 ms).
class JankMonitor {
  JankMonitor._();

  static final JankMonitor instance = JankMonitor._();

  static const int windowSize = 120;
  static const double jankThresholdMs = 34.0;

  final List<double> _frameMs = [];
  int _jankCount = 0;
  bool _listening = false;
  final List<VoidCallback> _listeners = [];

  bool get listening => _listening;
  int get jankCount => _jankCount;
  List<double> get frameMs => List.unmodifiable(_frameMs);

  /// p95 frame time over the recorded window, in ms.
  double get p95Ms {
    if (_frameMs.isEmpty) return 0;
    final sorted = [..._frameMs]..sort();
    final idx = (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  void start() {
    if (_listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _notify();
  }

  void stop() {
    if (!_listening) return;
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _notify();
  }

  void reset() {
    _frameMs.clear();
    _jankCount = 0;
    _notify();
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      recordFrameMs(timing.totalSpan.inMicroseconds / 1000.0);
    }
    _notify();
  }

  /// Records one frame duration in ms (also the test seam).
  void recordFrameMs(double ms) {
    _frameMs.add(ms);
    if (_frameMs.length > windowSize) _frameMs.removeAt(0);
    if (ms > jankThresholdMs) _jankCount++;
  }
}

/// Small overlay badge showing live frame stats; visible only while the
/// monitor is running (developer mode toggle, NFR-O01).
class JankBadge extends StatefulWidget {
  const JankBadge({super.key});

  @override
  State<JankBadge> createState() => _JankBadgeState();
}

class _JankBadgeState extends State<JankBadge> {
  @override
  void initState() {
    super.initState();
    JankMonitor.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    JankMonitor.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final monitor = JankMonitor.instance;
    if (!monitor.listening) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border.all(color: context.simpulBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'frame p95 ${monitor.p95Ms.toStringAsFixed(1)} ms \u2022 '
        'jank ${monitor.jankCount}',
        style: TextStyle(
          fontSize: 11,
          color: monitor.jankCount > 0
              ? context.simpulWarn
              : context.simpulMuted,
        ),
      ),
    );
  }
}
