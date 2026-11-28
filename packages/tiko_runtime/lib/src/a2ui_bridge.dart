/// A2UI surface bridge (Fase E) — jembatan tool/render protokol A2UI v1.0 ke
/// runtime Tiko: state surface per sesi, penyimpanan atomik di disk
/// (`<dataDir>/surfaces/`), event bus (`surface.created/updated/deleted`),
/// dan konsumsi aksi anti-replay.
///
/// fail-closed: kegagalan parse/apply tidak pernah mengunci turn — event
/// `surface.rejected` dipancarkan dan pemanggil memutuskan fallback.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

final RegExp _unsafePathChars = RegExp(r'[^A-Za-z0-9_.\-]');

/// Menyimpan satu snapshot surface A2UI: perwakilan file di disk.
class A2uiSurfaceRecord {
  A2uiSurfaceRecord({
    required this.surfaceId,
    required this.sessionKey,
    required this.updatedAt,
    required this.body,
  });

  final String surfaceId;
  final String sessionKey;
  final DateTime updatedAt;

  /// `{"surfaceId", "catalogId", "components", "dataModel"}`.
  final Map<String, dynamic> body;

  Map<String, dynamic> toJson({bool includeBody = false}) => {
        'surfaceId': surfaceId,
        'sessionKey': sessionKey,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (includeBody) 'body': body,
      };

  Map<String, dynamic> get renderBody {
    final out = Map<String, dynamic>.from(body);
    out['sessionKey'] = sessionKey;
    out['updatedAt'] = updatedAt.toUtc().toIso8601String();
    return out;
  }
}

class A2uiToolBridge {
  A2uiToolBridge({
    required String dataDir,
    this.onEvent,
    this.ttl = const Duration(days: 7),
    this.maxStored = 256,
  }) : root = p.join(dataDir, 'surfaces') {
    _loadIndex();
  }

  /// Emits `surface.created|updated|deleted|rejected` — biasanya
  /// `runtime.events.emit` sehingga event memantul ke WS `/v1/stream`.
  final void Function(String type, [Map<String, dynamic>? data])? onEvent;
  final Duration ttl;
  final int maxStored;
  final String root;

  final Map<String, A2uiSurfaceSet> _sessions = {};
  final Map<String, A2uiSurfaceRecord> _index = {};

  Directory get _rootDir => Directory(root);

  A2uiSurfaceSet sessionSet(String sessionKey) {
    if (_sessions.length >= 64 && !_sessions.containsKey(sessionKey)) {
      _sessions.remove(_sessions.keys.first);
    }
    return _sessions.putIfAbsent(sessionKey, A2uiSurfaceSet.new);
  }

  static String _sanitizeSession(String sessionKey) =>
      sessionKey.replaceAll(_unsafePathChars, '_').substring(
            0,
            sessionKey.length > 64 ? 64 : sessionKey.length,
          );

  String _fileFor(String sessionKey, String surfaceId) =>
      p.join(root, _sanitizeSession(sessionKey), '$surfaceId.json');

  String get _indexPath => p.join(root, 'index.json');

