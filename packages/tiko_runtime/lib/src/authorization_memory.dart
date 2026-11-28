import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Fase 39 — AuthorizationMemory (paritas Grok Bot "smarter approvals"):
/// mengingat aksi (tool + hash argumen) yang sudah disetujui pengguna agar
/// approval yang sama tidak ditanyakan berulang dalam jendela TTL.
///
/// Konvensi repo:
/// - Default off via config (`authorization_memory:`) — mengubah semantik
///   approval, jadi hanya aktif bila operator menyetel `enabled: true`.
/// - Fail-closed: tool pada daftar `never_cache_tools` TIDAK PERNAH
///   diotorisasi otomatis meskipun fitur on; entry kedaluwarsa diabaikan;
///   kegagalan disk tidak pernah menghasilkan otorisasi palsu.
/// - Scope: otorisasi terikat sesi (`session:<id>`) atau global (`*`) —
///   global hanya bila pengguna menyetujuinya secara eksplisit.
/// Fingerprint hash argumen yang stabil — semantik sama dengan hash ledger
/// approval (`_stableHash`): key internal `_`* dibuang, normalisasi
/// key-sorted JSON + FNV-1a 32-bit. Dipakai agar otorisasi tersimpan cocok
/// dengan approval sungguhan.
String stableArgsHash(Map<String, dynamic> value) {
  final safe = Map<String, dynamic>.from(value)
    ..removeWhere((key, _) => key.startsWith('_'));
  String normalize(dynamic item) {
    if (item is Map) {
      final keys = item.keys.map((e) => '$e').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${normalize(item[k])}').join(',')}}';
    }
    if (item is List) return '[${item.map(normalize).join(',')}]';
    return jsonEncode(item);
  }

  final input = normalize(safe);
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class AuthorizationEntry {
  AuthorizationEntry({
    required this.tool,
    required this.argsHash,
    required this.scope,
    required this.grantedAt,
    required this.expiresAt,
    this.actor = '',
  });

  final String tool;
  final String argsHash;

  /// `session:<id>` atau `*`.
  final String scope;
  final DateTime grantedAt;
  final DateTime expiresAt;
  final String actor;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'args_hash': argsHash,
        'scope': scope,
        'granted_at': grantedAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'actor': actor,
      };

  static AuthorizationEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tool = raw['tool'];
    final hash = raw['args_hash'];
    final scope = raw['scope'];
    final expires = raw['expires_at'];
    if (tool is! String ||
        tool.trim().isEmpty ||
        hash is! String ||
        hash.isEmpty ||
        scope is! String ||
        scope.isEmpty) {
      return null;
    }
    final expiresAt = DateTime.tryParse(expires is String ? expires : '');
    if (expiresAt == null) return null;
    return AuthorizationEntry(
      tool: tool.trim(),
      argsHash: hash,
      scope: scope,
      grantedAt: DateTime.tryParse(raw['granted_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      expiresAt: expiresAt.toUtc(),
      actor: raw['actor'] is String ? raw['actor'] as String : '',
    );
  }
}

class AuthorizationCheckResult {
  const AuthorizationCheckResult({
    required this.authorized,
    this.entry,
    this.reason = '',
  });

  final bool authorized;
  final AuthorizationEntry? entry;
  final String reason;

  Map<String, dynamic> toJson() => {
        'authorized': authorized,
        if (reason.isNotEmpty) 'reason': reason,
        if (entry != null) 'granted_at': entry!.grantedAt.toIso8601String(),
        if (entry != null) 'expires_at': entry!.expiresAt.toIso8601String(),
      };
}

class AuthorizationMemory {
  AuthorizationMemory({
    required String path,
    this.ttl = const Duration(minutes: 60),
    this.maxEntries = 256,
    this.neverCacheTools = const <String>{},
  }) : path = path;

  final String path;
  final Duration ttl;
  final int maxEntries;

  /// Tool yang tidak boleh diotorisasi otomatis (fail-closed permanen):
  /// default mencakup tool yang mengeksekusi kode/agent sewenang-wenang.
  final Set<String> neverCacheTools;

  final List<AuthorizationEntry> _entries = [];
  bool _loaded = false;
  Future<void> _saveTail = Future<void>.value();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = json['entries'];
      if (raw is! List) return;
      for (final item in raw) {
        final entry = AuthorizationEntry.fromJson(item);
        if (entry != null) _entries.add(entry);
      }
    } on FormatException {
      _entries.clear();
    }
  }

  /// Cek otorisasi untuk kombinasi (tool, argsHash, sesi). Entry global (`*`)
  /// dan entry sesi yang cocok keduanya diterima; kedaluwarsa dihapus.
  AuthorizationCheckResult check({
    required String tool,
    required String argsHash,
    required String sessionId,
  }) {
    final now = DateTime.now().toUtc();
    if (neverCacheTools.contains(tool)) {
      return const AuthorizationCheckResult(
        authorized: false,
        reason: 'tool berada di never_cache_tools (fail-closed)',
      );
    }
    if (argsHash.isEmpty) {
      return const AuthorizationCheckResult(
        authorized: false,
        reason: 'args_hash kosong',
      );
    }
    final sessionScope = 'session:$sessionId';
    _entries.removeWhere((e) => e.isExpiredAt(now));
    for (final entry in _entries.reversed) {
      if (entry.tool != tool || entry.argsHash != argsHash) continue;
      if (entry.scope == '*' || entry.scope == sessionScope) {
        return AuthorizationCheckResult(
          authorized: true,
          entry: entry,
          reason: entry.scope == '*'
              ? 'otorisasi global aktif'
              : 'otorisasi sesi aktif',
        );
      }
    }
    return const AuthorizationCheckResult(
      authorized: false,
      reason: 'belum ada otorisasi yang cocok',
    );
  }

  /// Catat otorisasi baru. Return false bila tool masuk daftar never-cache
  /// (ditolak fail-closed) atau argumen hash kosong.
  Future<bool> grant({
    required String tool,
    required String argsHash,
    required String sessionId,
    bool global = false,
    String actor = '',
  }) async {
    if (neverCacheTools.contains(tool) || argsHash.isEmpty) return false;
    final now = DateTime.now().toUtc();
    _entries.removeWhere((e) => e.isExpiredAt(now));
    final entry = AuthorizationEntry(
      tool: tool,
      argsHash: argsHash,
      scope: global ? '*' : 'session:$sessionId',
      grantedAt: now,
      expiresAt: now.add(ttl),
      actor: actor,
    );
    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    await _persist();
    return true;
  }

  /// Cabut otorisasi. [tool] kosong = cabut semua (satu per satu atau global).
  Future<int> revoke({String tool = '', String sessionId = ''}) async {
    final before = _entries.length;
    if (tool.isEmpty && sessionId.isEmpty) {
      _entries.clear();
    } else if (tool.isEmpty) {
      final scope = 'session:$sessionId';
      _entries.removeWhere((e) => e.scope == scope);
    } else if (sessionId.isEmpty) {
      _entries.removeWhere((e) => e.tool == tool);
    } else {
      final scope = 'session:$sessionId';
      _entries.removeWhere((e) => e.tool == tool && e.scope == scope);
    }
    final removed = before - _entries.length;
    if (removed > 0) await _persist();
    return removed;
  }

  int count() => _entries.length;

  List<Map<String, dynamic>> snapshot({DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    _entries.removeWhere((e) => e.isExpiredAt(at));
    return _entries.map((e) => e.toJson()).toList();
  }

  Future<void> _persist() {
    final next = _saveTail.then((_) => _write());
    _saveTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write() async {
    await Directory(p.dirname(path)).create(recursive: true);
    final payload = jsonEncode({
      'entries': _entries.map((e) => e.toJson()).toList(),
    });
    final tmp = File('$path.tmp');
    await tmp.writeAsString(payload);
    await tmp.rename(path);
  }
}

/// Tool `authz` — inspeksi dan pencabutan otorisasi tersimpan: list/revoke/
/// clear. Mencabut selalu boleh; memberi otorisasi baru TIDAK lewat tool ini
/// (hanya lewat approval sungguhan) — fail-closed.
class AuthorizationTool implements Tool {
  AuthorizationTool({required this.memory});

  final AuthorizationMemory memory;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'authz',
        description:
            'Kelola otorisasi tersimpan (smart approvals): lihat otorisasi '
            'aktif, cabut per tool/sesi, atau kosongkan semua. Memberi '
            'otorisasi baru hanya lewat approval sungguhan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'revoke', 'clear'],
            },
            'tool': {
              'type': 'string',
              'description': 'Filter tool untuk revoke (opsional).',
            },
            'session': {
              'type': 'string',
              'description': 'Filter sesi untuk revoke (opsional).',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 30,
        maxOutputChars: 8000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final tool = (args['tool'] as String?)?.trim() ?? '';
    final session = (args['session'] as String?)?.trim() ?? '';
    try {
      switch (action) {
        case 'list':
          final items = memory.snapshot();
          if (items.isEmpty) {
            return const ToolResult(callId: '', content: 'Tidak ada otorisasi aktif.');
          }
          final buf = StringBuffer('${items.length} otorisasi aktif:\n');
          for (final item in items) {
            buf.writeln(
                '- ${item['tool']} scope=${item['scope']} kedaluwarsa=${item['expires_at']}');
          }
          return ToolResult(callId: '', content: buf.toString().trim());

        case 'revoke':
          final removed = await memory.revoke(tool: tool, sessionId: session);
          return ToolResult(
            callId: '',
            content: removed > 0
                ? '$removed otorisasi dicabut.'
                : 'Tidak ada otorisasi yang cocok untuk dicabut.',
          );

        case 'clear':
          final removed = await memory.revoke();
          return ToolResult(
            callId: '',
            content: '$removed otorisasi dicabut (semua).',
          );

        default:
          return const ToolResult(
            callId: '',
            content: 'action tidak dikenal. Gunakan: list, revoke, clear.',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(callId: '', content: 'authz gagal: $e', isError: true);
    }
  }
}
