library;

import 'dart:math';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

/// D2 — Hyperdimensional Computing (HDC) memory, eksperimental.
///
/// Representasi memori sebagai **hypervector biner** (default 10.000 dimensi,
/// dipacked ke Uint8List 1.250 byte) dengan operasi kognitif:
/// - *binding* (XOR) — mengikat konsep,
/// - *bundling* (majority vote) — menggabungkan ingatan,
/// - *permutation* (rotasi bit) — menyandikan urutan,
/// - *similarity* (Hamming) — pencarian asosiatif.
///
/// **Posisi yang jujur**: pelengkap pencarian asosiatif yang ringan untuk
/// perangkat edge — BUKAN pengganti embedding semantik (tidak ada model
/// bahasa di baliknya) dan BUKAN klaim "kapasitas tak terbatas". Similarity
/// berbasis trigram karakter (Kanerva-style): teks yang mirip secara
/// karakteristik menghasilkan vektor yang mirip.
///
/// Penyimpanan murni in-memory (hilang saat restart); kapasitas dibatasi
/// dengan eviksi FIFO.

/// Jumlah dimensi default.
const int hdcDefaultDimensions = 10000;

/// Operasi hypervector biner (bit packed per byte, LSB-first per byte).
class HdcVector {
  HdcVector._(this.bits, this.dimensions)
      : assert(bits.length == (dimensions + 7) >> 3);

  final Uint8List bits;
  final int dimensions;

  /// Hypervector acak seimbang (p=0.5 per bit) dari [rng].
  factory HdcVector.random(int dimensions, Random rng) {
    final bytes = (dimensions + 7) >> 3;
    final bits = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      bits[i] = rng.nextInt(256);
    }
    return HdcVector._(bits, dimensions);
  }

  factory HdcVector.zero(int dimensions) =>
      HdcVector._(Uint8List((dimensions + 7) >> 3), dimensions);

  /// Binding: XOR (self-inverse — unbinding = binding ulang).
  HdcVector bind(HdcVector other) {
    _checkSameDims(other);
    final out = Uint8List(bits.length);
    for (var i = 0; i < bits.length; i++) {
      out[i] = bits[i] ^ other.bits[i];
    }
    return HdcVector._(out, dimensions);
  }

  /// Permutation: rotasi siklik sebesar [shift] bit.
  HdcVector permute(int shift) {
    final total = dimensions;
    final out = Uint8List(bits.length);
    final s = ((shift % total) + total) % total;
    for (var i = 0; i < total; i++) {
      if (_getBit((i - s + total) % total)) {
        _setBit(out, i);
      }
    }
    return HdcVector._(out, dimensions);
  }

  /// Jarak Hamming antar dua vektor.
  int hammingDistance(HdcVector other) {
    _checkSameDims(other);
    var dist = 0;
    for (var i = 0; i < bits.length; i++) {
      var x = bits[i] ^ other.bits[i];
      // popcount per byte (Dart belum punya intrinsic popcount).
      while (x != 0) {
        x &= x - 1;
        dist++;
      }
    }
    return dist;
  }

  /// Similarity: 1 - hamming/dimensions (1.0 = identik).
  double similarity(HdcVector other) {
    _checkSameDims(other);
    return 1.0 - hammingDistance(other) / dimensions;
  }

  /// Majority vote per bit atas kandidat. Seri (tepat setengah) dipecahkan
  /// deterministik ke 0 — dokumen sebagai pilihan desain.
  static HdcVector bundle(List<HdcVector> vectors, int dimensions) {
    if (vectors.isEmpty) {
      throw ArgumentError('bundle butuh minimal satu vektor');
    }
    final out = HdcVector.zero(dimensions);
    final half = vectors.length / 2.0;
    for (var i = 0; i < dimensions; i++) {
      var ones = 0;
      for (final v in vectors) {
        if (v._getBit(i)) ones++;
      }
      if (ones > half) {
        _setBit(out.bits, i);
      }
    }
    return out;
  }

  bool _getBit(int index) =>
      (bits[index >> 3] >> (index & 7)) & 1 == 1;

  static void _setBit(Uint8List bits, int index) {
    bits[index >> 3] |= 1 << (index & 7);
  }

  void _checkSameDims(HdcVector other) {
    if (other.dimensions != dimensions) {
      throw ArgumentError(
          'dimensi tidak cocok: $dimensions vs ${other.dimensions}');
    }
  }
}

