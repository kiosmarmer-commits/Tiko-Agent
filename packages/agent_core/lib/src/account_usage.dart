// Hermes parity: `agent/account_usage_cache.py` — apa yang diketahui
// `model.options` tentang usage langganan tanpa menunggu jaringan.
//
// Window usage datang dari API provider, jadi pembaca (picker, `/usage`)
// membaca cache ini dan meminta refresh latar belakang, bukan fetch inline.
// Setiap fetch mendarat di sini supaya pembaca maksimal satu turn atau satu
// interval refresh di belakang.
//
// Aturan integritas (di-copy mentah dari Hermes):
//   - snapshot TANPA window tidak pernah disimpan — fetch gagal/kosong tidak
//     boleh menghapus snapshot yang lebih fresh;
//   - fetch yang MULAI sebelum snapshot tersimpan terfresh tidak boleh
//     menggantikannya (late-fetch guard, `startedMonotonic`);
//   - snapshot lebih tua dari [snapshotStaleAfterS] dirender sebagai state
//     `unknown`, bukan gauge percaya-diri — angka basah yang dilaporkan
//     sebagai live bisa salah-label akun yang sudah pulih (atau memburuk);
//   - refresh di-throttle per slot provider: fetch gagal/kosong tetap dihitung
//     sebagai satu percobaan, jadi kredensial mati tidak di-ask ulang di
//     setiap pembukaan.

/// Window usage satu akun provider.
class AccountUsageWindow {
  const AccountUsageWindow({
    required this.label,
    this.usedPercent,
    this.resetAt,
    this.detail,
    this.scope = accountUsageScopeAccount,
  });

  final String label;

  /// 0..100, null bila provider tidak melaporkan persentase.
  final double? usedPercent;
  final DateTime? resetAt;
  final String? detail;

  /// `account`: menghabiskan window ini = login habis. `model`: window hanya
  /// membat satu keluarga model dan tidak pernah menyiratkan akun habis.
  final String scope;

  Map<String, dynamic> toJson() => {
        'label': label,
        if (usedPercent != null) 'used_percent': usedPercent,
        if (resetAt != null) 'reset_at': resetAt!.toIso8601String(),
        if (detail != null) 'detail': detail,
        'scope': scope,
      };

  static AccountUsageWindow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    if (label is! String || label.isEmpty) return null;
    final reset = raw['reset_at'];
    DateTime? resetAt;
    if (reset is String && reset.isNotEmpty) {
      resetAt = DateTime.tryParse(reset);
    }
    final scope = raw['scope'];
    return AccountUsageWindow(
      label: label,
      usedPercent: raw['used_percent'] is num
          ? (raw['used_percent'] as num).toDouble()
          : null,
      resetAt: resetAt,
      detail: raw['detail'] is String ? raw['detail'] as String : null,
      scope: scope == accountUsageScopeModel
          ? accountUsageScopeModel
          : accountUsageScopeAccount,
    );
  }
}

const accountUsageScopeAccount = 'account';
const accountUsageScopeModel = 'model';

/// Snapshot usage langganan satu provider pada satu waktu fetch.
class AccountUsageSnapshot {
  const AccountUsageSnapshot({
    required this.provider,
    required this.source,
    required this.fetchedAt,
    this.title = 'Account limits',
    this.plan,
    this.windows = const [],
    this.details = const [],
    this.unavailableReason,
    this.identity,
  });

  final String provider;
  final String source;
  final DateTime fetchedAt;
  final String title;
  final String? plan;
  final List<AccountUsageWindow> windows;
  final List<String> details;
  final String? unavailableReason;

  /// Identitas akun stabil (bukan rahasia) dari kredensial yang dipakai
  /// fetch; null = fetcher tidak bisa membedakan akun.
  final String? identity;

