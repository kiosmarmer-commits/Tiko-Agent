/// Versioned cache for expensive graph computations (NFR-S09, GRA-D04):
/// layout positions and cluster assignments are stored together with the
/// algorithm/model version, so a stale entry is never served after the
/// algorithm or vault changes.
abstract class GraphCacheStore {
  Future<void> saveGraphCache({
    required String kind,
    required String version,
    required Map<String, Object?> payload,
  });

  /// Returns the cached payload for [kind], or null when absent or stored
  /// under a different [version].
  Future<Map<String, Object?>?> loadGraphCache({
    required String kind,
    required String version,
  });
}
