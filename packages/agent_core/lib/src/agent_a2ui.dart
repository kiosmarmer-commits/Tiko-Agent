/// A2UI (Agent-to-UI) v1.0 — model pesan & validasi fail-closed milik Tiko.
///
/// Implementasi ini mengikuti spesifikasi A2UI v1.0 resmi
/// (https://a2ui.org/specification/v1.0-a2ui/ — Apache-2.0): UI dikirim agen
/// sebagai **data bukan kode** lewat aliran pesan JSON berurutan, dirender
/// host dengan katalog komponen native.
///
/// Empat pesan mutasi yang didukung (envelope `version: "1.0"`):
/// - `createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`.
/// Pesan fungsi dua arah (`callRendererFunction`, `agentFunctionResponse`,
/// `rendererFunctionResponse`, `callAgentFunction`) **belum diadopsi** —
/// ditolak dengan pesan jelas (bukan diabaikan diam-diam).
///
/// Prinsip keamanan (selaras Fase E, docs/14-A2UI-GENERATIVE-UI.md):
/// - **Agen tidak tepercaya**: hanya komponen whitelist katalog Tiko yang
///   lolos; kunci/komponen tak dikenal ditolak, bukan dilewati.
/// - **Fail-closed**: pelanggaran apa pun melempar [FormatException]; host
///   merender pesan error, tidak pernah UI setengah jadi.
/// - **Tanpa eksekusi kode**: aksi hanyalah nama + payload yang diteruskan
///   ke pipeline tool/approvals; tidak ada eval perintah.
/// - Batas ketat: jumlah pesan/komponen/kedalaman/teks/aksi per pemanggilan.
///
/// Murni Dart tanpa dependensi Flutter sehingga validasi bisa jalan di sisi
/// agen (tool `render_a2ui`) maupun sisi klien.
library;

import 'dart:convert';

import 'genui.dart';

/// Versi protokol yang diadopsi Tiko.
const String a2uiVersion = '1.0';

/// Batas struktural (Fase E §6.1).
const int a2uiMaxMessages = 24;
const int a2uiMaxNodes = 120;
const int a2uiMaxDepth = 8;
const int a2uiMaxTextChars = 4000;
const int a2uiMaxLabelChars = 200;
const int a2uiMaxActions = 8;
const int a2uiMaxSurfaces = 8;
const int a2uiMaxChartPoints = 31;
const int a2uiMaxOptions = 16;
const int a2uiMaxTabs = 8;
const int a2uiMaxChildren = 20;
const int a2uiMaxFenceBytes = 24 * 1024;
const int a2uiMaxBlocksPerMessage = genuiMaxBlocksPerMessage;

/// Kunci pesan mutasi v1.0 yang didukung.
const Set<String> a2uiSupportedKeys = {
  'createSurface',
  'updateComponents',
  'updateDataModel',
  'deleteSurface',
};

/// Kunci pesan RPC dua arah v1.0 yang belum didukung Fase E.
const Set<String> a2uiUnsupportedKeys = {
  'callRendererFunction',
  'rendererFunctionResponse',
  'callAgentFunction',
  'agentFunctionResponse',
};

/// Katalog yang di-whitelist Tiko (Fase E §8.5).
const Set<String> a2uiAllowedCatalogIds = {
  'tiko.basic.v1',
  'tiko.charts.v1',
  'tiko.kanban.v1',
};

/// Kunci body yang diperbolehkan per jenis pesan; kunci lain ditolak
/// (mis. `sendDataModel` streaming dua arah belum diadopsi Fase E).
const Map<String, Set<String>> a2uiBodyKeys = {
  'createSurface': {'surfaceId', 'catalogId', 'components', 'dataModel'},
  'updateComponents': {'surfaceId', 'components'},
  'updateDataModel': {'surfaceId', 'path', 'value'},
  'deleteSurface': {'surfaceId'},
};

/// Katalog default bila surface tidak menyebut `catalogId`.
const String a2uiDefaultCatalogId = 'tiko.basic.v1';

/// Whitelist tipe komponen (katalog dasar A2UI + katalog kustom Tiko).
const Set<String> a2uiAllowedComponents = {
  'Row',
  'Column',
  'Card',
  'Divider',
  'Text',
  'Image',
  'Icon',
  'Button',
  'TextField',
  'CheckBox',
  'ChoicePicker',
  'Slider',
  'DateTimeInput',
  'Metric',
  'Chart',
  'KanbanCard',
  'ApprovalSheet',
  'List',
  'Tabs',
  'Modal',
  'Video',
  'AudioPlayer',
};

final RegExp _a2uiSafeId = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');
final RegExp _a2uiActionName = RegExp(r'^[a-z][a-z0-9_]{1,64}$');
final RegExp _a2uiControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
final RegExp _a2uiIconName = RegExp(r'^[a-z0-9_]{1,64}$');
final RegExp _a2uiDataPointer = RegExp(r'^/([A-Za-z0-9_.\-]+(/[A-Za-z0-9_.\-]+)*)?$');

/// Kunci struktur umum yang tersedia pada semua komponen.
const Set<String> _commonComponentKeys = {
  'child',
  'children',
  '@catalogId',
  '@checks',
  '@accessibility',
};

/// Kunci properti per tipe komponen; kunci lain ditolak (§8.2).
const Map<String, Set<String>> _a2uiComponentKeys = {
  'Row': {'justify', 'align', 'weight'},
  'Column': {'justify', 'align', 'weight'},
  'Card': {},
  'Divider': {'axis'},
  'Text': {'text', 'variant'},
  'Image': {'src', 'fit'},
  'Icon': {'name'},
  'Button': {'label', 'action', 'variant'},
  'TextField': {'label', 'value', 'variant', 'placeholder', 'action'},
  'CheckBox': {'label', 'value', 'action'},
  'ChoicePicker': {'label', 'options', 'value', 'action'},
  'Slider': {'label', 'min', 'max', 'step', 'value', 'action'},
  'DateTimeInput': {'label', 'value', 'action'},
  'Metric': {'label', 'value', 'delta', 'tone'},
  'Chart': {'kind', 'points'},
  'KanbanCard': {'title', 'status', 'detail'},
  'ApprovalSheet': {'risk', 'summary', 'commands'},
  'List': {'axis'},
  'Tabs': {'labels'},
  'Modal': {'title'},
  'Video': {'src', 'poster'},
  'AudioPlayer': {'src', 'loop'},
};

const Set<String> _a2uiButtonVariants = {'primary', 'secondary', 'danger'};
const Set<String> _a2uiTones = {'primary', 'neutral', 'error'};
const Set<String> _a2uiApprovalRisks = {'low', 'medium', 'high'};
const Set<String> _a2uiChartKinds = {
  'bar',
  'line',
  'area',
  'donut',
  'pie',
  'scatter',
  'hbar',
};
const Set<String> _a2uiTextVariants = {'heading', 'body', 'caption', 'mono'};

