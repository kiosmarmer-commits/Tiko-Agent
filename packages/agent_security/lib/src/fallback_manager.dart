/// Result of a provider availability check.
class ProviderCheckResult {
  const ProviderCheckResult({
    required this.available,
    required this.provider,
    required this.model,
    this.fallbackProvider,
    this.reason,
  });

  final bool available;
  final String provider;
  final String model;
  final String? fallbackProvider;
  final String? reason;
}

/// Manages fallback providers for automatic failover
///
/// When a primary provider fails (due to errors, rate limits, or timeouts),
/// this manager automatically falls back to backup providers.
class FallbackManager {
  FallbackManager({
    required this.config,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.fallbackDelay = const Duration(seconds: 2),
  });

  /// Fallback configuration
  final FallbackConfig config;

  /// Maximum number of retries before giving up
  final int maxRetries;

  /// Delay between retries
  final Duration retryDelay;

  /// Delay before switching to fallback
  final Duration fallbackDelay;

  /// Map of primary provider -> list of fallback providers
  final Map<String, List<FallbackProvider>> _fallbacks = {};

  /// Track current provider for each primary
  final Map<String, int> _currentIndices = {};

  /// Track failed providers temporarily
  final Map<String, DateTime> _failedProviders = {};

  bool _initialized = false;

  /// Initialize the fallback manager
  Future<void> initialize() async {
    if (_initialized) return;
    
    // Load from config
    for (final entry in config.fallbacks) {
      _fallbacks[entry.primary] = entry.fallbacks
          .map((f) => FallbackProvider(
                name: f.name,
                priority: f.priority,
                timeout: f.timeout,
                maxRetries: f.maxRetries,
              ))
          .toList();
      _currentIndices[entry.primary] = 0;
    }
    
    _initialized = true;
  }

  /// Check if a provider is available (with fallback)
  Future<ProviderCheckResult> checkProvider(String primary, String model) async {
    // First, check if primary is available
    final primaryCheck = await _checkPrimary(primary, model);
    
    if (primaryCheck.available) {
      return primaryCheck;
    }
    
    // Primary failed, try fallbacks
    if (_fallbacks.containsKey(primary)) {
      final fallbacks = _fallbacks[primary]!;
      
      for (final fallback in fallbacks) {
        final result = await _checkFallback(fallback, model);
        if (result.available) {
          return ProviderCheckResult(
            available: true,
            provider: fallback.name,
            model: model,
            fallbackProvider: primary,
            reason: 'Fell back from $primary to ${fallback.name}',
          );
        }
      }
    }
    
    // No providers available
    return ProviderCheckResult(
      available: false,
      provider: primary,
      model: model,
      reason: 'All providers (primary and fallbacks) are unavailable',
    );
  }

  /// Check primary provider
  Future<ProviderCheckResult> _checkPrimary(String provider, String model) async {
    // In a real implementation, this would actually check the provider
    // For now, check if it's in the failed list
    if (_failedProviders.containsKey(provider)) {
      final failedAt = _failedProviders[provider]!;
      final retryAfter = config.retryAfter;
      
      if (DateTime.now().difference(failedAt) < retryAfter) {
        return ProviderCheckResult(
          available: false,
          provider: provider,
          model: model,
          reason: 'Provider temporarily unavailable (retry after ${retryAfter.inSeconds}s)',
        );
      } else {
        // Retry period expired, remove from failed list
        _failedProviders.remove(provider);
      }
    }
    
    // Assume primary is available
    return ProviderCheckResult(
      available: true,
      provider: provider,
      model: model,
    );
  }

  /// Check fallback provider
  Future<ProviderCheckResult> _checkFallback(
    FallbackProvider fallback, 
    String model,
  ) async {
    // Check if this fallback is in the failed list
    if (_failedProviders.containsKey(fallback.name)) {
      final failedAt = _failedProviders[fallback.name]!;
      final retryAfter = fallback.timeout;
      
      if (DateTime.now().difference(failedAt) < retryAfter) {
        return ProviderCheckResult(
          available: false,
          provider: fallback.name,
          model: model,
          reason: 'Fallback provider temporarily unavailable',
        );
      } else {
        _failedProviders.remove(fallback.name);
      }
    }
    
    // Assume fallback is available
    return ProviderCheckResult(
      available: true,
      provider: fallback.name,
      model: model,
    );
  }

  /// Get fallback provider for a primary
  Future<String?> getFallback(String primary) async {
    if (!_fallbacks.containsKey(primary)) {
      return null;
    }
    
    final fallbacks = _fallbacks[primary]!;
    if (fallbacks.isEmpty) {
      return null;
    }
    
    // Get next fallback based on current index
    final currentIndex = _currentIndices[primary] ?? 0;
    final nextIndex = (currentIndex + 1) % fallbacks.length;
    _currentIndices[primary] = nextIndex;
    
    return fallbacks[nextIndex].name;
  }

  /// Report a provider failure
  Future<void> reportFailure({
    required String provider,
    required String reason,
    Duration? retryAfter,
  }) async {
    _failedProviders[provider] = DateTime.now();
    
    // If this is a fallback provider, also mark it in the primary's fallback list
    for (final primary in _fallbacks.keys) {
      for (final fallback in _fallbacks[primary]!) {
        if (fallback.name == provider) {
          // In a real implementation, we might want to rotate fallbacks
          // or temporarily disable this fallback
        }
      }
    }
  }