  void _loadIndex() {
    try {
      final f = File(_indexPath);
      if (!f.existsSync()) return;
      final raw =
          (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['items']
              as List<dynamic>? ?? const [];
      for (final item in raw) {
        if (item is! Map) continue;
        final record = A2uiSurfaceRecord(
          surfaceId: item['surfaceId'].toString(),
          sessionKey: item['sessionKey'].toString(),
          updatedAt: DateTime.tryParse(item['updatedAt'].toString()) ??
              DateTime.now().toUtc(),
          body: item['body'] is Map
              ? Map<String, dynamic>.from(item['body'] as Map)
              : <String, dynamic>{},
        );
        _index[record.surfaceId] = record;
      }
    } catch (_) {
      // Fail-closed: index rusak diabaikan; file per surface tetap ada.
    }
  }

  void _persistIndex() {
    try {
      _rootDir.createSync(recursive: true);
      final tmp = File('$_indexPath.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'items': _index.values
            .map((r) => r.toJson(
                  includeBody: false,
                ))
            .toList(),
      }));
      tmp.renameSync(_indexPath);
    } catch (_) {} // best-effort
  }

  void _prune([DateTime? now]) {
    final effective = now ?? DateTime.now().toUtc();
    final expired = [
      for (final r in _index.values)
        if (effective.difference(r.updatedAt) > ttl) r.surfaceId,
    ];
    for (final id in expired) {
      final record = _index.remove(id);
      if (record != null) {
        try {
          File(_fileFor(record.sessionKey, id)).deleteSync();
        } catch (_) {} // best-effort
      }
    }
    while (_index.length > maxStored) {
      final oldest = _index.keys.first;
      final record = _index.remove(oldest);
      try {
        if (record != null) File(_fileFor(record.sessionKey, oldest)).deleteSync();
      } catch (_) {} // best-effort
    }
  }

  /// Menerapkan pesan A2UI tervalidasi ke state sesi, menyimpan snapshot,
  /// dan memancarkan event. Melempar [FormatException] bila urutan pesan
  /// tidak valid (pemanggil menangkap dan tidak mengunci turn).
  List<A2uiSurfaceChange> ingest(
    String sessionKey,
    List<A2uiMessage> messages,
  ) {
    _prune();
    try {
      // Validasi dulu ke set scratch (salinan state sesi) agar state tidak
      // berubah parsial bila pesan di tengah batch tidak valid (atomik,
      // fail-closed).
      sessionSet(sessionKey).clone().apply(messages);
      final changes = sessionSet(sessionKey).apply(messages);
      for (final change in changes) {
        final surface = sessionSet(sessionKey).surface(change.surfaceId);
        if (surface == null) {
          _removeRecord(sessionKey, change.surfaceId);
          onEvent?.call(change.event, {
            'surfaceId': change.surfaceId,
            'sessionKey': sessionKey,
          });
          continue;
        }
        _saveSnapshot(sessionKey, surface);
        onEvent?.call(change.event, {
          'surfaceId': change.surfaceId,
          'sessionKey': sessionKey,
          'origin': 'model',
          'catalogId': surface.catalogId,
        });
      }
      return changes;
    } on FormatException catch (e) {
      onEvent?.call('surface.rejected', {
        'sessionKey': sessionKey,
        'reason': e.message,
      });
      rethrow;
    }
  }

  void _saveSnapshot(String sessionKey, A2uiSurface surface) {
    final record = A2uiSurfaceRecord(
      surfaceId: surface.surfaceId,
      sessionKey: sessionKey,
      updatedAt: DateTime.now().toUtc(),
      body: {
        'surfaceId': surface.surfaceId,
        'catalogId': surface.catalogId,
        'components':
            surface.components.values.map((c) => c.toJson()).toList(),
        'dataModel': surface.dataModel,
      },
    );
    _index[surface.surfaceId] = record;
    try {
      final file = File(_fileFor(sessionKey, surface.surfaceId));
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(record.renderBody));
      tmp.renameSync(file.path);
    } catch (_) {} // best-effort
    _persistIndex();
  }

  void _removeRecord(String sessionKey, String surfaceId) {
    final record = _index.remove(surfaceId);
    try {
      File(_fileFor(record?.sessionKey ?? sessionKey, surfaceId))
          .deleteSync();
    } catch (_) {} // best-effort
    _persistIndex();
  }

  /// Daftar surface tersimpan; [sessionKey] opsional sebagai filter.
  List<Map<String, dynamic>> list([String? sessionKey]) {
    _prune();
    return [
      for (final r in _index.values)
        if (sessionKey == null || r.sessionKey == sessionKey)
          r.toJson(),
    ];
  }

  /// Isi lengkap surface (komponen + data model) bila ada.
  Map<String, dynamic>? get(String surfaceId) {
    _prune();
    return _index[surfaceId]?.renderBody;
  }

  Future<bool> delete(String surfaceId) async {
    final record = _index.remove(surfaceId);
    if (record == null) return false;
    try {
      File(_fileFor(record.sessionKey, surfaceId)).deleteSync();
    } catch (_) {} // best-effort
    _persistIndex();
    onEvent?.call('surface.deleted', {
      'surfaceId': surfaceId,
      'sessionKey': record.sessionKey,
      'origin': 'host',
    });
    return true;
  }

  /// Pre-check aksi TANPA mengonsumsi (host dapat memvalidasi sebelum
  /// mengeksekusi). Fail-closed: hanya aksi yang dideklarasikan komponen
  /// surface yang valid — tidak ada fallback generik.
  bool validateAction(
    String sessionKey,
    String surfaceId,
    String actionName,
  ) =>
      sessionSet(sessionKey).validateAction(surfaceId, actionName);

  /// Validasi + konsumsi (anti-replay) aksi A2UI dari `POST /v1/ui/actions`.
  /// Penolakan memancarkan event `surface.action_rejected` (observabilitas).
  bool consumeAction(
    String sessionKey,
    String surfaceId,
    String actionName,
  ) {
    final ok = sessionSet(sessionKey).consumeAction(surfaceId, actionName);
    if (!ok) {
      onEvent?.call('surface.action_rejected', {
        'surfaceId': surfaceId,
        'sessionKey': sessionKey,
        'action': actionName,
      });
    }
    return ok;
  }

  /// Update input form (Fase E6): tulis nilai [value] ke data model bila
  /// properti `value` komponen terikat `@path`, simpan snapshot, dan
  /// kembalikan (action: nama aksi `onChanged` komponen bila ada, path:
  /// path data model yang ditulis bila ada). Melempar [FormatException]
  /// bila surface/komponen tidak valid atau nilai salah tipe.
  ({String? action, String? path}) applyInput(
    String sessionKey,
    String surfaceId,
    String componentId,
    Object? value,
  ) {
    _prune();
    if (sessionSet(sessionKey).surface(surfaceId) == null) {
      throw FormatException(
          'a2ui: surface "$surfaceId" tidak ada untuk sesi ini');
    }
    final path = sessionSet(sessionKey).writeInputValue(
      surfaceId,
      componentId,
      value,
    );
    final surface = sessionSet(sessionKey).surface(surfaceId);
    if (surface != null) _saveSnapshot(sessionKey, surface);
    onEvent?.call('surface.updated', {
      'surfaceId': surfaceId,
      'sessionKey': sessionKey,
      'origin': 'input',
    });
    final target =
        sessionSet(sessionKey).inputTargetOf(surfaceId, componentId);
    return (action: target?.actionName, path: path);
  }
}