/// Komponen input form (Fase E6): aksinya repeatable — tiap perubahan isian
/// dikirim ulang ke host (beda dengan aksi tombol yang sekali pakai).
const Set<String> _a2uiInputComponents = {
  'TextField',
  'CheckBox',
  'ChoicePicker',
  'Slider',
  'DateTimeInput',
};

/// Target tulis-balik satu komponen input (Fase E6).
class A2uiInputTarget {
  const A2uiInputTarget(this.type, this.boundPath, {this.actionName});

  final String type;

  /// Path data model bila properti `value` terikat `@path`, selain itu null.
  final String? boundPath;

  /// Nama aksi `onChanged` (repeatable) bila komponen membawa `action`.
  final String? actionName;
}

/// Satu aksi tombol yang tervalidasi: `{"name": ..., "payload": {...}}`.
class A2uiAction {
  A2uiAction._(this.name, this.payload);

  final String name;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {'name': name, 'payload': payload};
}

/// Komponen flat gaya A2UI v1.0: `id` + `component` + properti, children
/// menunjuk id komponen lain (adjacency list, bukan nesting).
class A2uiComponent {
  A2uiComponent._(
    this.id,
    this.type,
    this.properties,
    this.childId,
    this.childIds,
  );

  final String id;
  final String type;

  /// Properti non-struktural yang sudah tervalidasi.
  final Map<String, dynamic> properties;
  final String? childId;
  final List<String> childIds;

  /// Aksi tombol bila komponen punya properti `action` valid.
  A2uiAction? get action {
    final raw = properties['action'];
    if (raw is! Map<String, dynamic>) return null;
    final name = raw['name'];
    if (name is! String) return null;
    final payloadRaw = raw['payload'];
    final payload = payloadRaw is Map<String, dynamic>
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};
    return A2uiAction._(name, payload);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'component': type,
        ...properties,
        if (childId != null) 'child': childId,
        if (childIds.isNotEmpty) 'children': childIds,
      };
}

/// Pesan A2UI v1.0 yang sudah tervalidasi (sealed untuk pewarisan aman).
sealed class A2uiMessage {
  const A2uiMessage();

  Map<String, dynamic> toJson() {
    final payload = body();
    return {'version': a2uiVersion, ...payload};
  }

  Map<String, dynamic> body();

  /// surfaceId yang jadi sasaran pesan (untuk event bus / store).
  String get surfaceId;
}

class A2uiCreateSurface extends A2uiMessage {
  const A2uiCreateSurface({
    required this.surfaceId,
    this.catalogId = a2uiDefaultCatalogId,
    this.components = const [],
    this.dataModel,
  });

  final String surfaceId;
  final String catalogId;
  final List<A2uiComponent> components;
  final Map<String, dynamic>? dataModel;

  @override
  Map<String, dynamic> body() => {
        'createSurface': {
          'surfaceId': surfaceId,
          'catalogId': catalogId,
          if (components.isNotEmpty)
            'components': components.map((c) => c.toJson()).toList(),
          if (dataModel != null) 'dataModel': dataModel,
        },
      };
}

class A2uiUpdateComponents extends A2uiMessage {
  const A2uiUpdateComponents({required this.surfaceId, required this.components});

  final String surfaceId;
  final List<A2uiComponent> components;

  @override
  Map<String, dynamic> body() => {
        'updateComponents': {
          'surfaceId': surfaceId,
          'components': components.map((c) => c.toJson()).toList(),
        },
      };
}

class A2uiUpdateDataModel extends A2uiMessage {
  const A2uiUpdateDataModel({
    required this.surfaceId,
    required this.path,
    required this.value,
  });

  final String surfaceId;
  final String path;
  final dynamic value;

  @override
  Map<String, dynamic> body() => {
        'updateDataModel': {
          'surfaceId': surfaceId,
          'path': path,
          'value': value,
        },
      };
}

class A2uiDeleteSurface extends A2uiMessage {
  const A2uiDeleteSurface({required this.surfaceId});

  final String surfaceId;

  @override
  Map<String, dynamic> body() => {
        'deleteSurface': {'surfaceId': surfaceId},
      };
}

/// Mem-parse payload tool / isi fence `a2ui` menjadi daftar pesan tervalidasi.
///
/// Menerima: JSON array berisi envelope, JSONL (satu envelope per baris),
/// objek envelope tunggal, atau struktur Dart yang sudah didekode.
/// Melempar [FormatException] dengan pesan berbahasa Indonesia pada
/// pelanggaran pertama.
List<A2uiMessage> parseA2uiMessages(Object? raw, {int? maxMessages}) {
  final limit = maxMessages ?? a2uiMaxMessages;
  List<dynamic> items;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('a2ui: payload kosong');
    }
    if (trimmed.startsWith('[')) {
      try {
        items = jsonDecode(trimmed) as List<dynamic>;
      } catch (_) {
        throw const FormatException('a2ui: bukan JSON array yang valid');
      }
    } else {
      items = <dynamic>[];
      for (final line in const LineSplitter().convert(trimmed)) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('//')) continue;
        try {
          items.add(jsonDecode(l));
        } catch (e) {
          throw FormatException('a2ui: baris JSONL tidak valid ($e)');
        }
      }
    }
  } else if (raw is List) {
    items = raw;
  } else if (raw is Map) {
    items = [raw];
  } else {
    throw const FormatException('a2ui: payload harus array, objek, atau JSONL');
  }
  return _validateEnvelopeList(items, limit);
}

List<A2uiMessage> _validateEnvelopeList(List<dynamic> items, int limit) {
  if (items.isEmpty) {
    throw const FormatException('a2ui: tidak ada pesan');
  }
  if (items.length > limit) {
    throw FormatException('a2ui: jumlah pesan melebihi $limit');
  }
  final messages = <A2uiMessage>[];
  final nodesPerSurface = <String, int>{};
  final actionsPerSurface = <String, Set<String>>{};
  final componentsFromCreate = <String, Set<String>>{};
  for (final item in items) {
    if (item is! Map) {
      throw const FormatException('a2ui: tiap pesan harus objek JSON');
    }
    final envelope = _stringKeyMap(item);
    final version = envelope['version'];
    if (version != null && version != a2uiVersion) {
      throw FormatException(
          'a2ui: version harus "$a2uiVersion" (dapat: $version)');
    }
    for (final k in envelope.keys) {
      if (k == 'version') continue;
      if (a2uiUnsupportedKeys.contains(k)) {
        throw FormatException(
            'a2ui: pesan "$k" belum didukung Tiko (Fase E hanya mutasi UI)');
      }
      if (!a2uiSupportedKeys.contains(k)) {
        throw FormatException('a2ui: kunci pesan tidak dikenal "$k"');
      }
    }
    final keys = a2uiSupportedKeys.where(envelope.containsKey).toList();
    if (keys.length != 1) {
      throw const FormatException(
          'a2ui: envelope harus punya tepat satu kunci pesan');
    }
    final k = keys.first;
    final knownBodyKeys = a2uiBodyKeys[k]!;
    for (final key in (envelope[k] as Map).keys) {
      if (!knownBodyKeys.contains(key)) {
        throw FormatException(
            'a2ui: kunci "$key" tidak dikenal pada pesan "$k"');
      }
    }
    final bodyRaw = envelope[k];
    if (bodyRaw is! Map) {
      throw FormatException('a2ui: "$k" harus objek');
    }
    final body = _stringKeyMap(bodyRaw);
    messages.add(_parseMessageBody(
        k, body, nodesPerSurface, actionsPerSurface, componentsFromCreate));
  }
  return messages;
}