/// Encoder teks → hypervector (trigram karakter, gaya Kanerva).
///
/// Deterministik terhadap [seed]: encoder dengan seed sama menghasilkan
/// vektor sama untuk teks sama.
class HdcEncoder {
  HdcEncoder({this.dimensions = hdcDefaultDimensions, this.seed = 20261117});

  final int dimensions;
  final int seed;

  final Map<String, HdcVector> _charVectors = {};

  /// Vektor per karakter, diturunkan deterministik dari kode karakter.
  HdcVector charVector(String char) {
    final cached = _charVectors[char];
    if (cached != null) return cached;
    final rng = Random(seed ^ (char.codeUnitAt(0) * 0x9E3779B1));
    final v = HdcVector.random(dimensions, rng);
    _charVectors[char] = v;
    return v;
  }

  /// Menyandikan [text] menjadi satu hypervector: setiap trigram karakter
  /// di-bind dengan posisinya (permutation), lalu semua dibundle.
  /// Teks kosong/pendek tetap menghasilkan vektor valid.
  HdcVector encode(String text) {
    final normalized = text.toLowerCase().trim();
    if (normalized.isEmpty) {
      return HdcVector.zero(dimensions);
    }
    final padded = '  $normalized  ';
    final sum = HdcVector.zero(dimensions);
    final contributors = <HdcVector>[];
    for (var i = 0; i + 3 <= padded.length; i++) {
      final trigram = padded.substring(i, i + 3);
      var v = charVector(trigram[0])
          .bind(charVector(trigram[1]).permute(1))
          .bind(charVector(trigram[2]).permute(2));
      // Posisi trigram disandikan lewat permutation tambahan.
      v = v.permute(i % dimensions);
      contributors.add(v);
    }
    if (contributors.isEmpty) {
      return HdcVector.zero(dimensions);
    }
    // Untuk menghindari dominasi teks panjang dan menjaga batas biaya,
    // maksimal 512 trigram pertama diambil (dokumen sebagai batas).
    final capped = contributors.length > 512
        ? contributors.sublist(0, 512)
        : contributors;
    final bundled = HdcVector.bundle(capped, dimensions);
    for (var i = 0; i < sum.bits.length; i++) {
      sum.bits[i] = bundled.bits[i];
    }
    return sum;
  }
}

/// Satu entri memori HDC.
class HdcEntry {
  HdcEntry({
    required this.id,
    required this.text,
    required this.vector,
    this.meta = const {},
    required this.createdAt,
  });

  final String id;
  final String text;
  final HdcVector vector;
  final Map<String, dynamic> meta;
  final DateTime createdAt;
}

/// Toko memori asosiatif berbasis HDC: remember/recall/forget dengan
/// kapasitas terbatas (eviksi FIFO) dan pencarian top-k berdasarkan similarity.
class HdcMemory {
  HdcMemory({
    this.dimensions = hdcDefaultDimensions,
    this.maxEntries = 1000,
    int seed = 20261117,
    DateTime Function()? clock,
  })  : encoder = HdcEncoder(dimensions: dimensions, seed: seed),
        _clock = clock ?? DateTime.now;

  final int dimensions;
  final int maxEntries;
  final HdcEncoder encoder;
  final DateTime Function() _clock;

  final Map<String, HdcEntry> _entries = {};
  final List<String> _order = [];

  int get length => _entries.length;

