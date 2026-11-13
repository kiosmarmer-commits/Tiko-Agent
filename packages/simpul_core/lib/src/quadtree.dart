import 'dart:typed_data';

/// Point quadtree over node positions for viewport culling and hover/click
/// hit-testing (GRA-R02). Deterministic: region results are sorted by node id
/// and hit-test ties resolve to the smallest node id.
class QuadtreeIndex {
  QuadtreeIndex._(this._root, this._x, this._y);

  final _QNode _root;
  final Float32List _x;
  final Float32List _y;

  static const _capacity = 8;

  static QuadtreeIndex build(Float32List x, Float32List y) {
    var minX = 0.0, minY = 0.0, maxX = 1.0, maxY = 1.0;
    if (x.isNotEmpty) {
      minX = maxX = x[0].toDouble();
      minY = maxY = y[0].toDouble();
      for (var i = 1; i < x.length; i++) {
        if (x[i] < minX) minX = x[i].toDouble();
        if (x[i] > maxX) maxX = x[i].toDouble();
        if (y[i] < minY) minY = y[i].toDouble();
        if (y[i] > maxY) maxY = y[i].toDouble();
      }
      if (maxX - minX < 1e-6) maxX = minX + 1e-6;
      if (maxY - minY < 1e-6) maxY = minY + 1e-6;
    }
    final tree = QuadtreeIndex._(_QNode(minX, minY, maxX, maxY), x, y);
    for (var i = 0; i < x.length; i++) {
      tree._insert(i, x[i].toDouble(), y[i].toDouble());
    }
    return tree;
  }

  void _insert(int id, double px, double py) {
    var node = _root;
    while (true) {
      final children = node.children;
      if (children == null) {
        if (node.points.length >= _capacity && _subdivide(node)) continue;
        node.points.add(id);
        return;
      }
      node = children[_childIndex(node, px, py)];
    }
  }

  /// Splits a leaf into four quadrants; returns false when every point would
  /// land in the same quadrant (identical positions), leaving the leaf as is.
  bool _subdivide(_QNode node) {
    final midX = (node.minX + node.maxX) / 2;
    final midY = (node.minY + node.maxY) / 2;
    final children = [
      _QNode(node.minX, node.minY, midX, midY),
      _QNode(midX, node.minY, node.maxX, midY),
      _QNode(node.minX, midY, midX, node.maxY),
      _QNode(midX, midY, node.maxX, node.maxY),
    ];
    final buckets = [for (var i = 0; i < 4; i++) <int>[]];
    for (final id in node.points) {
      buckets[_childIndex(
        node,
        _x[id].toDouble(),
        _y[id].toDouble(),
      )].add(id);
    }
    for (final bucket in buckets) {
      if (bucket.length == node.points.length) return false;
    }
    node.children = children;
    for (var c = 0; c < 4; c++) {
      children[c].points = buckets[c];
    }
    node.points = [];
    return true;
  }

  int _childIndex(_QNode node, double px, double py) {
    final east = px >= (node.minX + node.maxX) / 2;
    final north = py >= (node.minY + node.maxY) / 2;
    return switch ((east, north)) {
      (false, false) => 0,
      (true, false) => 1,
      (false, true) => 2,
      (true, true) => 3,
    };
  }

  /// Node ids whose position lies inside the closed rectangle, sorted.
  List<int> queryRegion(double minX, double minY, double maxX, double maxY) {
    final out = <int>[];
    _collect(_root, minX, minY, maxX, maxY, out);
    out.sort();
    return out;
  }

  void _collect(
    _QNode node,
    double minX,
    double minY,
    double maxX,
    double maxY,
    List<int> out,
  ) {
    if (node.maxX < minX || node.minX > maxX) return;
    if (node.maxY < minY || node.minY > maxY) return;
    for (final id in node.points) {
      final px = _x[id].toDouble();
      final py = _y[id].toDouble();
      if (px >= minX && px <= maxX && py >= minY && py <= maxY) {
        out.add(id);
      }
    }
    final children = node.children;
    if (children != null) {
      for (final child in children) {
        _collect(child, minX, minY, maxX, maxY, out);
      }
    }
  }

  /// Nearest node to (px, py) within [radius], or null. Ties pick the
  /// smallest node id.
  int? hitTest(double px, double py, {double radius = 10}) {
    final best = <double>[-1, radius * radius];
    _hitSearch(_root, px, py, best);
    final id = best[0].toInt();
    return id < 0 ? null : id;
  }

  void _hitSearch(_QNode node, double px, double py, List<double> best) {
    final closestX = px.clamp(node.minX, node.maxX).toDouble();
    final closestY = py.clamp(node.minY, node.maxY).toDouble();
    final dx = px - closestX;
    final dy = py - closestY;
    if (dx * dx + dy * dy > best[1]) return;

    for (final id in node.points) {
      final ddx = px - _x[id];
      final ddy = py - _y[id];
      final distSq = ddx * ddx + ddy * ddy;
      final currentBest = best[0].toInt();
      if (distSq < best[1] ||
          (distSq == best[1] && (currentBest < 0 || id < currentBest))) {
        best[0] = id.toDouble();
        best[1] = distSq;
      }
    }
    final children = node.children;
    if (children != null) {
      for (final child in children) {
        _hitSearch(child, px, py, best);
      }
    }
  }
}

class _QNode {
  _QNode(this.minX, this.minY, this.maxX, this.maxY);

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  List<_QNode>? children;
  List<int> points = [];
}