String _parseSurfaceId(Map<String, dynamic> body) {
  final id = body['surfaceId'];
  if (id is! String || !_a2uiSafeId.hasMatch(id)) {
    throw const FormatException(
        'a2ui: surfaceId wajib [A-Za-z0-9_.-] 1-64 karakter');
  }
  return id;
}

A2uiMessage _parseMessageBody(
  String kind,
  Map<String, dynamic> body,
  Map<String, int> nodesPerSurface,
  Map<String, Set<String>> actionsPerSurface,
  Map<String, Set<String>> componentsFromCreate,
) {
  final surfaceId = _parseSurfaceId(body);
  switch (kind) {
    case 'createSurface':
      if (body.containsKey('catalogId')) {
        final catalog = body['catalogId'];
        if (catalog is! String || !a2uiAllowedCatalogIds.contains(catalog)) {
          throw FormatException(
              'a2ui: catalogId harus salah satu dari $a2uiAllowedCatalogIds');
        }
      }
      final rawComponents = body['components'] ?? const [];
      if (rawComponents is! List) {
        throw const FormatException('a2ui: components harus array');
      }
      final rawModel = body['dataModel'];
      if (rawModel != null && rawModel is! Map) {
        throw const FormatException('a2ui: dataModel harus objek');
      }
      final components = _parseComponentList(
        rawComponents,
        surfaceId,
        nodesPerSurface,
        actionsPerSurface,
        allowRootLoop: true,
      );
      final ids = components.map((c) => c.id).toSet();
      if (!ids.contains('root')) {
        throw const FormatException('a2ui: createSurface wajib memuat "root"');
      }
      componentsFromCreate[surfaceId] = ids;
      return A2uiCreateSurface(
        surfaceId: surfaceId,
        catalogId: body['catalogId'] as String? ?? a2uiDefaultCatalogId,
        components: components,
        dataModel:
            rawModel == null ? null : Map<String, dynamic>.from(rawModel),
      );
    case 'updateComponents':
      final rawComponents = body['components'];
      if (rawComponents is! List || rawComponents.isEmpty) {
        throw const FormatException('a2ui: components wajib array non-kosong');
      }
      final components = _parseComponentList(
        rawComponents,
        surfaceId,
        nodesPerSurface,
        actionsPerSurface,
        allowRootLoop: false,
      );
      return A2uiUpdateComponents(surfaceId: surfaceId, components: components);
    case 'updateDataModel':
      final path = body['path'];
      if (path != null && (path is! String || path.isEmpty || path.length > 256)) {
        throw const FormatException('a2ui: path wajib string 1-256 karakter');
      }
      if (path is String && path != '/' && !_a2uiDataPointer.hasMatch(path)) {
        throw FormatException('a2ui: path bukan JSON Pointer valid: $path');
      }
      if (!body.containsKey('value')) {
        throw const FormatException('a2ui: updateDataModel wajib punya value');
      }
      return A2uiUpdateDataModel(
        surfaceId: surfaceId,
        path: path is String ? path : '/',
        value: _sanitizeDataValue(body['value'], 0),
      );
    case 'deleteSurface':
      componentsFromCreate.remove(surfaceId);
      nodesPerSurface.remove(surfaceId);
      actionsPerSurface.remove(surfaceId);
      return A2uiDeleteSurface(surfaceId: surfaceId);
    default:
      throw FormatException('a2ui: kunci pesan tidak dikenal "$kind"');
  }
}

Map<String, dynamic> _stringKeyMap(Map<dynamic, dynamic> raw) =>
    raw.map((k, v) => MapEntry(k.toString(), v));

dynamic _sanitizeDataValue(dynamic v, int depth) {
  if (depth > 8) {
    throw const FormatException('a2ui: data value terlalu dalam');
  }
  if (v == null || v is String || v is num || v is bool) {
    if (v is String && v.length > a2uiMaxTextChars) {
      throw FormatException(
          'a2ui: string data melebihi $a2uiMaxTextChars karakter');
    }
    return v;
  }
  if (v is Map) {
    return v.map((k, val) => MapEntry(
        k.toString(), _sanitizeDataValue(val, depth + 1)));
  }
  if (v is List) {
    if (v.length > 200) {
      throw const FormatException('a2ui: array data melebihi 200 elemen');
    }
    return v.map((e) => _sanitizeDataValue(e, depth + 1)).toList();
  }
  throw FormatException('a2ui: value tidak didukung (${v.runtimeType})');
}

