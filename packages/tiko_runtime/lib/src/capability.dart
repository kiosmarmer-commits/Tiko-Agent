import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Scoped capability token (PRD §12).
class CapabilityToken {
  CapabilityToken({
    required this.id,
    required this.sessionId,
    required this.tool,
    required this.operations,
    required this.roots,
    required this.argumentsFingerprint,
    required this.expiresAt,
    this.domains = const [],
    this.maxBytes = 102400,
    this.singleUse = true,
  });

  final String id;
  final String sessionId;
  final String tool;
  final List<String> operations;
  final List<String> roots;
  final String argumentsFingerprint;
  final List<String> domains;
  final DateTime expiresAt;
  final int maxBytes;
  final bool singleUse;
  bool used = false;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
  bool get isValid => !isExpired && !(singleUse && used);

  void markUsed() => used = true;

  Map<String, dynamic> toJson() => {
        'capability_id': id,
        'session_id': sessionId,
        'tool': tool,
        'operations': operations,
        'roots': roots,
        'domains': domains,
        'expires_at': expiresAt.toIso8601String(),
        'max_bytes': maxBytes,
        'single_use': singleUse,
      };

  /// Stable fingerprint of the exact approved tool arguments. Capability
  /// ids are excluded because the id is attached only after approval.
  static String fingerprintArguments(Map<String, dynamic> arguments) {
    Object? normalize(Object? value, {bool root = false}) {
      if (value is Map) {
        final keys = value.keys.map((key) {
          if (key is! String) throw const FormatException('tool argument keys must be strings');
          return key;
        }).toList()..sort();
        return <String, Object?>{
          for (final key in keys)
            if (!root || key != '_capability_id')
              key: normalize(value[key]),
        };
      }
      if (value is List) {
        return value.map((item) => normalize(item)).toList(growable: false);
      }
      if (value == null || value is String || value is num || value is bool) {
        return value;
      }
      throw const FormatException('unsupported tool argument value');
    }

    final canonical = normalize(arguments, root: true);
    final encoded = jsonEncode(canonical);
    if (utf8.encode(encoded).length > 100 * 1024) {
      throw const FormatException('approved tool arguments exceed 100 KiB');
    }
    return encoded;
  }

  static CapabilityToken mint({
    required String sessionId,
    required String tool,
    required List<String> operations,
    required List<String> roots,
    required Map<String, dynamic> arguments,
    Duration ttl = const Duration(minutes: 5),
    List<String> domains = const [],
    bool singleUse = true,
  }) {
    return CapabilityToken(
      id: 'cap_${const Uuid().v4()}',
      sessionId: sessionId,
      tool: tool,
      operations: List.unmodifiable(operations),
      roots: List.unmodifiable(roots),
      argumentsFingerprint: fingerprintArguments(arguments),
      domains: List.unmodifiable(domains),
      expiresAt: DateTime.now().toUtc().add(ttl),
      singleUse: singleUse,
    );
  }
}

class CapabilityVault {
  final _tokens = <String, CapabilityToken>{};

  CapabilityToken issue(CapabilityToken t) {
    if (!t.singleUse) {
      throw ArgumentError('runtime capabilities must be single-use');
    }
    if (_tokens.containsKey(t.id)) {
      throw StateError('capability id collision');
    }
    _tokens[t.id] = t;
    return t;
  }

  CapabilityToken? take(String id) {
    final t = _tokens[id];
    if (t == null || !t.isValid) {
      _tokens.remove(id);
      return null;
    }
    if (t.singleUse) {
      t.markUsed();
      _tokens.remove(id);
    }
    return t;
  }
}
