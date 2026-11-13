import 'dart:math' as math;
import 'dart:typed_data';

import 'graph_csr.dart';

/// Tunable physics parameters (GRA-17 sliders map onto these).
class ForceLayoutConfig {
  const ForceLayoutConfig({
    this.repulsion = 2400.0,
    this.springLength = 90.0,
    this.springStrength = 0.08,
    this.damping = 0.6,
    this.centerPull = 0.015,
    this.theta = 0.9,
    this.maxIterations = 300,
    this.sleepEnergy = 1e-3,
  });

  final double repulsion;
  final double springLength;
  final double springStrength;
  final double damping;
  final double centerPull;

  /// Barnes-Hut opening angle; larger is faster and less precise.
  final double theta;
  final int maxIterations;

  /// Simulation sleeps when mean kinetic energy drops below this (GRA-L03).
  final double sleepEnergy;
}

class LayoutResult {
  const LayoutResult({
    required this.iterations,
    required this.finalEnergy,
    required this.slept,
  });

  final int iterations;
  final double finalEnergy;
  final bool slept;
}

/// Force-directed layout with Barnes-Hut approximation, O(n log n) per
/// iteration (GRA-L01). Runs on [GraphCsr] and writes positions back into its
/// `Float32List` buffers (GRA-D01, GRA-L06).
///
/// With `warmStart: true` the existing positions are kept and the simulation
/// continues from them (GRA-L02); otherwise positions are seeded
/// deterministically on a golden-angle spiral.
abstract final class ForceLayout {
  static LayoutResult simulate(
    GraphCsr graph, {
    ForceLayoutConfig config = const ForceLayoutConfig(),
    bool warmStart = false,
  }) {
    final n = graph.nodeCount;
    if (n == 0) {
      return const LayoutResult(iterations: 0, finalEnergy: 0, slept: true);
    }
    final x = graph.positionsX;
    final y = graph.positionsY;
    if (!warmStart) {
      _seedSpiral(n, x, y);
    }
    _jitterDuplicates(n, x, y);

    final vx = Float32List(n);
    final vy = Float32List(n);
    final fx = Float32List(n);
    final fy = Float32List(n);

    var energy = double.infinity;
    var slept = false;
    var iteration = 0;
    const maxStep = 20.0;
    const tempFloor = 0.01;
    for (; iteration < config.maxIterations; iteration++) {
      final progress = iteration / config.maxIterations;
      final temp = math.max(tempFloor, maxStep * (1 - progress) * (1 - progress));
      final tree = _QuadTree.build(x, y);
      for (var i = 0; i < n; i++) {
        fx[i] = -config.centerPull * x[i];
        fy[i] = -config.centerPull * y[i];
        tree.applyRepulsion(i, x[i].toDouble(), y[i].toDouble(), config, fx, fy);
      }
      _applySprings(graph, x, y, config, fx, fy);

      var kinetic = 0.0;
      for (var i = 0; i < n; i++) {
        vx[i] = (vx[i] + fx[i]) * config.damping;
        vy[i] = (vy[i] + fy[i]) * config.damping;
        final speed = math.sqrt(vx[i] * vx[i] + vy[i] * vy[i]);
        if (speed > temp) {
          final scale = temp / speed;
          vx[i] *= scale;
          vy[i] *= scale;
        }
        x[i] += vx[i];
        y[i] += vy[i];
        kinetic += vx[i] * vx[i] + vy[i] * vy[i];
      }
      energy = kinetic / n;
      if (energy < config.sleepEnergy) {
        slept = true;
        break;
      }
    }
    return LayoutResult(
      iterations: iteration + 1,
      finalEnergy: energy,
      slept: slept,
    );
  }

  static void _seedSpiral(int n, Float32List x, Float32List y) {
    const golden = 2.399963229728653;
    for (var i = 0; i < n; i++) {
      final r = 10.0 * math.sqrt(i + 0.5);
      final a = i * golden;
      x[i] = r * math.cos(a);
      y[i] = r * math.sin(a);
    }
  }

  static void _jitterDuplicates(int n, Float32List x, Float32List y) {
    final seen = <double, int>{};
    for (var i = 0; i < n; i++) {
      final key = (x[i] * 1e4).roundToDouble() * 31 + (y[i] * 1e4).roundToDouble();
      final count = seen.putIfAbsent(key, () => 0);
      seen[key] = count + 1;
      if (count == 0) continue;
      final offset = 0.6180339887498949 * count % 1 - 0.5;
      x[i] += offset * 2 * (count + 1);
      y[i] += (2.399963229728653 * count % 1 - 0.5) * 2 * (count + 1);
    }
  }