List<A2uiComponent> _parseComponentList(
  List<dynamic> rawComponents,
  String surfaceId,
  Map<String, int> nodesPerSurface,
  Map<String, Set<String>> actionsPerSurface, {
  required bool allowRootLoop,
}) {
  final out = <A2uiComponent>[];
  final ids = <String>{};
  for (final raw in rawComponents) {
    if (raw is! Map) {
      throw const FormatException('a2ui: komponen harus objek JSON');
    }
    final map = _stringKeyMap(raw);
    final id = map['id'];
    if (id is! String || !_a2uiSafeId.hasMatch(id)) {
      throw const FormatException(
          'a2ui: component.id wajib [A-Za-z0-9_.-] 1-64 karakter');
    }
    if (!ids.add(id)) {
      throw FormatException('a2ui: component.id "$id" duplikat dalam pesan');
    }
    final type = map['component'] ?? map['type'];
    if (type is! String || !a2uiAllowedComponents.contains(type)) {
      throw FormatException(
          'a2ui: komponen "$id" memakai tipe tidak dikenal atau di luar '
          'whitelist Tiko (${type ?? 'kosong'})');
    }
    final used = (nodesPerSurface[surfaceId] ?? 0) + 1;
    if (used > a2uiMaxNodes) {
      throw FormatException(
          'a2ui: jumlah komponen surface "$surfaceId" melebihi $a2uiMaxNodes');
    }
    nodesPerSurface[surfaceId] = used;

    for (final key in map.keys) {
      if (key == 'id' || key == 'component' || key == 'type') continue;
      if (!_commonComponentKeys.contains(key) &&
          !(_a2uiComponentKeys[type] ?? const <String>{}).contains(key)) {
        throw FormatException(
            'a2ui: kunci tak dikenal "$key" pada komponen $type');
      }
    }

    String? childId;
    if (map['child'] != null) {
      final c = map['child'];
      if (c is! String || !_a2uiSafeId.hasMatch(c)) {
        throw const FormatException('a2ui: child wajib id komponen valid');
      }
      if (!allowRootLoop && c == 'root') {
        throw const FormatException(
            'a2ui: updateComponents tidak boleh menimpa root');
      }
      childId = c;
    }
    var childIds = const <String>[];
    if (map['children'] != null) {
      final children = map['children'];
      if (children is! List) {
        throw const FormatException('a2ui: children wajib array id');
      }
      if (children.length > a2uiMaxChildren) {
        throw FormatException(
            'a2ui: children maksimal $a2uiMaxChildren elemen');
      }
      final idsList = <String>[];
      for (final c in children) {
        if (c is! String || !_a2uiSafeId.hasMatch(c)) {
          throw const FormatException('a2ui: children wajib berisi id valid');
        }
        if (!allowRootLoop && c == 'root') {
          throw const FormatException(
              'a2ui: updateComponents tidak boleh menimpa root');
        }
        idsList.add(c);
      }
      childIds = idsList;
    }

    final properties = <String, dynamic>{};
    for (final key in map.keys) {
      if (key == 'id' || key == 'component' || key == 'type') continue;
      if (_commonComponentKeys.contains(key)) continue;
      properties[key] = _validateProperty(type, key, map[key]);
    }
    if (properties.containsKey('text') && properties['text'] is String) {
      final text = properties['text'] as String;
      if (_a2uiControlChars.hasMatch(text)) {
        throw const FormatException('a2ui: teks memuat karakter kontrol');
      }
      if (text.length > a2uiMaxTextChars) {
        throw FormatException(
            'a2ui: teks melebihi $a2uiMaxTextChars karakter');
      }
    }
    for (final key in const ['label', 'title', 'placeholder', 'status', 'detail']) {
      final v = properties[key];
      if (v is String) {
        if (v.length > a2uiMaxLabelChars) {
          throw FormatException(
              'a2ui: "$key" melebihi $a2uiMaxLabelChars karakter');
        }
        if (_a2uiControlChars.hasMatch(v)) {
          throw FormatException('a2ui: "$key" memuat karakter kontrol');
        }
      }
    }

    final action = properties['action'];
    if (action != null) {
      final usedActions = actionsPerSurface.putIfAbsent(surfaceId, () => <String>{});
      if (usedActions.length >= a2uiMaxActions &&
          !usedActions.contains(action['name'])) {
        throw FormatException(
            'a2ui: aksi surface "$surfaceId" melebihi $a2uiMaxActions');
      }
      usedActions.add(action['name'] as String);
    }

    out.add(A2uiComponent._(id, type, properties, childId, childIds));
  }
  return out;
}

