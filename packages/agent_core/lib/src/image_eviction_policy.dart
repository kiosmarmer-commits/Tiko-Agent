/// Hermes parity: `agent/image_eviction_policy.py` (+ pasangan send-path
/// `evict_stale_outbound_tool_images` di `agent/context_compressor.py`).
///
/// Kebijakan eviksi gambar outbound: dua lintasan kirim (OpenAI-shaped dan
/// wire Anthropic) harus setuju pada satu kebijakan karena keduanya jalan
/// dari salinan baru tiap request. Trigger adalah LIMIT provider, bukan
/// hitungan keep-newest-N: pensiunan gambar mengedit pesan yang sudah
/// di-cache provider (Anthropic cocokkan prompt-cache pada prefix byte
/// persis), jadi jendela keep-newest-N membuat tiap turn miss prefix penuh.
/// Gambar ditahan sampai request akan melintasi limit nyata, lalu dipensiun-
/// kan per batch — satu turn lebih lambat per batch, nol di bawah limit.
///
/// Deviasi sadar dari Hermes:
/// - Hermes meng-latch frontier pensiunan per tool_call_id antar request
///   (`latched_retire_count`); Tiko memutuskan send-path per request tanpa
///   latch karena runtime membangun ulang konteks dari history terkompresi
///   tiap turn (preflight compaction menulis ulang prefix secara rutin,
///   sehingga nilai latch jauh lebih rendah).
/// - Hermes bekerja pada wire dict; Tiko bekerja pada [ChatMessage] dengan
///   `images: List<ChatImage>` (base64). Upload user (bukan role `tool`)
///   di-reserve dan tidak pernah ditulis ulang, seperti Hermes.
library;

import 'dart:convert';
import 'dart:math';

import 'models.dart';

/// Ambang terdokumentasi Anthropic: di atasnya cap dimensi ketat 2000px
/// berlaku untuk SEMUA gambar dalam request.
const outboundImageLimit = 20;

/// Ceiling keras per-request ketika many-image cap terbukti tidak aktif.
const outboundImageHardLimit = 100;

/// Budget byte request (32MB limit biasa bind lebih dulu; sisakan headroom).
const outboundImageBudgetBytes = 24000000;

/// Kuantum pensiunan per langkah (step function atas overshoot).
const imageEvictionBatch = 8;

/// Lantai satisfiability — melindungi frame terbaru saat upload reserved
/// sendiri menembus ceiling blok (tak ada pensiunan yang bisa memperbaiki).
const outboundImageFloor = 3;

/// Cap per-sisi many-image Anthropic (px): gambar di atasnya membuat SEMUA
/// gambar dalam request tunduk pada cap ketat ini.
const manyImageDimensionLimit = 2000;

/// Decode hanya header: PNG IHDR berakhir di byte 24; JPEG SOF ada di beberapa
/// KB pertama. Prefix base64 ~32KB longgar (base64: 3 byte per 4 char).
const _dimensionProbeChars = 32 * 1024;

const _jpegSofMarkers = {
  0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, //
  0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
};

/// (width, height) untuk byte PNG/JPEG, atau null bila tak terbaca.
/// PNG: IHDR. JPEG: jalan segmen (lewati fill byte 0xFF) ke marker SOF
/// pertama; berhenti di SOS. Hanya header — tidak pernah decode penuh.
(int, int)? imageDimensionsFromBytes(List<int> raw) {
  if (raw.length >= 24 &&
      raw[0] == 0x89 &&
      raw[1] == 0x50 &&
      raw[2] == 0x4E &&
      raw[3] == 0x47 &&
      raw[4] == 0x0D &&
      raw[5] == 0x0A &&
      raw[6] == 0x1A &&
      raw[7] == 0x0A) {
    final w = (raw[16] << 24) | (raw[17] << 16) | (raw[18] << 8) | raw[19];
    final h = (raw[20] << 24) | (raw[21] << 16) | (raw[22] << 8) | raw[23];
    return (w, h);
  }
  if (raw.length > 4 && raw[0] == 0xFF && raw[1] == 0xD8) {
    var i = 2;
    while (i + 9 < raw.length) {
      if (raw[i] != 0xFF) {
        i++;
        continue;
      }
      var marker = raw[i + 1];
      i += 2;
      while (marker == 0xFF && i < raw.length) {
        marker = raw[i];
        i += 1;
      }
      if (marker == 0xD8 || marker == 0xD9) continue;
      if (marker == 0xDA || i + 2 > raw.length) break;
      final segmentLen = (raw[i] << 8) | raw[i + 1];
      if (segmentLen < 2 || i + segmentLen > raw.length) break;
      if (_jpegSofMarkers.contains(marker) && segmentLen >= 7) {
        final h = (raw[i + 3] << 8) | raw[i + 4];
        final w = (raw[i + 5] << 8) | raw[i + 6];
        return (w, h);
      }
      i += segmentLen;
    }
  }
  return null;
}