  /// Menyimpan [text] dengan [id] (id sama menimpa entri lama).
  void remember(String id, String text, {Map<String, dynamic>? meta}) {
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError('id wajib 1-128 karakter');
    }
    if (text.isEmpty || text.length > 10000) {
      throw ArgumentError('text wajib 1-10000 karakter');
    }
    if (_entries.containsKey(id)) {
      _order.remove(id);
    }
    _entries[id] = HdcEntry(
      id: id,
      text: text,
      vector: encoder.encode(text),
      meta: meta ?? const {},
      createdAt: _clock(),
    );
    _order.add(id);
    while (_order.length > maxEntries) {
      final evicted = _order.removeAt(0);
      _entries.remove(evicted);
    }
  }

  /// Mencari top-k entri paling mirip dengan [query].
  /// [minSimilarity] 0..1 — entri di bawah ambang tidak dikembalikan.
  List<({HdcEntry entry, double similarity})> recall(
    String query, {
    int topK = 5,
    double minSimilarity = 0.0,
  }) {
    if (query.trim().isEmpty) return const [];
    if (topK < 1) throw ArgumentError('topK minimal 1');
    final q = encoder.encode(query);
    final scored = <({HdcEntry entry, double similarity})>[];
    for (final entry in _entries.values) {
      final sim = q.similarity(entry.vector);
      if (sim >= minSimilarity) {
        scored.add((entry: entry, similarity: sim));
      }
    }
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    return scored.take(topK).toList(growable: false);
  }

  /// Menghapus entri; true bila ada.
  bool forget(String id) {
    final removed = _entries.remove(id) != null;
    _order.remove(id);
    return removed;
  }

  void clear() {
    _entries.clear();
    _order.clear();
  }
}

/// Tool `hdc_memory` (D2, eksperimental) — aksi: remember|recall|forget|stats.
class HdcMemoryTool implements Tool {
  HdcMemoryTool(this._memory);

  final HdcMemory _memory;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'hdc_memory',
        description:
            'Memori asosiatif hyperdimensional (eksperimental, in-memory). '
            'Aksi: remember (id+text), recall (query, top-k berdasarkan '
            'kemiripan trigram), forget (id), stats. Cocok untuk asosiasi '
            'ringan di perangkat edge; bukan pengganti memori semantik.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['remember', 'recall', 'forget', 'stats'],
            },
            'id': {'type': 'string', 'description': 'Identitas entri (1-128)'},
            'text': {'type': 'string', 'description': 'Isi untuk remember'},
            'query': {'type': 'string', 'description': 'Kueri untuk recall'},
            'top_k': {'type': 'integer', 'description': 'Default 5'},
            'min_similarity': {
              'type': 'number',
              'description': 'Ambang 0..1, default 0.0',
            },
          },
          'required': ['action'],
        },
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    switch (args['action']?.toString()) {
      case 'remember':
        final id = (args['id'] as String?)?.trim() ?? '';
        final text = (args['text'] as String?)?.trim() ?? '';
        if (id.isEmpty || text.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'remember butuh id dan text',
            isError: true,
          );
        }
        try {
          _memory.remember(id, text);
        } on ArgumentError catch (e) {
          return ToolResult(callId: '', content: '$e', isError: true);
        }
        return ToolResult(
          callId: '',
          content: 'OK tersimpan (id=$id, total=${_memory.length})',
        );
      case 'recall':
        final query = (args['query'] as String?)?.trim() ?? '';
        if (query.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'recall butuh query',
            isError: true,
          );
        }
        final topK = args['top_k'] is int ? args['top_k'] as int : 5;
        final minSim = args['min_similarity'] is num
            ? (args['min_similarity'] as num).toDouble()
            : 0.0;
        final hits = _memory.recall(
          query,
          topK: topK.clamp(1, 20),
          minSimilarity: minSim.clamp(0.0, 1.0),
        );
        if (hits.isEmpty) {
          return const ToolResult(callId: '', content: 'Tidak ada hasil.');
        }
        final lines = [
          for (final h in hits)
            '${h.entry.id} (similarity=${h.similarity.toStringAsFixed(3)}): '
                '${h.entry.text.length > 200 ? '${h.entry.text.substring(0, 200)}…' : h.entry.text}',
        ];
        return ToolResult(callId: '', content: lines.join('\n'));
      case 'forget':
        final id = (args['id'] as String?)?.trim() ?? '';
        final removed = _memory.forget(id);
        return ToolResult(
          callId: '',
          content: removed ? 'OK dihapus (id=$id)' : 'id tidak ditemukan: $id',
          isError: !removed,
        );
      case 'stats':
      default:
        return ToolResult(
          callId: '',
          content:
              'entries=${_memory.length}, maxEntries=${_memory.maxEntries}, '
              'dimensions=${_memory.dimensions}',
        );
    }
  }
}