dynamic _validateProperty(String type, String key, dynamic value) {
  String str(dynamic v) {
    if (v is! String) {
      throw FormatException('a2ui: "$key" pada $type harus string');
    }
    return v;
  }

  Map<String, dynamic> obj(dynamic v) {
    if (v is! Map) {
      throw FormatException('a2ui: "$key" pada $type harus objek');
    }
    return _stringKeyMap(v);
  }

  switch (key) {
    case 'justify':
    case 'align':
      final v = str(value);
      const allowed = {
        'start', 'end', 'center', 'spaceBetween', 'spaceAround', 'stretch',
      };
      if (!allowed.contains(v)) {
        throw FormatException('a2ui: "$key" harus salah satu dari $allowed');
      }
      return v;
    case 'variant':
      final v = str(value);
      if (type == 'Button') {
        if (!_a2uiButtonVariants.contains(v)) {
          throw FormatException(
              'a2ui: variant tombol harus salah satu dari $_a2uiButtonVariants');
        }
        return v;
      }
      if (!_a2uiTextVariants.contains(v)) {
        throw FormatException(
            'a2ui: variant teks harus salah satu dari $_a2uiTextVariants');
      }
      return v;
    case 'axis':
      final v = str(value);
      if (!const {'horizontal', 'vertical'}.contains(v)) {
        throw const FormatException('a2ui: axis horizontal|vertical');
      }
      return v;
    case 'fit':
      final v = str(value);
      if (!const {'cover', 'contain'}.contains(v)) {
        throw const FormatException('a2ui: fit cover|contain');
      }
      return v;
    case 'src':
    case 'poster':
      final v = str(value);
      final okHttp = Uri.tryParse(v)?.scheme == 'https' ||
          Uri.tryParse(v)?.scheme == 'http';
      final okFile = v.startsWith('file://data/uploads/');
      if (!okHttp && !okFile) {
        throw const FormatException(
            'a2ui: src/poster hanya https/http atau file://data/uploads/**');
      }
      if (v.length > 2048) {
        throw const FormatException('a2ui: src/poster maksimal 2048 karakter');
      }
      return v;
    case 'loop':
      if (value is! bool) {
        throw const FormatException('a2ui: loop harus boolean');
      }
      return value;
    case 'name':
      final v = str(value);
      if (!_a2uiIconName.hasMatch(v)) {
        throw const FormatException('a2ui: Icon.name wajib [a-z0-9_] 1-64');
      }
      return v;
    case 'text':
    case 'label':
    case 'title':
    case 'placeholder':
    case 'status':
    case 'detail':
      if (value is String) return value;
      if (value is Map && value.containsKey('@path')) return value;
      throw FormatException(
          'a2ui: "$key" pada $type harus string atau @path');
    case '@path':
      throw const FormatException('a2ui: @path bukan properti level');
    case 'value':
      if (value is String && value.length > a2uiMaxTextChars) {
        throw FormatException(
            'a2ui: value melebihi $a2uiMaxTextChars karakter');
      }
      if (value is String ||
          value is num ||
          value is bool ||
          (value is Map && value.containsKey('@path'))) {
        return value;
      }
      throw FormatException(
          'a2ui: "value" pada $type harus string/angka/bool atau @path');
    case 'min':
    case 'max':
    case 'step':
    case 'delta':
    case 'weight':
      if (value is! num) {
        throw FormatException('a2ui: "$key" pada $type harus angka');
      }
      if (key == 'weight' && (value < 0 || value > 100)) {
        throw const FormatException('a2ui: weight 0-100');
      }
      return value;
    case 'tone':
      final v = str(value);
      if (!_a2uiTones.contains(v)) {
        throw FormatException('a2ui: tone harus salah satu dari $_a2uiTones');
      }
      return v;
    case 'labels':
      if (value is! List || value.isEmpty) {
        throw const FormatException(
            'a2ui: Tabs wajib punya labels[] non-kosong');
      }
      if (value.length > a2uiMaxTabs) {
        throw FormatException('a2ui: Tabs maksimal $a2uiMaxTabs tab');
      }
      final labels = <String>[];
      for (final l in value) {
        if (l is! String ||
            l.isEmpty ||
            l.length > a2uiMaxLabelChars ||
            _a2uiControlChars.hasMatch(l)) {
          throw const FormatException(
              'a2ui: label tab harus string non-kosong <= maks');
        }
        labels.add(l);
      }
      return labels;
    case 'kind':
      final v = str(value);
      if (!_a2uiChartKinds.contains(v)) {
        throw FormatException('a2ui: kind harus salah satu dari $_a2uiChartKinds');
      }
      return v;
    case 'points':
      if (value is! List || value.isEmpty) {
        throw const FormatException('a2ui: Chart wajib punya points[]');
      }
      if (value.length > a2uiMaxChartPoints) {
        throw FormatException(
            'a2ui: Chart maksimal $a2uiMaxChartPoints titik');
      }
      final points = <Map<String, dynamic>>[];
      for (final p in value) {
        if (p is! Map) {
          throw const FormatException(
              'a2ui: points harus berisi objek {label, value}');
        }
        final m = _stringKeyMap(p);
        for (final k in m.keys) {
          if (!const {'label', 'value'}.contains(k)) {
            throw FormatException('a2ui: kunci tak dikenal "$k" pada point');
          }
        }
        final label = m['label'];
        if (label is! String ||
            label.isEmpty ||
            label.length > a2uiMaxLabelChars) {
          throw const FormatException(
              'a2ui: point.label wajib string 1-$a2uiMaxLabelChars');
        }
        if (m['value'] is! num) {
          throw const FormatException('a2ui: point.value harus angka');
        }
        points.add({'label': label, 'value': m['value']});
      }
      return points;
    case 'options':
      if (value is! List || value.isEmpty) {
        throw const FormatException('a2ui: ChoicePicker wajib punya options[]');
      }
      if (value.length > a2uiMaxOptions) {
        throw FormatException('a2ui: options maksimal $a2uiMaxOptions');
      }
      final out = <Map<String, dynamic>>[];
      for (final o in value) {
        if (o is! Map) {
          throw const FormatException(
              'a2ui: options harus berisi objek {label, value}');
        }
        final m = _stringKeyMap(o);
        for (final k in m.keys) {
          if (!const {'label', 'value'}.contains(k)) {
            throw FormatException('a2ui: kunci tak dikenal "$k" pada option');
          }
        }
        final label = m['label'];
        if (label is! String ||
            label.isEmpty ||
            label.length > a2uiMaxLabelChars) {
          throw const FormatException('a2ui: option.label wajib string');
        }
        out.add({'label': label, 'value': m['value']?.toString() ?? ''});
      }
      return out;
    case 'risk':
      final v = str(value);
      if (!_a2uiApprovalRisks.contains(v)) {
        throw FormatException(
            'a2ui: risk harus salah satu dari $_a2uiApprovalRisks');
      }
      return v;
    case 'summary':
      if (value is Map && value.containsKey('@path')) return value;
      final v = str(value);
      if (v.length > a2uiMaxTextChars) {
        throw const FormatException(
            'a2ui: summary melebihi $a2uiMaxTextChars karakter');
      }
      if (_a2uiControlChars.hasMatch(v)) {
        throw const FormatException('a2ui: summary memuat karakter kontrol');
      }
      return v;
    case 'commands':
      if (value is! List) {
        throw const FormatException('a2ui: commands harus list string');
      }
      if (value.length > a2uiMaxActions) {
        throw const FormatException(
            'a2ui: commands maksimal $a2uiMaxActions item');
      }
      final commands = <String>[];
      for (final c in value) {
        if (c is! String ||
            c.isEmpty ||
            c.length > a2uiMaxLabelChars) {
          throw const FormatException(
              'a2ui: item commands wajib string 1-$a2uiMaxLabelChars');
        }
        if (_a2uiControlChars.hasMatch(c)) {
          throw const FormatException(
              'a2ui: commands memuat karakter kontrol');
        }
        commands.add(c);
      }
      return commands;
    case 'action':
      final m = obj(value);
      for (final k in m.keys) {
        if (!const {'name', 'payload'}.contains(k)) {
          throw FormatException('a2ui: kunci tak dikenal "$k" pada action');
        }
      }
      final name = m['name'];
      if (name is! String || !_a2uiActionName.hasMatch(name)) {
        throw const FormatException(
            'a2ui: action.name wajib [a-z][a-z0-9_] 2-65 karakter');
      }
      final payloadRaw = m['payload'];
      if (payloadRaw == null) {
        return {'name': name};
      }
      final payload = _sanitizeDataValue(payloadRaw, 0);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('a2ui: action.payload harus objek');
      }
      return {'name': name, 'payload': payload};
    default:
      throw FormatException('a2ui: kunci tak dikenal "$key" pada $type');
  }
}

/// Katalog halus widget / batas untuk flatten — dipakai renderer untuk
/// menghitung kedalaman graf dari root.
int a2uiGraphDepth(Map<String, A2uiComponent> components, String rootId) {
  int depth(String id, Set<String> visited) {
    final node = components[id];
    if (node == null) return 0;
    if (!visited.add(id)) {
      throw FormatException('a2ui: siklus komponen pada "$id"');
    }
    var max = 0;
    final refs = [
      if (node.childId != null) node.childId!,
      ...node.childIds,
    ];
    for (final ref in refs) {
      max = max > depth(ref, visited) ? max : depth(ref, visited) + 1;
    }
    visited.remove(id);
    return 1 + max;
  }

  final d = depth(rootId, {});
  if (d > a2uiMaxDepth) {
    throw FormatException('a2ui: kedalaman UI melebihi $a2uiMaxDepth');
  }
  return d;
}

/// State permukaan yang sudah digabung (komponen + data model).
class A2uiSurface {
  A2uiSurface._(this.surfaceId, this.catalogId, this.components, this.dataModel);

  final String surfaceId;
  final String catalogId;
  final Map<String, A2uiComponent> components;
  Map<String, dynamic> dataModel;
}

/// Hasil penerapan sekumpulan pesan ke permukaan sesi.
class A2uiSurfaceChange {
  const A2uiSurfaceChange(this.surfaceId, this.event);

