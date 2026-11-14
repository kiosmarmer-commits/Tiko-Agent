import 'graph_cache.dart';
import 'vault_index.dart';

/// Web/ffi-less stub for the SQLite backend: [SqliteVaultIndex.tryOpen]
/// always returns null so callers fall back to [JsonVaultIndex]
/// (same graceful-degradation contract as on a host without libsqlite3).
class SqliteVaultIndex implements VaultIndex, GraphCacheStore {
  SqliteVaultIndex._();

  static SqliteVaultIndex? tryOpen(String dbPath, {List<int>? vaultKey}) => null;

  static bool get sqlcipherAvailable => false;

  static bool isFileEncrypted(String path) => false;

  static bool encryptFileInPlace(String dbPath, List<int> vaultKey) => false;

  static void decryptFileInPlace(String dbPath, List<int> vaultKey) {
    throw UnsupportedError('SqliteVaultIndex tidak tersedia di platform ini');
  }

  @override
  Future<void> replaceAll(List<IndexedNote> notes) => _unsupported();

  @override
  Future<void> upsert(List<IndexedNote> notes) => _unsupported();

  @override
  Future<void> removePaths(List<String> paths) => _unsupported();

  @override
  Future<Map<String, ({int mtimeNs, int sizeBytes, String hash})>> stats() =>
      _unsupported();

  @override
  Future<List<SearchHit>> search(String query, {int limit = 20}) =>
      _unsupported();

  @override
  Future<List<String>> backlinks(String notePath) => _unsupported();

  @override
  Future<IndexedNote?> noteByPath(String path) => _unsupported();

  @override
  Future<Map<String, List<String>>> tagsOf(Set<String> paths) =>
      _unsupported();

  @override
  Future<VaultHealthReport> health() => _unsupported();

  @override
  Future<void> saveGraphCache({
    required String kind,
    required String version,
    required Map<String, Object?> payload,
  }) =>
      _unsupported();

  @override
  Future<Map<String, Object?>?> loadGraphCache({
    required String kind,
    required String version,
  }) =>
      _unsupported();

  @override
  Future<void> close() async {}

  Never _unsupported() =>
      throw UnsupportedError('SqliteVaultIndex tidak tersedia di platform ini');
}