/// Sisi terpanjang (px) dari data-URL / base64 gambar, atau null bila tak
/// terbaca. Menerima `data:image/...;base64,....` dan base64 telanjang;
/// remote URL / container tak dikenal => null (dianggap tidak aman).
int? imageMaxSideFromBase64(String? data) {
  if (data == null || data.isEmpty) return null;
  var payload = data;
  if (payload.startsWith('data:')) {
    final comma = payload.indexOf(',');
    if (comma < 0) return null;
    if (!payload.substring(0, comma).contains(';base64')) return null;
    payload = payload.substring(comma + 1);
  }
  payload = payload.trim();
  var prefix = payload.length > _dimensionProbeChars
      ? payload.substring(0, _dimensionProbeChars)
      : payload;
  final trimmed = prefix.length - (prefix.length % 4);
  if (trimmed <= 0) return null;
  prefix = prefix.substring(0, trimmed);
  List<int> raw;
  try {
    raw = base64.decode(prefix);
  } catch (_) {
    return null;
  }
  final dims = imageDimensionsFromBytes(raw);
  return dims == null ? null : max(dims.$1, dims.$2);
}

/// True hanya bila sisi terpanjang diketahui dan dalam many-image limit.
bool imageWithinManyImageLimit(String? data) {
  final longest = imageMaxSideFromBase64(data);
  return longest != null && longest <= manyImageDimensionLimit;
}

/// True bila SETIAP gambar (reserved + carrier) terbaca dan dalam limit.
/// Aturan Anthropic per request: satu gambar oversize/terbaca-gagal
/// mempertahankan ceiling ketat untuk seluruh request.
bool imagesAllWithinManyImageLimit(Iterable<String?> datas) {
  for (final d in datas) {
    if (!imageWithinManyImageLimit(d)) return false;
  }
  return true;
}

/// Ceiling blok request: ketat 20 kecuali semua gambar aman many-image.
int outboundImageBlockLimit(bool manyImageSafe) =>
    manyImageSafe ? outboundImageHardLimit : outboundImageLimit;

/// Berapa tool-result PELINGLAM tinggi gambar yang dipensiunkan.
///
/// `carrierBlocksNewestFirst` = jumlah blok gambar per carrier, terbaru
/// dulu; `reservedBlocks` = gambar yang tak boleh ditulis ulang (upload
/// user). Dimensi byte aktif hanya bila `carrierBytesNewestFirst` diberikan.
///
/// Retire count HARUS step function atas overshoot: target eksak
/// `count - limit` menggeser frontier tiap gambar baru; batch tetap berhenti
/// menegakkan limit setelah batch pertama. Kuantum = `batch` dibatasi
/// `window - floor`; lantai melindungi frame terbaru hanya pada tekanan
/// upload reserved — tekanan byte (limit request-size keras, provider jawab
/// 413) tetap maju dalam kuantum utuh ke arah lantai.
int outboundImageRetireCount(
  List<int> carrierBlocksNewestFirst,
  int reservedBlocks, {
  List<int>? carrierBytesNewestFirst,
  int reservedBytes = 0,
  bool manyImageSafe = false,
  int? limit,
  int budget = outboundImageBudgetBytes,
  int batch = imageEvictionBatch,
  int floor = outboundImageFloor,
}) {
  final effectiveLimit = limit ?? outboundImageBlockLimit(manyImageSafe);
  final total = carrierBlocksNewestFirst.length;
  var best = 0;
  for (var m = 1; m <= total; m++) {
    final r = _retireCountForRequest(
      carrierBlocksNewestFirst.sublist(total - m),
      reservedBlocks,
      carrierBytesNewestFirst?.sublist(total - m),
      reservedBytes,
      effectiveLimit,
      budget,
      batch,
      floor,
    );
    if (r > best) best = r;
  }
  return best;
}