  final String surfaceId;

  /// 'surface.created' | 'surface.updated' | 'surface.deleted'.
  final String event;
}

/// Status surface per sesi + penerapan pesan (Fase E §6.3: SurfaceStore
/// di-memory; sinkronisasi ke disk dilakukan host).
class A2uiSurfaceSet {
  A2uiSurfaceSet({this.maxSurfaces = a2uiMaxSurfaces});

  final int maxSurfaces;
  final Map<String, A2uiSurface> _surfaces = {};
  final Map<String, Set<String>> _surfaceActions = {};

  /// Nama aksi input (Fase E6) yang boleh dipicu berulang: dihitung ulang
  /// dari pool komponen setelah tiap create/update.
  final Map<String, Set<String>> _surfaceRepeatable = {};

  Map<String, A2uiSurface> get surfaces => Map.unmodifiable(_surfaces);

  A2uiSurface? surface(String surfaceId) => _surfaces[surfaceId];

  Set<String> actionsOf(String surfaceId) =>
      _surfaceActions[surfaceId] ?? const {};

  /// Anti-replay: memakai satu kali hak eksekusi [actionName] pada surface.
  /// Render ulang surface yang memuat aksi tersebut mengaktifkannya kembali.
  /// Aksi input (Fase E6) repeatable: cukup terdaftar, tidak dihabiskan.
  bool consumeAction(String surfaceId, String actionName) {
    final bucket = _surfaceActions[surfaceId];
    if (bucket == null || !bucket.contains(actionName)) return false;
    if (_surfaceRepeatable[surfaceId]?.contains(actionName) ?? false) {
      return true;
    }
    bucket.remove(actionName);
    return true;
  }

  /// Target tulis-balik [componentId] pada surface, atau null bila bukan
  /// komponen input / surface tak dikenal.
  A2uiInputTarget? inputTargetOf(String surfaceId, String componentId) {
    final c = _surfaces[surfaceId]?.components[componentId];
    if (c == null || !_a2uiInputComponents.contains(c.type)) return null;
    final valueProp = c.properties['value'];
    final boundPath = valueProp is Map && valueProp['@path'] is String
        ? valueProp['@path'] as String
        : null;
    return A2uiInputTarget(
      c.type,
      boundPath,
      actionName: c.action?.name,
    );
  }

  /// Tulis balik nilai input (Fase E6) ke data model bila `value` terikat
  /// `@path`; mengembalikan path yang ditulis (null bila tidak terikat).
  /// Melempar [FormatException] bila surface/komponen tak valid atau nilai
  /// tidak sesuai tipe komponen.
  String? writeInputValue(
    String surfaceId,
    String componentId,
    dynamic value,
  ) {
    final target = inputTargetOf(surfaceId, componentId);
    if (target == null) {
      throw FormatException(
          'a2ui: komponen "$componentId" bukan input yang teregister di '
          'surface "$surfaceId"');
    }
    if (!_isValidInputValue(target.type, value)) {
      throw FormatException(
          'a2ui: nilai tidak sesuai tipe komponen ${target.type}');
    }
    if (target.boundPath == null) return null;
    final surface = _surfaces[surfaceId]!;
    surface.dataModel =
        _applyPointer(surface.dataModel, target.boundPath!, value);
    return target.boundPath;
  }

  static bool _isValidInputValue(String type, dynamic v) {
    switch (type) {
      case 'TextField':
      case 'DateTimeInput':
        return v is String &&
            v.isNotEmpty &&
            v.length <= a2uiMaxTextChars &&
            !_hasControlChars(v);
      case 'CheckBox':
        return v is bool;
      case 'ChoicePicker':
        return v is String && v.length <= 256;
      case 'Slider':
        return v is num;
    }
    return false;
  }

  static bool _hasControlChars(String s) =>
      _a2uiControlChars.hasMatch(s);

  /// Salinan mendalam state untuk validasi atomik (scratch set): batch
  /// divalidasi ke salinan ini dulu sebelum diterapkan ke set asli.
  A2uiSurfaceSet clone() {
    final copy = A2uiSurfaceSet(maxSurfaces: maxSurfaces);
    for (final entry in _surfaces.entries) {
      copy._surfaces[entry.key] = A2uiSurface._(
        entry.value.surfaceId,
        entry.value.catalogId,
        Map<String, A2uiComponent>.of(entry.value.components),
        _copyDataModel(entry.value.dataModel),
      );
    }
    for (final entry in _surfaceActions.entries) {
      copy._surfaceActions[entry.key] = {...entry.value};
    }
    for (final entry in _surfaceRepeatable.entries) {
      copy._surfaceRepeatable[entry.key] = {...entry.value};
    }
    return copy;
  }

  /// Menerapkan pesan tervalidasi; melempar [FormatException] bila urutan
  /// tidak valid (mis. update sebelum create, create ganda).
  List<A2uiSurfaceChange> apply(List<A2uiMessage> messages) {
    final changes = <A2uiSurfaceChange>[];
    for (final m in messages) {
      switch (m) {
        case A2uiCreateSurface create:
          if (_surfaces.containsKey(create.surfaceId)) {
            throw FormatException(
                'a2ui: surface "${create.surfaceId}" sudah ada — hapus dulu '
                '(deleteSurface) sebelum membuat ulang');
          }
          if (_surfaces.length >= maxSurfaces) {
            throw FormatException(
                'a2ui: jumlah surface aktif melebihi $maxSurfaces per sesi');
          }
          final map = <String, A2uiComponent>{
            for (final c in create.components) c.id: c,
          };
          if (!map.containsKey('root')) {
            throw const FormatException('a2ui: createSurface wajib memuat "root"');
          }
          a2uiGraphDepth(map, 'root');
          _validateRefs(map);
          _surfaces[create.surfaceId] = A2uiSurface._(
            create.surfaceId,
            create.catalogId,
            map,
            create.dataModel == null
                ? <String, dynamic>{}
                : Map<String, dynamic>.from(create.dataModel!),
          );
          _collectActions(create.surfaceId, create.components);
          _recomputeRepeatable(create.surfaceId);
          changes.add(A2uiSurfaceChange(create.surfaceId, 'surface.created'));
        case A2uiUpdateComponents update:
          final surface = _requireSurface(update.surfaceId);
          for (final c in update.components) {
            surface.components[c.id] = c;
          }
          a2uiGraphDepth(surface.components, 'root');
          _validateRefs(surface.components);
          _collectActions(update.surfaceId, update.components);
          _recomputeRepeatable(update.surfaceId);
          changes
              .add(A2uiSurfaceChange(update.surfaceId, 'surface.updated'));
        case A2uiUpdateDataModel data:
          final surface = _requireSurface(data.surfaceId);
          surface.dataModel = _applyPointer(
            surface.dataModel,
            data.path,
            data.value,
          );
          changes
              .add(A2uiSurfaceChange(data.surfaceId, 'surface.updated'));
        case A2uiDeleteSurface delete:
          _requireSurface(delete.surfaceId);
          _surfaces.remove(delete.surfaceId);
          _surfaceActions.remove(delete.surfaceId);
          _surfaceRepeatable.remove(delete.surfaceId);
          changes
              .add(A2uiSurfaceChange(delete.surfaceId, 'surface.deleted'));
      }
    }
    return changes;
  }