  /// Report a provider success
  Future<void> reportSuccess(String provider) async {
    _failedProviders.remove(provider);
  }

  /// Execute with fallback support
  Future<T> executeWithFallback<T>({
    required String primaryProvider,
    required Future<T> Function() primaryAction,
    required Future<T> Function(String fallbackProvider) fallbackAction,
    String? model,
  }) async {
    try {
      // Try primary first
      return await primaryAction();
    } catch (e) {
      // Primary failed, report failure
      await reportFailure(
        provider: primaryProvider,
        reason: e.toString(),
      );
      
      // Wait before trying fallback
      await Future.delayed(fallbackDelay);
      
      // Try fallbacks
      if (_fallbacks.containsKey(primaryProvider)) {
        final fallbacks = _fallbacks[primaryProvider]!;
        
        for (final fallback in fallbacks) {
          try {
            final result = await fallbackAction(fallback.name);
            await reportSuccess(fallback.name);
            return result;
          } catch (fallbackError) {
            await reportFailure(
              provider: fallback.name,
              reason: fallbackError.toString(),
            );
            // Continue to next fallback
          }
        }
      }
      
      // All providers failed
      rethrow;
    }
  }

  /// Add a fallback configuration
  void addFallback({
    required String primary,
    required List<FallbackProviderConfig> fallbacks,
  }) {
    _fallbacks[primary] = fallbacks
        .map((f) => FallbackProvider(
              name: f.name,
              priority: f.priority,
              timeout: f.timeout,
              maxRetries: f.maxRetries,
            ))
        .toList();
    _currentIndices[primary] = 0;
  }

  /// Remove a fallback configuration
  void removeFallback(String primary) {
    _fallbacks.remove(primary);
    _currentIndices.remove(primary);
  }
}

/// Configuration for fallback providers
class FallbackConfig {
  const FallbackConfig({
    this.fallbacks = const [],
    this.retryAfter = const Duration(minutes: 1),
    this.maxFallbacks = 3,
    this.enableAutomaticFallback = true,
  });

  /// List of fallback configurations
  final List<FallbackEntry> fallbacks;

  /// Default retry after duration
  final Duration retryAfter;

  /// Maximum number of fallbacks to try
  final int maxFallbacks;

  /// Whether automatic fallback is enabled
  final bool enableAutomaticFallback;

  Map<String, dynamic> toJson() => {
        'fallbacks': fallbacks.map((f) => f.toJson()).toList(),
        'retryAfter': retryAfter.inSeconds,
        'maxFallbacks': maxFallbacks,
        'enableAutomaticFallback': enableAutomaticFallback,
      };

  factory FallbackConfig.fromJson(Map<String, dynamic> json) {
    return FallbackConfig(
      fallbacks: (json['fallbacks'] as List<dynamic>? ?? [])
          .map((f) => FallbackEntry.fromJson(f as Map<String, dynamic>))
          .toList(),
      retryAfter: Duration(seconds: json['retryAfter'] as int? ?? 60),
      maxFallbacks: json['maxFallbacks'] as int? ?? 3,
      enableAutomaticFallback: json['enableAutomaticFallback'] as bool? ?? true,
    );
  }
}

/// A fallback entry (primary -> fallbacks)
class FallbackEntry {
  const FallbackEntry({
    required this.primary,
    required this.fallbacks,
  });

  final String primary;
  final List<FallbackProviderConfig> fallbacks;

  Map<String, dynamic> toJson() => {
        'primary': primary,
        'fallbacks': fallbacks.map((f) => f.toJson()).toList(),
      };

  factory FallbackEntry.fromJson(Map<String, dynamic> json) {
    return FallbackEntry(
      primary: json['primary'] as String,
      fallbacks: (json['fallbacks'] as List<dynamic>? ?? [])
          .map((f) => FallbackProviderConfig.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Configuration for a fallback provider
class FallbackProviderConfig {
  const FallbackProviderConfig({
    required this.name,
    this.priority = 1,
    this.timeout = const Duration(minutes: 1),
    this.maxRetries = 3,
  });

  final String name;
  final int priority;
  final Duration timeout;
  final int maxRetries;

  Map<String, dynamic> toJson() => {
        'name': name,
        'priority': priority,
        'timeout': timeout.inSeconds,
        'maxRetries': maxRetries,
      };

  factory FallbackProviderConfig.fromJson(Map<String, dynamic> json) {
    return FallbackProviderConfig(
      name: json['name'] as String,
      priority: json['priority'] as int? ?? 1,
      timeout: Duration(seconds: json['timeout'] as int? ?? 60),
      maxRetries: json['maxRetries'] as int? ?? 3,
    );
  }
}

/// A fallback provider (runtime representation)
class FallbackProvider {
  final String name;
  final int priority;
  final Duration timeout;
  final int maxRetries;

  FallbackProvider({
    required this.name,
    required this.priority,
    required this.timeout,
    required this.maxRetries,
  });
}
