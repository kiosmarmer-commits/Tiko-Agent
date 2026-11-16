import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Persona bot persisten per chat (Hermes-parity): setiap bot punya nama,
/// prompt persona, model opsional, dan greeting — tersimpan sebagai file
/// JSON di `<dataDir>/bots/<id>.json`, binding sesi di
/// `<dataDir>/bots/bindings.json`.
class BotProfile {
  BotProfile({
    required this.id,
    required this.name,
    this.persona = '',
    this.model,
    this.greeting = '',
    this.toolAllowlist = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String name;
  final String persona;
  final String? model;
  final String greeting;

  /// Tool yang boleh dipakai sesi yang ter-bind ke bot ini (B1). Kosong
  /// berarti belum diatur: turn ditolak fail-closed, bukan mewarisi semua
  /// tool host (sama dengan semantik BotRouter di agent_core).
  final List<String> toolAllowlist;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'persona': persona,
        'model': model,
        'greeting': greeting,
        'tool_allowlist': toolAllowlist,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory BotProfile.fromJson(Map<String, dynamic> json) => BotProfile(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        persona: json['persona'] as String? ?? '',
        model: json['model'] as String?,
        greeting: json['greeting'] as String? ?? '',
        toolAllowlist: _parseAllowlist(json['tool_allowlist']),
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );

  BotProfile copyWith({
    String? name,
    String? persona,
    String? model,
    bool clearModel = false,
    String? greeting,
    List<String>? toolAllowlist,
    bool clearToolAllowlist = false,
  }) =>
      BotProfile(
        id: id,
        name: name ?? this.name,
        persona: persona ?? this.persona,
        model: clearModel ? null : (model ?? this.model),
        greeting: greeting ?? this.greeting,
        toolAllowlist: clearToolAllowlist
            ? const []
            : (toolAllowlist ?? this.toolAllowlist),
        createdAt: createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  static List<String> _parseAllowlist(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String) {
        final t = item.trim();
        if (t.isNotEmpty && !out.contains(t)) out.add(t);
      }
    }
    return List.unmodifiable(out);
  }

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool isValidId(String id) => idPattern.hasMatch(id);
}

class BotStore {
  BotStore({required String dataDir})
      : botsDir = p.join(dataDir, 'bots'),
        bindingsPath = p.join(dataDir, 'bots', 'bindings.json');

  final String botsDir;
  final String bindingsPath;

  final Map<String, BotProfile> _profiles = {};
  final Map<String, String> _bindings = {};

  Future<void> load() async {
    final dir = Directory(botsDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (p.basename(entity.path) == 'bindings.json') continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final profile = BotProfile.fromJson(json);
        _profiles[profile.id] = profile;
      } on FormatException {
        // Skip file korup; jangan gagalkan seluruh store.
      }
    }
    final bindingsFile = File(bindingsPath);
    if (await bindingsFile.exists()) {
      try {
        final json = jsonDecode(await bindingsFile.readAsString())
            as Map<String, dynamic>;
        _bindings
          ..clear()
          ..addEntries(
            json.entries.map((e) => MapEntry(e.key, e.value as String)),
          );
      } on FormatException {
        _bindings.clear();
      }
    }
  }

  List<BotProfile> list() =>
      _profiles.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  BotProfile? get(String id) => _profiles[id];

  BotProfile? botFor(String sessionId) {
    final botId = _bindings[sessionId];
    return botId == null ? null : _profiles[botId];
  }

  String? boundBotId(String sessionId) => _bindings[sessionId];

  Future<BotProfile> create({
    required String id,
    required String name,
    String persona = '',
    String? model,
    String greeting = '',
  }) async {
    final profile = BotProfile(
      id: id,
      name: name,
      persona: persona,
      model: model,
      greeting: greeting,
    );
    _profiles[id] = profile;
    await _writeProfile(profile);
    return profile;
  }

  Future<BotProfile> update(
    String id,
    BotProfile Function(BotProfile) mutate,
  ) async {
    final updated = mutate(_profiles[id]!);
    _profiles[id] = updated;
    await _writeProfile(updated);
    return updated;
  }

  Future<void> delete(String id) async {
    _profiles.remove(id);
    final file = File(p.join(botsDir, '$id.json'));
    if (await file.exists()) await file.delete();
    final bound = _bindings.entries
        .where((e) => e.value == id)
        .map((e) => e.key)
        .toList();
    for (final sessionId in bound) {
      _bindings.remove(sessionId);
    }
    if (bound.isNotEmpty) await _writeBindings();
  }

  Future<void> bind(String sessionId, String botId) async {
    _bindings[sessionId] = botId;
    await _writeBindings();
  }

  Future<void> unbind(String sessionId) async {
    final removed = _bindings.remove(sessionId);
    if (removed != null) await _writeBindings();
  }

  Future<void> _writeProfile(BotProfile profile) async {
    final dir = Directory(botsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(p.join(botsDir, '${profile.id}.json'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(profile.toJson()),
    );
    await tmp.rename(target.path);
  }

  Future<void> _writeBindings() async {
    final dir = Directory(botsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(bindingsPath);
    final tmp = File('$bindingsPath.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ')
        .convert(Map<String, String>.from(_bindings)));
    await tmp.rename(target.path);
  }
}
