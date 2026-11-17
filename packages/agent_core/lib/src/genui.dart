library;

/// GenUI (D1): DSL aman untuk antarmuka generatif — agen menghasilkan spesifikasi
/// UI terstruktur yang dirender host (Flutter) menjadi widget nyata.
///
/// Prinsip keamanan:
/// - **Grammar tertutup**: hanya tipe node berikut yang valid — `section`,
///   `text`, `metric`, `chart`, `form`, `actions`, `divider`. Tipe lain
///   ditolak (fail-closed); TIDAK ADA akses ke widget arbitrer.
/// - Kunci tak dikenal ditolak; batas ketat untuk depth, jumlah node, dan
///   panjang string; identifier (`id`, `name`, action id) dibatasi karakter aman.
/// - Parser murni Dart tanpa dependensi Flutter sehingga validasi bisa jalan
///   di sisi agen (tool `render_ui`) maupun sisi klien.
///
/// Transport: spesifikasi mengalir sebagai blok fenced ```genui di dalam teks
/// chat — tanpa perubahan protokol server. [extractGenUiBlocks] memisahkan
/// blok tersebut dari teks biasa.
import 'dart:convert';


/// Batas struktur.
const int genuiMaxDepth = 8;
const int genuiMaxNodes = 100;
const int genuiMaxTextChars = 2000;
const int genuiMaxLabelChars = 200;
const int genuiMaxChartPoints = 31;
const int genuiMaxFormFields = 8;
const int genuiMaxSelectOptions = 16;
const int genuiMaxButtons = 4;
const int genuiMaxChildren = 20;
const int genuiMaxBlocksPerMessage = 4;

final RegExp _safeId = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');
final RegExp _controlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

const Set<String> _textStyles = {'heading', 'body', 'mono'};
const Set<String> _chartTypes = {'bar', 'line'};
const Set<String> _fieldKinds = {'text', 'number', 'select'};
const Set<String> _buttonStyles = {'normal', 'danger'};

/// Node UI yang sudah tervalidasi. Gunakan [GenUiSpec.parse] untuk membangun;
/// konstruktor privat menjamin tidak ada node yang lolos validasi.
class GenUiNode {
  GenUiNode._(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
        'type': type,
        ...data.map((k, v) => MapEntry(k, _toJsonValue(v))),
      };

  static Object _toJsonValue(dynamic v) {
    if (v is GenUiNode) return v.toJson();
    if (v is List) return v.map(_toJsonValue).toList();
    return v;
  }
}

/// Spesifikasi UI lengkap: pohon node dengan batas depth/node terjaga.
class GenUiSpec {
  GenUiSpec._(this.root, this.nodeCount);

  final GenUiNode root;
  final int nodeCount;

  /// Mem-parse dan memvalidasi [json] secara fail-closed.
  ///
  /// Melempar [FormatException] dengan pesan berbahasa Indonesia yang
  /// menjelaskan pelanggaran pertama yang ditemukan.
  factory GenUiSpec.parse(Object? json) {
    if (json is String) {
      try {
        json = jsonDecode(json);
      } catch (_) {
        throw const FormatException('genui: bukan JSON yang valid');
      }
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('genui: spesifikasi harus objek JSON');
    }
    final counter = _NodeCounter();
    final root = _parseNode(json, 0, counter);
    return GenUiSpec._(root, counter.value);
  }