  static void _applySprings(
    GraphCsr graph,
    Float32List x,
    Float32List y,
    ForceLayoutConfig config,
    Float32List fx,
    Float32List fy,
  ) {
    for (var src = 0; src < graph.nodeCount; src++) {
      for (var e = graph.offsets[src]; e < graph.offsets[src + 1]; e++) {
        final dst = graph.targets[e];
        var dx = x[dst] - x[src];
        var dy = y[dst] - y[src];
        var d = math.sqrt(dx * dx + dy * dy);
        if (d < 1e-6) {
          dx = 0.5;
          dy = 0.5;
          d = 0.7071067811865476;
        }
        final force = config.springStrength * (d - config.springLength);
        final ux = dx / d * force;
        final uy = dy / d * force;
        fx[src] += ux;
        fy[src] += uy;
        fx[dst] -= ux;
        fy[dst] -= uy;
      }
    }
  }
}

class _QuadTree {
  _QuadTree(this.cx, this.cy, this.half);

  final double cx;
  final double cy;
  final double half;

  static const _leaf = -1;
  static const _internal = -2;

  int point = _leaf;
  double mass = 0;
  double mx = 0;
  double my = 0;
  _QuadTree? nw;
  _QuadTree? ne;
  _QuadTree? sw;
  _QuadTree? se;

  static const _minHalf = 1e-9;

  static _QuadTree build(Float32List x, Float32List y) {
    var minX = x[0].toDouble();
    var maxX = minX;
    var minY = y[0].toDouble();
    var maxY = minY;
    for (var i = 1; i < x.length; i++) {
      if (x[i] < minX) minX = x[i];
      if (x[i] > maxX) maxX = x[i];
      if (y[i] < minY) minY = y[i];
      if (y[i] > maxY) maxY = y[i];
    }
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    final half = math.max(maxX - minX, maxY - minY) / 2 + 1.0;
    final root = _QuadTree(cx, cy, half);
    for (var i = 0; i < x.length; i++) {
      root.insert(i, x[i].toDouble(), y[i].toDouble(), x, y, 0);
    }
    root.summarize();
    return root;
  }

  void insert(
    int i,
    double px,
    double py,
    Float32List x,
    Float32List y,
    int depth,
  ) {
    if (point >= 0) {
      final existing = point;
      point = _internal;
      mass = 0;
      mx = 0;
      my = 0;
      _insertDown(existing, x[existing].toDouble(), y[existing].toDouble(), x, y, depth);
      _insertDown(i, px, py, x, y, depth);
      return;
    }
    if (point == _leaf && mass == 0) {
      point = i;
      mass = 1;
      mx = px;
      my = py;
      return;
    }
    point = _internal;
    _insertDown(i, px, py, x, y, depth);
  }

  void _insertDown(
    int i,
    double px,
    double py,
    Float32List x,
    Float32List y,
    int depth,
  ) {
    mass += 1;
    mx += px;
    my += py;
    if (half <= _minHalf || depth > 64) return;
    _childFor(px, py).insert(i, px, py, x, y, depth + 1);
  }

  void summarize() {
    if (mass > 0) {
      mx /= mass;
      my /= mass;
    }
    nw?.summarize();
    ne?.summarize();
    sw?.summarize();
    se?.summarize();
  }

  _QuadTree _childFor(double px, double py) {
    final east = px >= cx;
    final north = py >= cy;
    final childHalf = half / 2;
    if (north) {
      if (east) {
        return (ne ??= _QuadTree(cx + childHalf, cy + childHalf, childHalf));
      }
      return (nw ??= _QuadTree(cx - childHalf, cy + childHalf, childHalf));
    }
    if (east) {
      return (se ??= _QuadTree(cx + childHalf, cy - childHalf, childHalf));
    }
    return (sw ??= _QuadTree(cx - childHalf, cy - childHalf, childHalf));
  }

  void applyRepulsion(
    int i,
    double px,
    double py,
    ForceLayoutConfig config,
    Float32List fx,
    Float32List fy,
  ) {
    if (mass == 0) return;
    final dx = mx - px;
    final dy = my - py;
    final d2 = dx * dx + dy * dy;
    final d = math.sqrt(d2);
    final width = half * 2;
    final far = d > 0 && width / d < config.theta;
    if (point >= 0 || far || nw == null) {
      if (d < 1e-3) return;
      final f = config.repulsion / (d2 + 1.0);
      fx[i] -= f * dx / d;
      fy[i] -= f * dy / d;
      return;
    }
    nw?.applyRepulsion(i, px, py, config, fx, fy);
    ne?.applyRepulsion(i, px, py, config, fx, fy);
    sw?.applyRepulsion(i, px, py, config, fx, fy);
    se?.applyRepulsion(i, px, py, config, fx, fy);
  }
}
