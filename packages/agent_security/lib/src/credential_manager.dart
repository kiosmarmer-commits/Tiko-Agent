import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Result of a credential availability check.
class CredentialCheckResult {
  const CredentialCheckResult({
    required this.available,
    this.reason,
    this.credentials,
  });

  final bool available;
  final String? reason;
  final List<String>? credentials;
}

/// Manages API credentials with support for credential pools
///
/// Credential pools allow distributing API calls across multiple keys
/// for the same provider, with automatic rotation on rate limits or failures.
class CredentialManager {
  CredentialManager({
    required this.storagePath,
    this.rotationStrategy = RotationStrategy.roundRobin,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
  });

  final String storagePath;
  final RotationStrategy rotationStrategy;
  final int maxRetries;
  final Duration retryDelay;

  /// Map of provider -> list of credential entries
  final Map<String, List<CredentialEntry>> _credentials = {};
  
  /// Map of provider -> current index for round-robin
  final Map<String, int> _currentIndices = {};
  
  /// Map of provider -> rate limit tracking
  final Map<String, RateLimitTracker> _rateLimitTrackers = {};

  bool _initialized = false;

  /// Initialize the credential manager
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      final file = File(storagePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        
        for (final entry in data.entries) {
          final provider = entry.key;
          final creds = entry.value as List<dynamic>;
          _credentials[provider] = creds
              .map((c) => CredentialEntry.fromJson(c as Map<String, dynamic>))
              .toList();
          _currentIndices[provider] = 0;
          _rateLimitTrackers[provider] = RateLimitTracker();
        }
      }
      _initialized = true;
    } catch (e) {
      // Failed to initialize
      _initialized = false;
      rethrow;
    }
  }

  /// Add a credential for a provider
  Future<void> addCredential({
    required String provider,
    required String key,
    String? name,
    String? model,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_credentials.containsKey(provider)) {
      _credentials[provider] = [];
      _currentIndices[provider] = 0;
      _rateLimitTrackers[provider] = RateLimitTracker();
    }
    
    final entry = CredentialEntry(
      id: _generateId(),
      provider: provider,
      key: key,
      name: name ?? 'key_${_credentials[provider]!.length + 1}',
      model: model,
      metadata: metadata ?? {},
      createdAt: DateTime.now().toUtc(),
      lastUsed: null,
      usageCount: 0,
      failures: 0,
    );
    
    _credentials[provider]!.add(entry);
    await _save();
  }

  /// Remove a credential
  Future<void> removeCredential(String id) async {
    for (final provider in _credentials.keys) {
      _credentials[provider]?.removeWhere((entry) => entry.id == id);
    }
    await _save();
  }

  /// Get a credential for a provider (with rotation)
  Future<CredentialEntry?> getCredential({
    required String provider,
    String? model,
  }) async {
    if (!_credentials.containsKey(provider) || _credentials[provider]!.isEmpty) {
      return null;
    }

    // Check rate limits and rotate if needed
    await _checkRateLimits(provider);
    
    // Get credential based on rotation strategy
    final entry = _getCredentialByStrategy(provider, model);
    
    if (entry != null) {
      // Update usage stats
      entry.lastUsed = DateTime.now().toUtc();
      entry.usageCount++;
      await _save();
    }
    
    return entry;
  }

  /// Check rate limits and rotate credentials if needed
  Future<void> _checkRateLimits(String provider) async {
    if (!_rateLimitTrackers.containsKey(provider)) return;
    
    final tracker = _rateLimitTrackers[provider]!;
    
    // Check if current credential is rate limited
    final currentIndex = _currentIndices[provider] ?? 0;
    if (currentIndex < _credentials[provider]!.length) {
      final currentEntry = _credentials[provider]![currentIndex];
      if (tracker.isRateLimited(currentEntry.id)) {
        // Rotate to next credential
        await _rotateCredential(provider);
      }
    }
  }

  /// Get credential based on rotation strategy
  CredentialEntry? _getCredentialByStrategy(String provider, String? model) {
    if (!_credentials.containsKey(provider) || _credentials[provider]!.isEmpty) {
      return null;
    }

    switch (rotationStrategy) {
      case RotationStrategy.roundRobin:
        return _getRoundRobin(provider, model);
      case RotationStrategy.leastUsed:
        return _getLeastUsed(provider, model);
      case RotationStrategy.random:
        return _getRandom(provider, model);
      case RotationStrategy.firstAvailable:
        return _getFirstAvailable(provider, model);
    }
  }

  /// Round-robin strategy
  CredentialEntry? _getRoundRobin(String provider, String? model) {
    final entries = _credentials[provider]!;
    final currentIndex = _currentIndices[provider] ?? 0;
    
    // Find next available credential
    for (var i = 0; i < entries.length; i++) {
      final index = (currentIndex + i) % entries.length;
      final entry = entries[index];
      
      // Check if model matches
      if (model != null && entry.model != null && entry.model != model) {
        continue;
      }
      
      // Check if credential is rate limited
      final tracker = _rateLimitTrackers[provider]!;
      if (!tracker.isRateLimited(entry.id)) {
        _currentIndices[provider] = (index + 1) % entries.length;
        return entry;
      }
    }
    
    return null;
  }

  /// Least used strategy
  CredentialEntry? _getLeastUsed(String provider, String? model) {
    final entries = _credentials[provider]!;
    
    CredentialEntry? bestEntry;
    int minUsage = double.infinity.toInt();
    
    for (final entry in entries) {
      // Check model match
      if (model != null && entry.model != null && entry.model != model) {
        continue;
      }
      
      // Check rate limit
      final tracker = _rateLimitTrackers[provider]!;
      if (tracker.isRateLimited(entry.id)) {
        continue;
      }
      
      if (entry.usageCount < minUsage) {
        minUsage = entry.usageCount;
        bestEntry = entry;
      }
    }
    
    return bestEntry;
  }

  /// Random strategy
  CredentialEntry? _getRandom(String provider, String? model) {
    final entries = _credentials[provider]!;
    final available = <CredentialEntry>[];
    
    for (final entry in entries) {
      // Check model match
      if (model != null && entry.model != null && entry.model != model) {
        continue;
      }
      
      // Check rate limit
      final tracker = _rateLimitTrackers[provider]!;
      if (!tracker.isRateLimited(entry.id)) {
        available.add(entry);
      }
    }
    
    if (available.isEmpty) return null;
    
    return available[DateTime.now().millisecondsSinceEpoch % available.length];
  }

  /// First available strategy
  CredentialEntry? _getFirstAvailable(String provider, String? model) {
    final entries = _credentials[provider]!;
    
    for (final entry in entries) {
      // Check model match
      if (model != null && entry.model != null && entry.model != model) {
        continue;
      }
      
      // Check rate limit
      final tracker = _rateLimitTrackers[provider]!;
      if (!tracker.isRateLimited(entry.id)) {
        return entry;
      }
    }
    
    return null;
  }

  /// Rotate to next credential for a provider
  Future<void> _rotateCredential(String provider) async {
    if (!_currentIndices.containsKey(provider)) {
      _currentIndices[provider] = 0;
      return;
    }
    
    _currentIndices[provider] = (_currentIndices[provider]! + 1) % _credentials[provider]!.length;
  }

  /// Report a failure for a credential
  Future<void> reportFailure(String credentialId) async {
    for (final provider in _credentials.keys) {
      for (final entry in _credentials[provider]!) {
        if (entry.id == credentialId) {
          entry.failures++;
          await _save();
          return;
        }
      }
    }
  }

  /// Report rate limit hit for a credential
  Future<void> reportRateLimit(String credentialId, Duration retryAfter) async {
    for (final provider in _credentials.keys) {
      if (_rateLimitTrackers.containsKey(provider)) {
        _rateLimitTrackers[provider]!.reportRateLimit(credentialId, retryAfter);
      }
    }
  }

  /// Check if credentials are available for a tool call
  Future<CredentialCheckResult> checkCredentials(ToolCall call) async {
    // Extract provider from tool name or args
    final provider = _extractProvider(call);
    
    if (provider == null) {
      return CredentialCheckResult(
        available: true,
        reason: 'No credentials required for ${call.name}',
      );
    }
    
    final credential = await getCredential(provider: provider);
    
    if (credential == null) {
      return CredentialCheckResult(
        available: false,
        reason: 'No credentials available for $provider',
      );
    }
    
    return CredentialCheckResult(
      available: true,
      credentials: [credential.key],
    );
  }

  /// Extract provider from tool call
  String? _extractProvider(ToolCall call) {
    // Check for provider in tool name
    const providerPatterns = [
      'openai_', 'anthropic_', 'google_', 'mistral_', 'groq_',
      'openrouter_', 'nous_', 'portal_',
    ];
    
    for (final pattern in providerPatterns) {
      if (call.name.startsWith(pattern)) {
        return call.name.substring(0, pattern.length - 1);
      }
    }
    
    // Check for provider in args
    if (call.args.containsKey('provider')) {
      return call.args['provider'] as String?;
    }
    
    return null;
  }

  /// Save credentials to storage
  Future<void> _save() async {
    try {
      final data = <String, List<Map<String, dynamic>>>{};
      
      for (final entry in _credentials.entries) {
        data[entry.key] = entry.value.map((c) => c.toJson()).toList();
      }
      
      final file = File(storagePath);
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      // Failed to save
    }
  }

  /// Generate a unique ID
  String _generateId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_randomString(8)}';
  }

  /// Generate a random string
  String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    return List.generate(length, (_) => chars[random % chars.length]).join();
  }
}