  A2uiSurface _requireSurface(String surfaceId) {
    final surface = _surfaces[surfaceId];
    if (surface == null) {
      throw FormatException(
          'a2ui: surface "$surfaceId" belum dibuat (createSurface dulu)');
    }
    return surface;
  }

  Map<String, dynamic> _copyDataModel(Map<String, dynamic> model) =>
      model.map((k, v) => MapEntry(k, _copyDataValue(v)));

  dynamic _copyDataValue(dynamic v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _copyDataValue(val)));
    }
    if (v is List) {
      return [for (final e in v) _copyDataValue(e)];
    }
    return v;
  }

  void _validateRefs(Map<String, A2uiComponent> components) {
    for (final c in components.values) {
      if (c.childId != null && !components.containsKey(c.childId)) {
        throw FormatException(
            'a2ui: komponen "${c.id}" menunjuk child "${c.childId}" yang '
            'tidak ada');
      }
      if (c.type == 'Tabs') {
        final labels = c.properties['labels'];
        if (labels is! List || labels.length != c.childIds.length) {
          throw FormatException(
              'a2ui: Tabs "${c.id}" wajib labels sejumlah children '
              '(${labels is List ? labels.length : 0} label vs '
              '${c.childIds.length} children)');
        }
      }
      if (c.type == 'Modal') {
        if (c.childIds.isEmpty) {
          throw FormatException(
              'a2ui: Modal "${c.id}" wajib punya minimal satu children');
        }
      }
      for (final ref in c.childIds) {
        if (!components.containsKey(ref)) {
          throw FormatException(
              'a2ui: komponen "${c.id}" menunjuk children "$ref" yang '
              'tidak ada');
        }
      }
    }
  }

  void _collectActions(String surfaceId, List<A2uiComponent> components) {
    final bucket = _surfaceActions.putIfAbsent(surfaceId, () => <String>{});
    for (final c in components) {
      final action = c.action;
      if (action != null) bucket.add(action.name);
      if (bucket.length > a2uiMaxActions) {
        throw FormatException(
            'a2ui: aksi surface "$surfaceId" melebihi $a2uiMaxActions');
      }
    }
  }

  /// Nama = repeatable hanya bila dideklarasikan komponen input dan tidak
  /// ada di komponen non-input mana pun (aksi tombol tetap sekali pakai).
  void _recomputeRepeatable(String surfaceId) {
    final surface = _surfaces[surfaceId];
    if (surface == null) return;
    final counts = <String, int>{};
    final inputNames = <String>{};
    for (final c in surface.components.values) {
      final action = c.action?.name;
      if (action == null) continue;
      counts[action] = (counts[action] ?? 0) + 1;
      if (_a2uiInputComponents.contains(c.type)) inputNames.add(action);
    }
    _surfaceRepeatable[surfaceId] = {
      for (final name in inputNames)
        if ((counts[name] ?? 0) == 1) name,
    };
  }

  static Map<String, dynamic> _applyPointer(
    Map<String, dynamic> model,
    String path,
    dynamic value,
  ) {
    if (path == '/' || path.isEmpty) {
      return value is Map<String, dynamic>
          ? Map<String, dynamic>.from(value)
          : throw const FormatException('a2ui: root data model harus objek');
    }
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    dynamic node = model;
    Map<String, dynamic> container() =>
        node is Map<String, dynamic> ? node : <String, dynamic>{};
    for (var i = 0; i < segments.length; i++) {
      final asMap = container();
      if (i == segments.length - 1) {
        asMap[segments[i]] = value;
      } else {
        final next = asMap[segments[i]];
        asMap[segments[i]] = next is Map<String, dynamic> ? next : <String, dynamic>{};
        node = asMap[segments[i]];
      }
    }
    return model;
  }
}

/// Satu blok ```a2ui yang diekstrak dari teks chat.
class A2uiBlock {
  const A2uiBlock(this.start, this.end, this.messages, {this.complete = true});

  final int start;
  final int end;
  final List<A2uiMessage> messages;

  /// false = fence terakhir masih mengalir (belum tertutup); host
  /// menampilkan skeleton streaming, bukan teks mentah.
  final bool complete;
}

/// Mengekstrak blok fenced ```a2ui (info-string `a2ui` atau `a2ui v1`)
/// dari [text]. Blok tak valid dibiarkan sebagai teks biasa (fail-closed,
/// konsisten dengan [extractGenUiBlocks]). Dengan `includeStreaming` fence
/// terakhir yang belum tertutup dikembalikan sebagai blok `complete: false`
/// (tanpa pesan) agar host menampilkan skeleton saat balasan sedang mengalir.
List<A2uiBlock> extractA2uiBlocks(String text,
    {bool includeStreaming = false}) {
  final blocks = <A2uiBlock>[];
  final pattern = RegExp(r'^```a2ui(?: v1)?[ \t]*\r?\n', multiLine: true);
  for (final open in pattern.allMatches(text)) {
    if (blocks.length >= a2uiMaxBlocksPerMessage) break;
    final closePattern = RegExp(r'^```[ \t]*\r?$', multiLine: true);
    final close = closePattern.firstMatch(text.substring(open.end));
    if (close == null) {
      if (includeStreaming && text.length - open.end <= a2uiMaxFenceBytes) {
        blocks.add(
            A2uiBlock(open.start, text.length, const [], complete: false));
        break;
      }
      continue;
    }
    final body = text.substring(open.end, open.end + close.start);
    if (body.length > a2uiMaxFenceBytes) continue;
    try {
      final messages = parseA2uiMessages(body);
      blocks.add(A2uiBlock(open.start, open.end + close.end, messages));
    } on FormatException {
      continue;
    }
  }
  return blocks;
}

/// Memecah teks chat menjadi segmen teks biasa dan blok UI A2UI berurutan.
/// Segmen berupa `String`, `List<A2uiMessage>` (blok tuntas), atau
/// [A2uiBlock] dengan `complete: false` (masih mengalir).
List<Object> splitA2uiSegments(String text, {bool includeStreaming = false}) {
  final blocks =
      extractA2uiBlocks(text, includeStreaming: includeStreaming);
  if (blocks.isEmpty) return [text];
  final segments = <Object>[];
  var cursor = 0;
  for (final b in blocks) {
    if (b.start > cursor) segments.add(text.substring(cursor, b.start));
    segments.add(b.complete ? b.messages : b);
    cursor = b.end;
  }
  if (cursor < text.length) segments.add(text.substring(cursor));
  return segments;
}