int _retireCountForRequest(
  List<int> blocks,
  int reservedBlocks,
  List<int>? sizes,
  int reservedBytes,
  int limit,
  int budget,
  int batch,
  int floor,
) {
  final total = blocks.length;
  final blocksKept = List<int>.filled(total + 1, 0);
  final bytesKept = List<int>.filled(total + 1, 0);
  for (var i = 0; i < total; i++) {
    blocksKept[i + 1] = blocksKept[i] + blocks[i];
    bytesKept[i + 1] = bytesKept[i] + (sizes == null ? 0 : sizes[i]);
  }

  bool bytesFit(int kept) =>
      sizes == null || reservedBytes + bytesKept[kept] <= budget;
  bool fits(int kept) =>
      reservedBlocks + blocksKept[kept] <= limit && bytesFit(kept);

  if (fits(total)) return 0;

  final effFloor = floor.clamp(0, total);
  if (!fits(0) && bytesFit(effFloor)) {
    var byteWindow = effFloor;
    for (var k = effFloor; k <= total; k++) {
      if (bytesFit(k)) byteWindow = k;
    }
    final quantum = max(1, min(batch, byteWindow - effFloor + 1));
    final excess = total - effFloor;
    return excess - (excess % quantum);
  }
  var window = 0;
  if (fits(0)) {
    for (var k = 0; k <= total; k++) {
      if (fits(k)) window = k;
    }
  }
  final quantum = max(1, min(batch, window - effFloor));
  var retire = 0;
  while (retire < total) {
    retire = min(retire + quantum, total);
    if (fits(total - retire)) break;
  }
  return retire;
}

/// Placeholder untuk gambar yang dipensiunkan (Hermes: teks pengganti
/// blok gambar; bahasa runtime).
const retiredImagePlaceholder = '[gambar dihapus dari riwayat — hemat konteks]';

/// Send-path eviction pada SALINAN daftar pesan (jangan pernah pada history
/// persisten): carrier = pesan role `tool` berisi gambar, terbaru dulu;
/// upload user di-reserve. Kembalikan daftar baru + jumlah pesan yang
/// ditulis ulang; 0 berarti tidak ada perubahan (panggilan bebas biaya).
({List<ChatMessage> messages, int pruned}) evictStaleOutboundImages(
  List<ChatMessage> messages, {
  String placeholder = retiredImagePlaceholder,
  int? limit,
  int budget = outboundImageBudgetBytes,
  int batch = imageEvictionBatch,
  int floor = outboundImageFloor,
}) {
  final carriers = <int>[]; // indeks pesan, terbaru dulu
  final reserved = <String>[];
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    final sources = m.images ?? const <ChatImage>[];
    if (sources.isNotEmpty && m.role == 'tool') {
      carriers.add(i);
    } else {
      for (final img in sources) {
        reserved.add(img.base64);
      }
    }
  }
  if (carriers.isEmpty) return (messages: messages, pruned: 0);
  final allImages = <String?>[
    ...reserved,
    for (final i in carriers)
      for (final img in messages[i].images!) img.base64,
  ];
  final retire = outboundImageRetireCount(
    [
      for (final i in carriers) messages[i].images!.length,
    ],
    reserved.length,
    carrierBytesNewestFirst: [
      for (final i in carriers)
        messages[i].images!.fold<int>(0, (a, img) => a + img.base64.length),
    ],
    reservedBytes: reserved.fold<int>(0, (a, s) => a + s.length),
    manyImageSafe: imagesAllWithinManyImageLimit(allImages),
    limit: limit,
    budget: budget,
    batch: batch,
    floor: floor,
  );
  if (retire <= 0) return (messages: messages, pruned: 0);
  // `carriers` terbaru dulu; `retire` menghitung dari yang terlama.
  final targets = carriers.sublist(carriers.length - retire);
  var pruned = 0;
  final next = List<ChatMessage>.from(messages);
  for (final i in targets) {
    final m = messages[i];
    next[i] = ChatMessage(
      role: m.role,
      content: m.content.isEmpty
          ? placeholder
          : '${m.content.trim()}\n$placeholder',
      toolCallId: m.toolCallId,
      toolCalls: m.toolCalls,
      name: m.name,
      images: null,
    );
    pruned++;
  }
  return (messages: next, pruned: pruned);
}