/// Rotation strategies for credential selection
enum RotationStrategy {
  /// Select credentials in round-robin order
  roundRobin,
  
  /// Select the least used credential
  leastUsed,
  
  /// Select a random credential
  random,
  
  /// Select the first available credential
  firstAvailable,
}

/// A single credential entry
class CredentialEntry {
  CredentialEntry({
    required this.id,
    required this.provider,
    required this.key,
    required this.name,
    this.model,
    this.metadata = const {},
    required this.createdAt,
    this.lastUsed,
    this.usageCount = 0,
    this.failures = 0,
  });

  final String id;
  final String provider;
  final String key;
  final String name;
  final String? model;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  DateTime? lastUsed;
  int usageCount;
  int failures;

  /// Get the masked key for display (show only first and last characters)
  String get maskedKey {
    if (key.length <= 4) return '****';
    return '${key.substring(0, 2)}****${key.substring(key.length - 2)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'key': key,
        'name': name,
        'model': model,
        'metadata': metadata,
        'createdAt': createdAt.toIso8601String(),
        'lastUsed': lastUsed?.toIso8601String(),
        'usageCount': usageCount,
        'failures': failures,
      };

  factory CredentialEntry.fromJson(Map<String, dynamic> json) {
    return CredentialEntry(
      id: json['id'] as String,
      provider: json['provider'] as String,
      key: json['key'] as String,
      name: json['name'] as String,
      model: json['model'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      lastUsed: json['lastUsed'] != null
          ? DateTime.parse(json['lastUsed'] as String).toUtc()
          : null,
      usageCount: json['usageCount'] as int? ?? 0,
      failures: json['failures'] as int? ?? 0,
    );
  }
}

/// Tracks rate limits for credentials
class RateLimitTracker {
  final Map<String, RateLimitEntry> _entries = {};

  /// Check if a credential is rate limited
  bool isRateLimited(String credentialId) {
    final entry = _entries[credentialId];
    if (entry == null) return false;
    
    return DateTime.now().isBefore(entry.retryAfter);
  }

  /// Report a rate limit hit
  void reportRateLimit(String credentialId, Duration retryAfter) {
    _entries[credentialId] = RateLimitEntry(
      retryAfter: DateTime.now().add(retryAfter),
    );
  }

  /// Clear rate limit for a credential
  void clearRateLimit(String credentialId) {
    _entries.remove(credentialId);
  }
}

/// Rate limit entry
class RateLimitEntry {
  final DateTime retryAfter;

  RateLimitEntry({required this.retryAfter});
}