/// Tambahan system-prompt untuk mengajari model protokol A2UI versi Tiko.
/// Disuntik host bila generative UI aktif pada percakapan tersebut.
String tikoA2uiSystemPromptAddon() => '''
## Antarmuka generatif: A2UI v1.0 (Tiko)
Kamu bisa membuat UI interaktif dengan tool `render_a2ui` atau blok fence \`\`\`a2ui.
Pesan berformat A2UI v1.0: {"version":"1.0","createSurface":{...}} dst. Komponen FLAT per id:
{"id":"root","component":"Column","children":["t1","b1"]}.
Whitelist komponen: Row, Column, Card, Divider, Text, Image, Icon, Button, TextField,
CheckBox, ChoicePicker, Slider, DateTimeInput, Metric, Chart, KanbanCard, ApprovalSheet,
List (axis horizontal|vertical), Tabs (labels sejumlah children, maks 8),
Modal (title string, konten hanya terlihat setelah pengguna membukanya
— host yang mengontrol tampilan, agen tidak dapat memaksa dialog terbuka).
- createSurface wajib tepat satu komponen id "root"; updateComponents untuk memperbarui.
- updateDataModel {"path":"/a/b","value":...} untuk data; teks komponen bisa
  berupa {"@path":"/a/b"} terikat data model.
- Tombol: {"component":"Button","label":"Proses","action":{"name":"nama_aksi","payload":{}}}.
  action.name = snake_case 2-65 karakter; payload kecil; aksi diteruskan ke pipeline
  tool/approvals Tiko (bukan eksekusi langsung).
Batas: 24 pesan/panggilan, 120 komponen/surface, depth 8, teks 4000 char, 8 aksi/surface.
Untuk ringkasan angka gunakan Metric; untuk seri waktu gunakan Chart (kind
bar|line|area|donut, maks 31 titik).
Untuk permintaan persetujuan berisiko gunakan ApprovalSheet (risk low|medium|high,
summary, commands[] berupa string); tombol setuju/tolak tetap komponen Button
dengan action terpisah.
Konvensi penargetan halaman GUI: beri surfaceId prefix `page.<halaman>.`
(contoh `page.tasks.dashboard`) dan surface akan muncul di halaman GUI yang
dituju — halaman yang didukung: tasks, bots, automation, runs, skills,
security. Update surface dengan updateComponents pada surfaceId yang sama
agar halaman selalu menampilkan versi terbaru.
Tombol link memakai action.name `open_url` dengan payload {"url":"https://host/path"};
hanya URL https yang cocok dengan allowlist host (config
a2ui.open_url_allow) yang dibuka, URL lain ditolak (fail-closed).
Komponen input (TextField, CheckBox, ChoicePicker, Slider, DateTimeInput) boleh
bawa `action` (onChanged): saat user mengubah isian, host mengirim action
tersebut dengan payload {"value": <isian baru>} — isian tidak otomatis masuk
konteks, jadi tanggapi aksinya. Bindung `value` via {"@path":...} membuat
tulis-balik user tersimpan ke data model surface otomatis.
''';

/// Satu entri allowlist URL [A2uiOpenUrlPolicy] setelah dinormalisasi.
class _A2uiOpenUrlEntry {
  const _A2uiOpenUrlEntry(this.host, {this.wildcard = false, this.path = ''});

  final String host;

  /// true = entri `*.host` (hanya subdomain, bukan host itu sendiri).
  final bool wildcard;

  /// '' = seluruh host; string mulai '/' = prefix path wajib.
  final String path;
}

/// Kebijakan allowlist URL untuk aksi `open_url` pada surface A2UI (E5).
/// Host memediasi setiap aksi `open_url` lewat kebijakan ini — fail-closed:
/// allowlist kosong berarti semua URL ditolak. Aturan:
/// - hanya skema `https`; port selain 443 ditolak; userinfo (`user@`) ditolak;
/// - entri berupa `host`, `https://host/path`, atau wildcard `*.host`;
/// - path entri kosong/'/' = seluruh host; selain itu prefix path
///   ('/docs' mencocokkan '/docs' dan '/docs/a', bukan '/docs-rm');
/// - kuery dan fragment diabaikan; entri tidak valid diabaikan.
class A2uiOpenUrlPolicy {
  A2uiOpenUrlPolicy({List<String> allow = const []}) {
    final entries = <_A2uiOpenUrlEntry>[];
    for (final raw in allow) {
      final entry = _parseEntry(raw);
      if (entry != null) entries.add(entry);
    }
    _entries = List.unmodifiable(entries);
  }

  late final List<_A2uiOpenUrlEntry> _entries;

  _A2uiOpenUrlEntry? _parseEntry(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^https://', caseSensitive: false), '');
    if (s.contains('://') || s.startsWith('*') && !s.startsWith('*.')) {
      return null;
    }
    final slash = s.indexOf('/');
    var hostPart = slash == -1 ? s : s.substring(0, slash);
    final pathPart = slash == -1 ? '' : s.substring(slash);
    hostPart = hostPart.toLowerCase();
    if (hostPart.endsWith(':443')) {
      hostPart = hostPart.substring(0, hostPart.length - 4);
    } else if (hostPart.contains(':')) {
      return null;
    }
    var wildcard = false;
    if (hostPart.startsWith('*.')) {
      wildcard = true;
      hostPart = hostPart.substring(2);
    }
    if (hostPart.isEmpty || hostPart.contains('*')) return null;
    String path;
    if (pathPart.isEmpty || pathPart == '/') {
      path = '';
    } else {
      path = pathPart.endsWith('/')
          ? pathPart.substring(0, pathPart.length - 1)
          : pathPart;
      if (!path.startsWith('/') || path.length < 2) return null;
    }
    return _A2uiOpenUrlEntry(hostPart, wildcard: wildcard, path: path);
  }

  /// true bila [url] boleh dibuka sesuai allowlist.
  bool allows(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.port != 443) return false;
    final p = uri.path;
    final path = p.isEmpty || p == '/'
        ? ''
        : (p.endsWith('/') ? p.substring(0, p.length - 1) : p);
    for (final e in _entries) {
      final hostOk = e.wildcard
          ? host.endsWith('.${e.host}') && host.length > e.host.length + 1
          : host == e.host;
      if (!hostOk) continue;
      final pathOk = e.path.isEmpty ||
          path == e.path ||
          path.startsWith('${e.path}/');
      if (pathOk) return true;
    }
    return false;
  }
}
