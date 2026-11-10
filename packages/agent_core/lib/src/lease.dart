/// Cross-subagent resource lease (NEW-07). An acquire is refused while
/// another owner still holds an unexpired lease; TTL expiry prevents
/// deadlocks when a subagent dies without releasing.
class LeaseManager {
  final Map<String, _LeaseRecord> _leases = {};

  /// Tries to take [resource] for [owner]. Re-acquiring by the same
  /// owner refreshes the lease. Returns false when another owner
  /// currently holds an unexpired lease.
  bool acquire(String resource, String owner, Duration ttl) {
    final now = DateTime.now();
    final existing = _leases[resource];
    if (existing != null &&
        existing.owner != owner &&
        now.isBefore(existing.expiresAt)) {
      return false;
    }
    _leases[resource] = _LeaseRecord(owner, now.add(ttl));
    return true;
  }

  /// Releases the lease; only the current owner may do so.
  bool release(String resource, String owner) {
    final existing = _leases[resource];
    if (existing == null || existing.owner != owner) return false;
    _leases.remove(resource);
    return true;
  }

  /// Active and expired leases, sorted by resource name.
  List<LeaseInfo> list() {
    final now = DateTime.now();
    final out = _leases.entries
        .map((e) => LeaseInfo(
              resource: e.key,
              owner: e.value.owner,
              expiresAt: e.value.expiresAt,
              expired: !now.isBefore(e.value.expiresAt),
            ))
        .toList();
    out.sort((a, b) => a.resource.compareTo(b.resource));
    return out;
  }
}

class _LeaseRecord {
  _LeaseRecord(this.owner, this.expiresAt);

  final String owner;
  final DateTime expiresAt;
}

/// Public snapshot of one lease as shown by [LeaseManager.list].
class LeaseInfo {
  const LeaseInfo({
    required this.resource,
    required this.owner,
    required this.expiresAt,
    required this.expired,
  });

  final String resource;
  final String owner;
  final DateTime expiresAt;
  final bool expired;
}
