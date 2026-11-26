import 'dart:convert';
import 'dart:io';

import 'messaging_gateways.dart';

/// Ledger kewajiban pengiriman pesan (Hermes `delivery_ledger`): pesan
/// outbound dicatat durabel SEBELUM dikirim, sehingga crash di tengah
/// pengiriman tidak pernah menghilangkan pesan secara diam-diam.
///
/// State machine: `pending → attempting → delivered | failed`.
/// `failed` adalah batas retry: pesan kembali ke antrean lewat [retry]
/// dan diabaikan sampai itu (tidak di-redeliver otomatis). Melebihi
/// batas percobaan atau kedaluwarsa → `abandoned`.
///
/// Semantik crash:
/// - crash saat `pending`   → redeliver polos (belum pernah disentuh receiver).
/// - crash saat `attempting`→ redeliver DENGAN marker `[dipulihkan]` agar
///   penerima tahu pesan mungkin terkirim dua kali.
/// - crash saat `failed`    → tidak di-redeliver otomatis (batas retry).
///
/// Ledger bersifat best-effort: kegagalan I/O ledger tidak pernah
/// memblokir pengiriman pesan.
enum DeliveryState { pending, attempting, delivered, failed, abandoned }

class DeliveryEntry {
  DeliveryEntry({
    required this.id,
    required this.gateway,
    required this.chatId,
    required this.text,
    required this.state,
    this.attempts = 0,
    required this.createdAt,
    required this.updatedAt,
    this.ownerPid,
    this.recovered = false,
  });

  final String id;
  final String gateway;
  final String chatId;
  final String text;
  DeliveryState state;
  int attempts;
  DateTime createdAt;
  DateTime updatedAt;

  /// PID proses yang terakhir memegang attempt ini — dipakai untuk
  /// mendeteksi orphan saat proses lain (yang sudah mati) crash mid-send.
  int? ownerPid;

  /// True bila entry dipulihkan dari state `attempting` milik proses lain
  /// — pengiriman berikutnya wajib membawa marker terlihat.
  bool recovered;

  Map<String, dynamic> toJson() => {
        'id': id,
        'gateway': gateway,
        'chat_id': chatId,
        'text': text,
        'state': state.name,
        'attempts': attempts,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        if (ownerPid != null) 'owner_pid': ownerPid,
        if (recovered) 'recovered': true,
      };

  static DeliveryEntry fromJson(Map<dynamic, dynamic> j) {
    return DeliveryEntry(
      id: j['id']?.toString() ?? '',
      gateway: j['gateway']?.toString() ?? '',
      chatId: j['chat_id']?.toString() ?? '',
      text: j['text']?.toString() ?? '',
      state: DeliveryState.values.firstWhere(
        (s) => s.name == j['state'],
        orElse: () => DeliveryState.pending,
      ),
      attempts: (j['attempts'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse(j['updated_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      ownerPid: (j['owner_pid'] as num?)?.toInt(),
      recovered: j['recovered'] == true,
    );
  }
}

class DeliveryLedger {
  DeliveryLedger({
    required this.persistPath,
    this.maxAttempts = 5,
    this.staleAfter = const Duration(hours: 24),
    this.maxEntries = 500,
    this.maxTextChars = 8000,
    DateTime Function()? clock,
    int? ownerPid,
  })  : _clock = clock ?? (() => DateTime.now().toUtc()),
        ownerPid = ownerPid ?? pid;

  final String persistPath;
  final int maxAttempts;
  final Duration staleAfter;
  final int maxEntries;
  final int maxTextChars;
  final DateTime Function() _clock;

  /// PID proses pemilik ledger ini (default: proses berjalan).
  final int ownerPid;

  final Map<String, DeliveryEntry> _entries = {};
  bool _loaded = false;

  int get length => _entries.length;

  DeliveryEntry? entry(String id) => _entries[id];

  Iterable<DeliveryEntry> get all => _entries.values;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(persistPath);
    if (!await f.exists()) return;
    try {
      if (await f.length() > 2 * 1024 * 1024) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is! Map) return;
        final e = DeliveryEntry.fromJson(value);
        if (e.id.isNotEmpty) _entries[e.id] = e;
      });
    } on Exception {
      // File korup dilompati — ledger best-effort.
    }
  }

  /// Catat pesan yang WAJIB terkirim. Dipanggil sebelum kirim.
  Future<DeliveryEntry?> enqueue({
    required String gateway,
    required String chatId,
    required String text,
    String? id,
  }) async {
    try {
      await load();
      var body = text;
      if (body.length > maxTextChars) {
        body = '${body.substring(0, maxTextChars)}…';
      }
      final e = DeliveryEntry(
        id: id ?? 'd-${DateTime.now().microsecondsSinceEpoch}-'
            '${_entries.length}',
        gateway: gateway,
        chatId: chatId,
        text: body,
        state: DeliveryState.pending,
        createdAt: _clock(),
        updatedAt: _clock(),
      );
      _entries[e.id] = e;
      _evictTerminal();
      await _save();
      return e;
    } on Exception {
      return null;
    }
  }