  bool get available =>
      (windows.isNotEmpty || details.isNotEmpty) &&
      (unavailableReason == null || unavailableReason!.isEmpty);

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'source': source,
        'fetched_at': fetchedAt.toIso8601String(),
        'title': title,
        if (plan != null) 'plan': plan,
        'windows': [for (final w in windows) w.toJson()],
        'details': details,
        if (unavailableReason != null) 'unavailable_reason': unavailableReason,
        if (identity != null) 'identity': identity,
      };

  static AccountUsageSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final provider = raw['provider'];
    final source = raw['source'];
    final fetched = raw['fetched_at'];
    if (provider is! String ||
        provider.isEmpty ||
        source is! String ||
        source.isEmpty) {
      return null;
    }
    final fetchedAt = DateTime.tryParse(fetched is String ? fetched : '');
    if (fetchedAt == null) return null;
    return AccountUsageSnapshot(
      provider: provider,
      source: source,
      fetchedAt: fetchedAt,
      title: raw['title'] is String ? raw['title'] as String : 'Account limits',
      plan: raw['plan'] is String ? raw['plan'] as String : null,
      windows: [
        for (final w in (raw['windows'] as List? ?? const []))
          ?AccountUsageWindow.fromJson(w),
      ],
      details: [
        for (final d in (raw['details'] as List? ?? const []))
          if (d is String) d,
      ],
      unavailableReason: raw['unavailable_reason'] is String
          ? raw['unavailable_reason'] as String
          : null,
      identity: raw['identity'] is String ? raw['identity'] as String : null,
    );
  }
}

/// Fetcher usage akun per provider (plugin/host). Return null bila tidak
/// tersedia — snapshot tanpa window tidak pernah disimpan.
typedef AccountUsageFetcher = Future<AccountUsageSnapshot?> Function(
  String provider,
);

/// Cache snapshot usage akun (per provider). Dart per-isolate tunggal:
/// guard in-flight cukup set sederhana; throttle `monotonic` memakai
/// `Stopwatch`-style detik yang diinjeksikan agar bisa dites.
class AccountUsageCache {
  AccountUsageCache({
    this.refreshAfterS = accountUsageRefreshAfterS,
    this.staleAfterS = accountUsageSnapshotStaleAfterS,
  });

  /// Pembaca yang dibuka lagi dalam rentang ini memakai yang sudah ada:
  /// window usage bergerak dalam menit, bukan detik.
  final double refreshAfterS;

  /// Snapshot lebih tua dari ini dirender `unknown`, bukan gauge live.
  final double staleAfterS;

  final Map<String, AccountUsageSnapshot> _snapshots = {};
  final Map<String, double> _started = {};
  final Map<String, double> _lastTry = {};
  final Set<String> _inflight = <String>{};
  final Map<String, AccountUsageFetcher> _fetchers = {};

  static String slotKey(String provider, {String? identityId}) =>
      '${provider.trim().toLowerCase()}|${(identityId ?? '').trim()}';

  /// Daftarkan fetcher usage akun untuk [provider] (host/plugin).
  void registerFetcher(String provider, AccountUsageFetcher fetcher) =>
      _fetchers[provider.trim().toLowerCase()] = fetcher;

  /// Apakah [provider] bisa melaporkan window usage sama sekali.
  bool hasFetcher(String provider) =>
      _fetchers.containsKey(provider.trim().toLowerCase());

  /// Simpan satu hasil fetch. Snapshot tanpa window tidak pernah disimpan;
  /// fetch yang mulai sebelum snapshot tersimpan terfresh tidak menggantikan
  /// (late-fetch guard). Snapshot tersimpan di slot provider-wide DAN slot
  /// identitasnya (bila fetcher mengidentifikasi akun).
  void remember(
    String? provider,
    AccountUsageSnapshot? snapshot, {
    String? identityId,
    double? startedMonotonic,
  }) {
    if (provider == null ||
        provider.trim().isEmpty ||
        snapshot == null ||
        snapshot.windows.isEmpty) {
      return;
    }
    final started = startedMonotonic ?? _now();
    final identity = snapshot.identity;
    final targets = <String>{};
    if (identityId == null || identityId.isEmpty) {
      // Fetch per-turn / per-`/usage`: slot provider-wide (gauge akun tunggal)
      // plus slot identitasnya bila fetcher mengidentifikasi akun.
      targets.add(slotKey(provider));
      if (identity != null && identity.isNotEmpty) {
        targets.add(slotKey(provider, identityId: identity));
      }
    } else {
      // Fetch per-kredensial: snapshot satu entri pool tidak boleh berpura-
      // pura menjadi gauge provider-wide.
      targets.add(slotKey(provider, identityId: identity ?? identityId));
    }
    for (final key in targets) {
      final prevStarted = _started[key];
      if (prevStarted != null && prevStarted > started) continue;
      _snapshots[key] = snapshot;
      _started[key] = started;
    }
  }

  /// Baca snapshot tersimpan (slot provider-wide atau slot identitas).
  AccountUsageSnapshot? cached(String provider, {String? identityId}) =>
      _snapshots[slotKey(provider, identityId: identityId)];

