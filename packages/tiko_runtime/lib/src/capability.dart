import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart'
    show CapabilityCheckResult, CapabilityGate;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Scoped capability token (PRD §12).
///
/// Token dibuat sempit dan terikat sumber daya (narrow resource-bound):
/// [operations] menyimpan operasi persis untuk tool itu ([operationForTool]),
/// [roots] memuat file absolut persis yang disetujui ([boundRoots]), dan
/// [domains] memuat host HTTP persis ([boundDomains]) — bukan "workspace
/// mana pun" generik. Fingerprint argumen tetap menjadi kunci utama; binding
/// sumber daya adalah lapisan pertahanan kedua yang juga terlihat di audit.
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

  /// Operasi sempit per tool (PRD §12). 'execute' generik tetap dikenal
  /// gerbang untuk token bergaya lama, tetapi token baru hanya menyimpan
  /// operasi persis yang disetujui untuk tool tersebut.
  static String operationForTool(String tool) => switch (tool) {
        'shell' => 'exec',
        'write_file' => 'write',
        'patch_file' => 'patch',
        'http_request' || 'web_fetch' => 'fetch',
        _ => 'execute',
      };

  /// Binding root sempit: untuk tool file, root = file absolut persis yang
  /// diminta (bukan seluruh workspace). Untuk tool tanpa path spesifik yang
  /// bisa ditarik (shell, script, mcp), tetap workspace — tetap dikunci oleh
  /// fingerprint argumen. Path absolut dipertahankan apa adanya; resolusi
  /// traversal tetap tugas jail tool (fail-closed di sana).
  static List<String> boundRoots(
    String tool,
    Map<String, dynamic> args, {
    required String workspaceRoot,
  }) {
    if (tool == 'write_file' || tool == 'patch_file') {
      final raw = args['path'];
      if (raw is String && raw.trim().isNotEmpty) {
        final normalized = p.normalize(
          p.isAbsolute(raw) ? raw : p.join(workspaceRoot, raw),
        );
        return List<String>.unmodifiable([normalized]);
      }
    }
    return List<String>.unmodifiable([workspaceRoot]);
  }

  /// Binding domain sempit untuk tool HTTP: host persis dari URL yang
  /// disetujui (lowercase). URL tidak valid menghasilkan list kosong; tool
  /// akan menolak URL tersebut lebih dulu (fail-closed).
  static List<String> boundDomains(String tool, Map<String, dynamic> args) {
    if (tool == 'http_request' || tool == 'web_fetch') {
      final raw = args['url'];
      if (raw is String) {
        final host = Uri.tryParse(raw.trim())?.host.toLowerCase();
        if (host != null && host.isNotEmpty) {
          return List<String>.unmodifiable([host]);
        }
      }
    }
    return const [];
  }

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
    int maxBytes = 102400,
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
      maxBytes: maxBytes,
    );
  }
}

class CapabilityVault implements CapabilityGate {
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

  /// Non-consuming validity check. Used by audit/pre-gate layers (Tirith)
  /// that must observe a capability without spending the single-use token;
  /// the enforcing gate still consumes it via [take].
  bool peek(String id, {String? tool}) {
    final t = _tokens[id];
    if (t == null || !t.isValid) return false;
    if (tool != null && t.tool != tool) return false;
    return true;
  }

  @override
  Future<CapabilityCheckResult> check(ToolCall call, Session session) async {
    final raw = call.args['_capability_id'];
    if (raw is! String || raw.isEmpty) {
      return const CapabilityCheckResult(
        allowed: false,
        reason: 'capability id required for high-impact tool call',
      );
    }
    final token = take(raw);
    if (token == null) {
      return const CapabilityCheckResult(
        allowed: false,
        reason: 'capability invalid or expired',
      );
    }
    if (token.tool != call.name) {
      return CapabilityCheckResult(
        allowed: false,
        reason: 'capability issued for ${token.tool}, not ${call.name}',
      );
    }
    return const CapabilityCheckResult(allowed: true);
  }
}