  /// Tandai attempt dimulai (state `attempting`, attempts++, owner=pid ini).
  Future<void> beginAttempt(String id, {int? ownerPid}) async {
    final e = _entries[id];
    if (e == null) return;
    try {
      e.state = DeliveryState.attempting;
      e.attempts++;
      e.ownerPid = ownerPid ?? this.ownerPid;
      e.updatedAt = _clock();
      await _save();
    } on Exception {
      // best-effort
    }
  }

  Future<void> markDelivered(String id) async {
    final e = _entries[id];
    if (e == null) return;
    try {
      e.state = DeliveryState.delivered;
      e.updatedAt = _clock();
      await _save();
    } on Exception {
      // best-effort
    }
  }

  Future<void> markFailed(String id) async {
    final e = _entries[id];
    if (e == null) return;
    try {
      e.state = DeliveryState.failed;
      e.updatedAt = _clock();
      await _save();
    } on Exception {
      // best-effort
    }
  }

  /// Batas retry: kembalikan pesan gagal ke antrean (state `pending`).
  Future<void> retry(String id) async {
    final e = _entries[id];
    if (e == null || e.state != DeliveryState.failed) return;
    try {
      e.state = DeliveryState.pending;
      e.updatedAt = _clock();
      await _save();
    } on Exception {
      // best-effort
    }
  }

  /// Pulihkan orphan: entry `pending`/`attempting` milik proses lain
  /// (owner pid ≠ pid ini) atau melewati [staleAfter]. Entry `attempting`
  /// orphan ditandai [DeliveryEntry.recovered] = true (marker wajib).
  Future<int> recoverOrphans() async {
    try {
      await load();
    } on Exception {
      return 0;
    }
    final now = _clock();
    var n = 0;
    for (final e in _entries.values) {
      if (e.state != DeliveryState.pending &&
          e.state != DeliveryState.attempting) {
        continue;
      }
      final stale = now.difference(e.updatedAt) > staleAfter;
      final orphan = e.state == DeliveryState.pending
          ? (e.ownerPid != null && e.ownerPid != ownerPid)
          : (e.ownerPid != null && e.ownerPid != ownerPid);
      if (!stale && !orphan) continue;
      if (e.state == DeliveryState.attempting) e.recovered = true;
      e.state = DeliveryState.pending;
      e.updatedAt = now;
      n++;
    }
    if (n > 0) await _save();
    return n;
  }

  /// Abandon entry yang melebihi batas percobaan atau kedaluwarsa.
  Future<int> sweep() async {
    final now = _clock();
    var n = 0;
    for (final e in _entries.values) {
      if (e.state == DeliveryState.delivered ||
          e.state == DeliveryState.abandoned) {
        continue;
      }
      final overAttempts = e.attempts >= maxAttempts;
      final stale = now.difference(e.createdAt) > staleAfter;
      if (overAttempts || stale) {
        e.state = DeliveryState.abandoned;
        e.updatedAt = now;
        n++;
      }
    }
    if (n > 0) await _save();
    return n;
  }

  /// Entry siap di-redeliver: `pending` (polos atau ber-marker recovered).
  List<DeliveryEntry> readyForRedelivery() => _entries.values
      .where((e) => e.state == DeliveryState.pending)
      .toList();

  /// Teks efektif yang harus dikirim: pesan pulih dari crash `attempting`
  /// diberi marker terlihat agar penerima tahu kemungkinan duplikat.
  String effectiveText(DeliveryEntry e) =>
      e.recovered ? '[dipulihkan] ${e.text}' : e.text;

  void _evictTerminal() {
    _entries.removeWhere(
      (id, e) =>
          (e.state == DeliveryState.delivered ||
              e.state == DeliveryState.abandoned) &&
          _clock().difference(e.updatedAt) > const Duration(hours: 1),
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  Future<void> _save() async {
    final file = File(persistPath);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      }),
      flush: true,
    );
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(await tmp.readAsString(), flush: true);
      try {
        await tmp.delete();
      } on FileSystemException {
        // best-effort
      }
    }
  }
}

/// Wrapper [MessagingGateway] yang mencatat tiap pengiriman ke ledger dan
/// otomatis menandai delivered/failed — titik tembus satu-baris untuk
/// gateway apa pun. Kegagalan ledger tidak pernah memblokir pengiriman.
class LedgeredGateway implements MessagingGateway {
  LedgeredGateway({required this.inner, required this.ledger});

  final MessagingGateway inner;
  final DeliveryLedger ledger;

  @override
  String get name => inner.name;

  @override
  Future<bool> sendMessage(String chatId, String text,
      {List<String>? attachments}) async {
    final entry = await ledger.enqueue(
      gateway: inner.name,
      chatId: chatId,
      text: text,
    );
    final body = entry == null ? text : ledger.effectiveText(entry);
    if (entry != null) await ledger.beginAttempt(entry.id);
    try {
      final ok = await inner.sendMessage(chatId, body, attachments: attachments);
      if (entry != null) {
        if (ok) {
          await ledger.markDelivered(entry.id);
        } else {
          await ledger.markFailed(entry.id);
        }
      }
      return ok;
    } catch (_) {
      if (entry != null) await ledger.markFailed(entry.id);
      rethrow;
    }
  }
}