  /// Snapshot terfresh milik provider mana pun (untuk rendering `/usage`).
  List<AccountUsageSnapshot> cachedAll() {
    final seen = <String, AccountUsageSnapshot>{};
    _snapshots.forEach((key, snap) {
      final existing = seen[snap.provider];
      if (existing == null || existing.fetchedAt.isBefore(snap.fetchedAt)) {
        seen[snap.provider] = snap;
      }
    });
    return seen.values.toList(growable: false);
  }

  /// True bila [snapshot] terlalu tua untuk dirender sebagai gauge live
  /// (umur negatif — jam berubah mundur — juga dianggap basah).
  bool snapshotIsStale(AccountUsageSnapshot? snapshot, {DateTime? now}) {
    if (snapshot == null) return true;
    final at = now ?? DateTime.now();
    final age = at.difference(snapshot.fetchedAt).inMilliseconds / 1000.0;
    return age < 0 || age > staleAfterS;
  }

  /// Ambil hak refresh untuk slot [key]: gagal bila masih in-flight atau
  /// dicoba terlalu dini. Fetch gagal/kosong tetap dihitung (dipanggil dari
  /// [claimRefresh] sebelum jalan).
  bool claimRefresh(String key, double now) {
    if (_inflight.contains(key)) return false;
    final last = _lastTry[key];
    if (last != null && now - last < refreshAfterS) return false;
    _inflight.add(key);
    _lastTry[key] = now;
    return true;
  }

  void releaseRefresh(String key) => _inflight.remove(key);

  /// Refresh latar-belakang bila slot sudah jatuh tempo (throttle, in-flight
  /// guard). Fetcher harus terdaftar; tanpa fetcher ini no-op. Fail-open:
  /// error fetch ditelan — cache tetap berisi snapshot lama.
  Future<void> refreshIfDue(String provider, {double Function()? now}) async {
    final slug = provider.trim().toLowerCase();
    final fetcher = _fetchers[slug];
    if (fetcher == null) return;
    final at = now?.call() ?? _now();
    final key = slotKey(slug);
    if (!claimRefresh(key, at)) return;
    try {
      final snap = await fetcher(slug);
      remember(slug, snap, startedMonotonic: at);
    } catch (_) {
      // fetch gagal: tetap dihitung sebagai percobaan, snapshot lama dipertahankan.
    } finally {
      releaseRefresh(key);
    }
  }

  double _now() => DateTime.now().microsecondsSinceEpoch / 1e6;
}

/// Hermes `account_usage_cache.REFRESH_AFTER_S`.
const double accountUsageRefreshAfterS = 120.0;

/// Hermes `account_usage_cache.SNAPSHOT_STALE_AFTER_S` (15 menit).
const double accountUsageSnapshotStaleAfterS = 15 * 60.0;

/// Render window usage akun menjadi baris `/usage` yang jujur: snapshot
/// basah dirender `tidak diketahui (usang)`, snapshot tanpa window tidak
/// pernah tampil sebagai gauge.
List<String> formatAccountUsageLines(
  List<AccountUsageSnapshot> snapshots, {
  DateTime? now,
  bool Function(AccountUsageSnapshot)? isStale,
}) {
  final lines = <String>[];
  for (final snap in snapshots) {
    if (!snap.available) {
      if (snap.unavailableReason != null && snap.unavailableReason!.isNotEmpty) {
        lines.add('${snap.provider}: tidak tersedia (${snap.unavailableReason})');
      }
      continue;
    }
    final stale = isStale?.call(snap) ??
        (now == null
            ? false
            : now.difference(snap.fetchedAt).inMilliseconds / 1000.0 < 0 ||
                now.difference(snap.fetchedAt).inMilliseconds / 1000.0 >
                    accountUsageSnapshotStaleAfterS);
    final head = stale
        ? '${snap.provider} (${snap.source}, usang — tidak diketahui)'
        : '${snap.provider} (${snap.source})';
    lines.add(head);
    for (final w in snap.windows) {
      final pct = w.usedPercent == null
          ? 'n/a'
          : '${w.usedPercent!.toStringAsFixed(1)}%';
      final reset = w.resetAt == null ? '' : ', reset ${w.resetAt!.toIso8601String()}';
      final scope = w.scope == accountUsageScopeModel ? ' [model]' : '';
      lines.add('- ${w.label}: $pct$reset$scope');
    }
    for (final d in snap.details) {
      lines.add('- $d');
    }
  }
  return lines;
}
