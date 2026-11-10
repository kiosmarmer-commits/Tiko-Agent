/// Ringkasan routing dan MCP dari payload endpoint /v1/status, dipakai
/// kartu Dashboard. Kelas murni tanpa I/O supaya parsing bisa diuji.
class RoutingSummary {
  const RoutingSummary({
    required this.defaultProvider,
    required this.tiers,
    required this.providers,
    required this.health,
    required this.mcpServers,
  });

  factory RoutingSummary.fromStatus(Map<String, dynamic>? status) {
    final routing =
        status?['routing'] as Map<String, dynamic>? ?? const {};
    final tiersRaw = routing['tiers'];
    final tiers = <String, String>{
      if (tiersRaw is Map)
        for (final e in tiersRaw.entries) '${e.key}': '${e.value}',
    };
    final healthRaw = routing['health'];
    final health = <String, Map<String, dynamic>>{};
    if (healthRaw is Map) {
      for (final e in healthRaw.entries) {
        if (e.value is Map) {
          health['${e.key}'] = Map<String, dynamic>.from(e.value as Map);
        }
      }
    }
    final providersRaw = routing['providers'];
    final providers = <String>[
      if (providersRaw is List) ...providersRaw.map((p) => '$p'),
    ];
    final mcp = status?['mcp'] as Map<String, dynamic>?;
    final serversRaw = mcp?['servers'];
    final servers = <Map<String, dynamic>>[
      if (serversRaw is List)
        for (final s in serversRaw)
          if (s is Map) Map<String, dynamic>.from(s),
    ];
    return RoutingSummary(
      defaultProvider: '${routing['default'] ?? '—'}',
      tiers: tiers,
      providers: providers,
      health: health,
      mcpServers: servers,
    );
  }

  final String defaultProvider;

  /// '1'..'3' → id provider; hanya tier yang dipetakan di config.
  final Map<String, String> tiers;

  /// Seluruh id provider yang terpasang di runtime.
  final List<String> providers;

  /// id provider → snapshot kesehatan circuit breaker.
  final Map<String, Map<String, dynamic>> health;

  /// Server MCP terkonfigurasi (id, type, enabled, risk).
  final List<Map<String, dynamic>> mcpServers;

  /// Provider untuk sebuah tier: pemetaan tier bila ada, selain itu
  /// provider default.
  String providerForTier(String tier) => tiers[tier] ?? defaultProvider;
}