  /// Versi yang tidak melempar: null bila tidak valid.
  static GenUiSpec? tryParse(Object? json) {
    try {
      return GenUiSpec.parse(json);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => root.toJson();
}

class _NodeCounter {
  int value = 0;
}

GenUiNode _parseNode(
  Map<String, dynamic> raw,
  int depth,
  _NodeCounter counter,
) {
  if (depth >= genuiMaxDepth) {
    throw const FormatException('genui: kedalaman melebihi $genuiMaxDepth');
  }
  final type = raw['type'];
  if (type is! String || !_knownTypes.contains(type)) {
    throw FormatException(
        'genui: tipe tidak dikenal atau tidak ada (type: $type)');
  }
  final allowed = _allowedKeys[type]!;
  for (final key in raw.keys) {
    if (key != 'type' && !allowed.contains(key)) {
      throw FormatException('genui: kunci tak dikenal "$key" pada tipe $type');
    }
  }
  counter.value += 1;
  if (counter.value > genuiMaxNodes) {
    throw const FormatException('genui: jumlah node melebihi $genuiMaxNodes');
  }

  String? str(Object? v, String key, {int? maxLen}) {
    if (v == null) return null;
    if (v is! String) throw FormatException('genui: "$key" harus string');
    if (_controlChars.hasMatch(v)) {
      throw FormatException('genui: "$key" memuat karakter kontrol');
    }
    if (maxLen != null && v.length > maxLen) {
      throw FormatException(
          'genui: "$key" melebihi $maxLen karakter');
    }
    return v;
  }

  String reqStr(String key, int maxLen) {
    final v = str(raw[key], key, maxLen: maxLen);
    if (v == null || v.trim().isEmpty) {
      throw FormatException('genui: "$key" wajib diisi');
    }
    return v;
  }

  String reqId(String key) {
    final v = str(raw[key], key, maxLen: 64);
    if (v == null || !_safeId.hasMatch(v)) {
      throw FormatException(
          'genui: "$key" wajib [A-Za-z0-9_.-] 1-64 karakter');
    }
    return v;
  }

  switch (type) {
    case 'section':
      final title = reqStr('title', genuiMaxLabelChars);
      final childrenRaw = raw['children'];
      if (childrenRaw is! List || childrenRaw.isEmpty) {
        throw const FormatException('genui: section wajib punya children[]');
      }
      if (childrenRaw.length > genuiMaxChildren) {
        throw const FormatException(
            'genui: section maksimal $genuiMaxChildren children');
      }
      final children = <GenUiNode>[];
      for (final child in childrenRaw) {
        if (child is! Map<String, dynamic>) {
          throw const FormatException(
              'genui: children harus berisi objek');
        }
        children.add(_parseNode(child, depth + 1, counter));
      }
      return GenUiNode._(type, {'title': title, 'children': children});
    case 'text':
      final text = reqStr('text', genuiMaxTextChars);
      final style = str(raw['style'], 'style') ?? 'body';
      if (!_textStyles.contains(style)) {
        throw FormatException(
            'genui: style harus salah satu dari $_textStyles');
      }
      return GenUiNode._(type, {'text': text, 'style': style});
    case 'metric':
      final label = reqStr('label', genuiMaxLabelChars);
      final valueRaw = raw['value'];
      final value = valueRaw is String
          ? str(valueRaw, 'value', maxLen: 64)!
          : (valueRaw is num
              ? valueRaw.toString()
              : throw const FormatException(
                  'genui: metric.value harus string atau angka'));
      final deltaRaw = raw['delta'];
      if (deltaRaw != null && deltaRaw is! num) {
        throw const FormatException('genui: metric.delta harus angka');
      }
      return GenUiNode._(type, {
        'label': label,
        'value': value,
        if (deltaRaw is num) 'delta': deltaRaw,
      });
    case 'chart':
      final chart = str(raw['chart'], 'chart') ?? 'bar';
      if (!_chartTypes.contains(chart)) {
        throw FormatException(
            'genui: chart harus salah satu dari $_chartTypes');
      }
      final pointsRaw = raw['points'];
      if (pointsRaw is! List || pointsRaw.isEmpty) {
        throw const FormatException('genui: chart wajib punya points[]');
      }
      if (pointsRaw.length > genuiMaxChartPoints) {
        throw const FormatException(
            'genui: chart maksimal $genuiMaxChartPoints titik');
      }
      final points = <Map<String, dynamic>>[];
      for (final p in pointsRaw) {
        if (p is! Map<String, dynamic>) {
          throw const FormatException(
              'genui: points harus berisi objek {label, value}');
        }
        for (final k in p.keys) {
          if (!const {'label', 'value'}.contains(k)) {
            throw FormatException('genui: kunci tak dikenal "$k" pada point');
          }
        }
        final label = reqStrFrom(p, 'label');
        final value = p['value'];
        if (value is! num) {
          throw const FormatException('genui: point.value harus angka');
        }
        points.add({'label': label, 'value': value});
      }
      return GenUiNode._(type, {'chart': chart, 'points': points});
    case 'form':
      final id = reqId('id');
      final title = str(raw['title'], 'title', maxLen: genuiMaxLabelChars);
      final fieldsRaw = raw['fields'];
      if (fieldsRaw is! List || fieldsRaw.isEmpty) {
        throw const FormatException('genui: form wajib punya fields[]');
      }
      if (fieldsRaw.length > genuiMaxFormFields) {
        throw const FormatException(
            'genui: form maksimal $genuiMaxFormFields field');
      }
      final names = <String>{};
      final fields = <Map<String, dynamic>>[];
      for (final f in fieldsRaw) {
        if (f is! Map<String, dynamic>) {
          throw const FormatException('genui: fields harus berisi objek');
        }
        for (final k in f.keys) {
          if (!const {'name', 'label', 'kind', 'options', 'initial'}
              .contains(k)) {
            throw FormatException(
                'genui: kunci tak dikenal "$k" pada field');
          }
        }
        final name = f['name'];
        if (name is! String || !_safeId.hasMatch(name)) {
          throw const FormatException(
              'genui: field.name wajib [A-Za-z0-9_.-] 1-64 karakter');
        }
        if (!names.add(name)) {
          throw FormatException('genui: field.name "$name" duplikat');
        }
        final label = reqStrFrom(f, 'label');
        final kind = f['kind'] ?? 'text';
        if (kind is! String || !_fieldKinds.contains(kind)) {
          throw FormatException(
              'genui: field.kind harus salah satu dari $_fieldKinds');
        }
        var options = const <String>[];
        if (kind == 'select') {
          final rawOptions = f['options'];
          if (rawOptions is! List ||
              rawOptions.isEmpty ||
              rawOptions.length > genuiMaxSelectOptions) {
            throw const FormatException(
                'genui: select wajib punya 1-$genuiMaxSelectOptions options');
          }
          options = rawOptions
              .map((o) => o is String ? o : o.toString())
              .toList(growable: false);
        }
        final initial = f['initial'];
        if (initial != null && initial is! String && initial is! num) {
          throw const FormatException(
              'genui: field.initial harus string atau angka');
        }
        fields.add({
          'name': name,
          'label': label,
          'kind': kind,
          if (options.isNotEmpty) 'options': options,
          if (initial != null) 'initial': initial.toString(),
        });
      }
      return GenUiNode._(type, {
        'id': id,
        if (title != null) 'title': title,
        'fields': fields,
      });
    case 'actions':
      final buttonsRaw = raw['buttons'];
      if (buttonsRaw is! List || buttonsRaw.isEmpty) {
        throw const FormatException('genui: actions wajib punya buttons[]');
      }
      if (buttonsRaw.length > genuiMaxButtons) {
        throw const FormatException('genui: actions maksimal $genuiMaxButtons tombol');
      }
      final ids = <String>{};
      final buttons = <Map<String, dynamic>>[];
      for (final b in buttonsRaw) {
        if (b is! Map<String, dynamic>) {
          throw const FormatException('genui: buttons harus berisi objek');
        }
        for (final k in b.keys) {
          if (!const {'id', 'label', 'style'}.contains(k)) {
            throw FormatException(
                'genui: kunci tak dikenal "$k" pada button');
          }
        }
        final id = b['id'];
        if (id is! String || !_safeId.hasMatch(id)) {
          throw const FormatException(
              'genui: button.id wajib [A-Za-z0-9_.-] 1-64 karakter');
        }
        if (!ids.add(id)) {
          throw FormatException('genui: button.id "$id" duplikat');
        }
        final label = reqStrFrom(b, 'label');
        final style = b['style'] ?? 'normal';
        if (style is! String || !_buttonStyles.contains(style)) {
          throw FormatException(
              'genui: button.style harus salah satu dari $_buttonStyles');
        }
        buttons.add({'id': id, 'label': label, 'style': style});
      }
      return GenUiNode._(type, {'buttons': buttons});
    case 'divider':
      return GenUiNode._(type, const {});
    default:
      throw FormatException('genui: tipe tidak dikenal (type: $type)');
  }
}

String reqStrFrom(Map<String, dynamic> map, String key) {
  final v = map[key];
  if (v is! String || v.trim().isEmpty || v.length > genuiMaxLabelChars) {
    throw FormatException(
        'genui: "$key" wajib string 1-$genuiMaxLabelChars karakter');
  }
  if (_controlChars.hasMatch(v)) {
    throw FormatException('genui: "$key" memuat karakter kontrol');
  }
  return v;
}

const Set<String> _knownTypes = {
  'section', 'text', 'metric', 'chart', 'form', 'actions', 'divider',
};

const Map<String, Set<String>> _allowedKeys = {
  'section': {'title', 'children'},
  'text': {'text', 'style'},
  'metric': {'label', 'value', 'delta'},
  'chart': {'chart', 'points'},
  'form': {'id', 'title', 'fields'},
  'actions': {'buttons'},
  'divider': {},
};

/// Satu blok ```genui yang diekstrak dari teks chat.
class GenUiBlock {
  const GenUiBlock(this.start, this.end, this.spec);

  /// Offset karakter awal blok (sebelum fence pembuka) di teks asli.
  final int start;

  /// Offset karakter akhir blok (setelah fence penutup).
  final int end;
  final GenUiSpec spec;
}

/// Mengekstrak blok fenced ```genui dari [text].
///
/// Hanya fence dengan info-string persis `genui` (atau `genui ` dengan
/// spasi) yang dianggap blok UI — blok kode biasa tidak tersentuh. Blok yang
/// JSON-nya tidak valid tetap dikembalikan sebagai bagian teks biasa
/// (fail-closed: host menampilkan teks, bukan UI rusak).
List<GenUiBlock> extractGenUiBlocks(String text) {
  final blocks = <GenUiBlock>[];
  final pattern = RegExp(r'^```genui[ \t]*\r?\n', multiLine: true);
  for (final open in pattern.allMatches(text)) {
    if (blocks.length >= genuiMaxBlocksPerMessage) break;
    final closePattern = RegExp(r'^```[ \t]*\r?$', multiLine: true);
    final close = closePattern.firstMatch(text.substring(open.end));
    if (close == null) continue; // fence tidak tertutup -> bukan blok UI
    final body = text.substring(open.end, open.end + close.start);
    final spec = GenUiSpec.tryParse(body);
    if (spec == null) continue; // tidak valid -> dibiarkan sebagai teks
    blocks.add(GenUiBlock(open.start, open.end + close.end, spec));
  }
  return blocks;
}

/// Memecah teks chat menjadi segmen teks biasa dan blok UI berurutan.
/// Dipakai host untuk merender campuran teks + UI.
List<Object> splitGenUiSegments(String text) {
  final blocks = extractGenUiBlocks(text);
  if (blocks.isEmpty) return [text];
  final segments = <Object>[];
  var cursor = 0;
  for (final b in blocks) {
    if (b.start > cursor) {
      segments.add(text.substring(cursor, b.start));
    }
    segments.add(b.spec);
    cursor = b.end;
  }
  if (cursor < text.length) segments.add(text.substring(cursor));
  return segments;
}
