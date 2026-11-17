/// GenUI typed actions (GUI-P0-04): registry spesifikasi aksi per sesi.
///
/// Masalah yang diselesaikan: renderer GenUI mengirim action/form sebagai
/// teks bebas `/ui <action-id> <json>` — tidak ada validasi server-side,
/// sehingga action id bisa dipalsukan, diulang (replay), atau dipanggil dari
/// sesi lain. Registry ini menutup celah tersebut:
///
/// - **Ownership**: action hanya valid untuk sesi yang menerima spesifikasinya.
/// - **Expiry**: spesifikasi kedaluwarsa setelah [ttl] sejak dirender.
/// - **Single-use**: aksi yang sudah dikonsumsi ditolak (anti-replay); render
///   ulang spesifikasi dengan id yang sama menggantikan dan mengaktifkan ulang.
/// - **Validasi nilai**: field form divalidasi terhadap kind/options yang
///   dideklarasikan; tombol polos harus tanpa nilai.
///
/// Fail-closed: semua pelanggaran melempar [GenUiActionRejected].
library;

import 'genui.dart';

/// Alasan penolakan aksi GenUI yang tervalidasi.
class GenUiActionRejected implements Exception {
  const GenUiActionRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Satu aksi interaktif yang terdaftar (dari node `actions` atau `form`).
class GenUiActionSpec {
  const GenUiActionSpec({
    required this.actionId,
    required this.kind,
    required this.expiresAt,
    this.fields = const <Map<String, dynamic>>[],
  });

  /// 'button' (node actions) atau 'form'.
  final String kind;
  final String actionId;
  final DateTime expiresAt;

  /// Untuk form: daftar field `{name, kind, options?}` hasil parser GenUI.
  final List<Map<String, dynamic>> fields;
}

/// Registry aksi GenUI per sesi. Thread-safety mengikuti model runtime Tiko:
/// semua operasi dipanggil dari event loop yang sama (tanpa isolate paralel),
/// sehingga Map biasa aman digunakan.
class GenUiActionRegistry {
  GenUiActionRegistry({
    this.ttl = const Duration(minutes: 15),
    this.maxSessions = 256,
    this.maxActionsPerSession = 16,
  });

  final Duration ttl;
  final int maxSessions;
  final int maxActionsPerSession;

  final Map<String, Map<String, GenUiActionSpec>> _bySession = {};

  /// Mendaftarkan semua node interaktif (`actions`/`form`) dalam [spec]
  /// untuk [sessionKey]. Render ulang dengan action id yang sama menggantikan
  /// spesifikasi lama (latest wins) dan mengaktifkan ulang aksinya.
  void register(String sessionKey, GenUiSpec spec, {DateTime? now}) {
    final effectiveNow = now ?? DateTime.now();
    _prune(effectiveNow);
    final bucket = _bySession.putIfAbsent(sessionKey, () => {});
    final found = <GenUiActionSpec>[];
    _collect(spec.root, effectiveNow, found);
    for (final action in found) {
      bucket[action.actionId] = action;
    }
    while (bucket.length > maxActionsPerSession) {
      bucket.remove(bucket.keys.first);
    }
    if (!_bySession.containsKey(sessionKey) && _bySession.length > maxSessions) {
      _bySession.remove(_bySession.keys.first);
    }
  }

  /// Memvalidasi ownership, expiry, dan [values], lalu mengonsumsi aksi
  /// (single-use). Melempar [GenUiActionRejected] bila tidak valid.
  GenUiActionSpec validateAndConsume(
    String sessionKey,
    String actionId,
    Map<String, dynamic> values, {
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final spec = _bySession[sessionKey]?[actionId];
    if (spec == null) {
      throw GenUiActionRejected(
          'aksi "$actionId" tidak dikenal untuk sesi ini (tidak pernah dirender, sudah dipakai, atau kedaluwarsa)');
    }
    if (effectiveNow.isAfter(spec.expiresAt)) {
      _bySession[sessionKey]?.remove(actionId);
      throw const GenUiActionRejected('aksi sudah kedaluwarsa — minta agen merender ulang UI');
    }
    if (spec.kind == 'button' && values.isNotEmpty) {
      throw const GenUiActionRejected('tombol aksi tidak menerima nilai form');
    }
    if (spec.kind == 'form') {
      _validateFormValues(spec, values);
    }
    _bySession[sessionKey]?.remove(actionId);
    return spec;
  }

  int get sessionCount => _bySession.length;

  void _validateFormValues(GenUiActionSpec spec, Map<String, dynamic> values) {
    final known = {for (final f in spec.fields) f['name'] as String: f};
    for (final key in values.keys) {
      final field = known[key];
      if (field == null) {
        throw GenUiActionRejected(
              'field "$key" tidak dikenal pada form "${spec.actionId}"');
      }
      final kind = field['kind'] as String? ?? 'text';
      final value = values[key];
      if (value == null) continue;
      switch (kind) {
        case 'number':
          if (value is! num && num.tryParse('$value') == null) {
            throw GenUiActionRejected('field "$key" harus angka');
          }
        case 'select':
          final options = (field['options'] as List? ?? const []).map((o) => '$o').toSet();
          if (options.isNotEmpty && !options.contains('$value')) {
            throw GenUiActionRejected('nilai "$value" bukan opsi valid untuk field "$key"');
          }
        default:
          if ('$value'.length > genuiMaxTextChars) {
            throw GenUiActionRejected('field "$key" melebihi batas panjang');
          }
      }
    }
  }

  void _collect(GenUiNode node, DateTime now, List<GenUiActionSpec> out) {
    if (node.type == 'actions') {
      final buttons = node.data['buttons'] as List? ?? const [];
      for (final b in buttons) {
        out.add(GenUiActionSpec(
          kind: 'button',
          actionId: b['id'] as String,
          expiresAt: now.add(ttl),
        ));
      }
      return;
    }
    if (node.type == 'form') {
      out.add(GenUiActionSpec(
        kind: 'form',
        actionId: node.data['id'] as String,
        expiresAt: now.add(ttl),
        fields: [
          for (final f in node.data['fields'] as List? ?? const [])
            Map<String, dynamic>.from(f as Map),
        ],
      ));
      return;
    }
    final children = node.data['children'];
    if (children is List) {
      for (final child in children) {
        if (child is GenUiNode) _collect(child, now, out);
      }
    }
  }

  void _prune(DateTime now) {
    _bySession.removeWhere((_, bucket) {
      bucket.removeWhere((_, spec) => now.isAfter(spec.expiresAt));
      return bucket.isEmpty;
    });
  }
}
