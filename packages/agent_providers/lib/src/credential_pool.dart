/// Named credential pool for one provider (Hermes-parity: credential pools
/// rotate multiple keys of the same provider on auth/rate-limit failures).
class CredentialPool {
  CredentialPool(Iterable<String> keys)
      : _keys = keys.where((k) => k.trim().isNotEmpty).toList(growable: false) {
    if (_keys.isEmpty) {
      throw ArgumentError('CredentialPool butuh minimal satu key');
    }
  }

  final List<String> _keys;
  int _index = 0;
  int _rotations = 0;

  int get length => _keys.length;
  int get rotations => _rotations;

  /// Key currently in use.
  String get current => _keys[_index];

  /// Rotates to the next key (round-robin). Returns the new current key.
  String reportFailure() {
    _index = (_index + 1) % _keys.length;
    _rotations++;
    return current;
  }

  void reportSuccess() {
    // Sticky strategy: the current key stays until it fails.
  }
}
