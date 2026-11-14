import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'vault_crypto.dart';

class DeltaSyncException implements Exception {
  const DeltaSyncException(this.message);
  final String message;
  @override
  String toString() => 'DeltaSyncException: $message';
}

class DeltaSyncStatus {
  const DeltaSyncStatus({
    required this.deviceId,
    required this.revision,
    required this.trackedFiles,
    required this.tombstones,
    required this.peers,
  });

  final String deviceId;
  final int revision;
  final int trackedFiles;
  final int tombstones;
  final List<String> peers;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'revision': revision,
        'trackedFiles': trackedFiles,
        'tombstones': tombstones,
        'peers': peers,
      };
}

class DeltaExportResult {
  const DeltaExportResult({
    required this.path,
    required this.fileCount,
    required this.tombstoneCount,
    required this.sizeBytes,
    required this.peerDeviceId,
  });

  final String path;
  final int fileCount;
  final int tombstoneCount;
  final int sizeBytes;
  final String peerDeviceId;
}

class DeltaImportResult {
  const DeltaImportResult({
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.tombstonesApplied,
    required this.senderDeviceId,
  });

  final List<String> applied;
  final List<String> skipped;
  final List<String> conflicts;
  final List<String> tombstonesApplied;
  final String senderDeviceId;

  Map<String, Object?> toJson() => {
        'applied': applied,
        'skipped': skipped,
        'conflicts': conflicts,
        'tombstonesApplied': tombstonesApplied,
        'senderDeviceId': senderDeviceId,
      };
}

enum ConflictStrategy { keepBoth, newest, ours, theirs }

/// Bidirectional offline delta sync between devices (SEC-20 follow-up).
///
/// Devices exchange two artifacts: a small plaintext **journal** (what this
/// device has, per file hash) and an encrypted **delta** (`SMPLDLT1`) that
/// contains only the entries that differ against the peer's journal. Applying
/// a delta is fail-closed: unsafe paths are rejected before writing, and
/// conflicting edits (both sides changed since the last sync) follow
/// [ConflictStrategy] — default `keepBoth` never loses data.
abstract final class DeltaSync {
  static const magic = 'SMPLDLT1';
  static const formatVersion = 1;
  static const journalDir = '.simpul/sync';
  static const manifestEntry = '__manifest__.json';

  static String journalPath(String vault) => p.join(vault, journalDir, 'journal.json');

  static String peerJournalPath(String vault, String deviceId) =>
      p.join(vault, journalDir, 'peer-$deviceId.json');

  static String _sanitizeDeviceId(String raw) {
    final id = raw.trim();
    if (id.isEmpty || id.length > 64) {
      throw const DeltaSyncException('deviceId kosong atau terlalu panjang');
    }
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) {
      throw const DeltaSyncException(
        'deviceId hanya boleh berisi huruf, angka, titik, garis, underscore',
      );
    }
    return id;
  }

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  /// Creates (or repairs) the sync journal for [vault] from the current
  /// on-disk state. Existing revisions are preserved so re-initialising does
  /// not reset peer clocks.
  static Future<DeltaSyncStatus> initJournal(
    String vault, {
    required String deviceId,
  }) async {
    final id = _sanitizeDeviceId(deviceId);
    final file = File(journalPath(vault));
    var revision = 0;
    var previous = <String, Object?>{};
    if (file.existsSync()) {
      try {
        previous = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
        revision = (previous['revision'] as num?)?.toInt() ?? 0;
      } on FormatException {
        throw const DeltaSyncException('journal korup (JSON tidak valid)');
      }
    }
    final files = <String, Object?>{};
    final previousFiles =
        ((previous['files'] as Map?) ?? const {}).cast<String, Object?>();
    await for (final entity
        in Directory(vault).list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final relative = p.relative(entity.path, from: vault).replaceAll('\\', '/');
      if (relative.split('/').any((s) => s.startsWith('.'))) continue;
      final bytes = await entity.readAsBytes();
      final stat = await entity.stat();
      final old = previousFiles[relative] as Map?;
      files[relative] = {
        'hash': _hash(bytes),
        'size': bytes.length,
        'mtimeMs': stat.modified.millisecondsSinceEpoch,
        'rev': (old?['rev'] as num?)?.toInt() ?? revision,
      };
    }
    final tombstones =
        ((previous['tombstones'] as Map?) ?? const {}).cast<String, Object?>();
    for (final entry in previousFiles.entries) {
      if (files.containsKey(entry.key)) continue;
      final info = (entry.value as Map).cast<String, Object?>();
      final existing = tombstones[entry.key] as Map?;
      if (existing?['deleted'] == true) continue;
      tombstones[entry.key] = {
        'hash': info['hash'],
        'deleted': true,
        'deletedAtMs': DateTime.now().millisecondsSinceEpoch,
      };
    }
    final peers = ((previous['peers'] as Map?) ?? const {}).keys.toList();
    final status = DeltaSyncStatus(
      deviceId: id,
      revision: revision,
      trackedFiles: files.length,
      tombstones: tombstones.length,
      peers: peers.cast<String>(),
    );
    await _writeJournal(vault, {
      'deviceId': id,
      'revision': revision,
      'files': files,
      'tombstones': tombstones,
      'peers': (previous['peers'] as Map?) ?? const {},
    });
    return status;
  }

  static Future<Map<String, Object?>> readJournal(String vault) async {
    final file = File(journalPath(vault));
    if (!file.existsSync()) {
      throw const DeltaSyncException(
        'journal sync belum ada — jalankan simpul sync-init',
      );
    }
    try {
      return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    } on FormatException {
      throw const DeltaSyncException('journal korup (JSON tidak valid)');
    }
  }

  static Future<void> _writeJournal(String vault, Map<String, Object?> journal) async {
    await Directory(p.dirname(journalPath(vault))).create(recursive: true);
    await VaultCrypto.writeBytesAtomically(
      journalPath(vault),
      utf8.encode(const JsonEncoder.withIndent('  ').convert(journal)),
    );
  }

  static Future<DeltaSyncStatus> status(String vault) async {
    final journal = await readJournal(vault);
    final files = (journal['files'] as Map?) ?? const {};
    final tombstones = (journal['tombstones'] as Map?) ?? const {};
    final peers = (journal['peers'] as Map?) ?? const {};
    return DeltaSyncStatus(
      deviceId: (journal['deviceId'] as String?) ?? '',
      revision: (journal['revision'] as num?)?.toInt() ?? 0,
      trackedFiles: files.length,
      tombstones: tombstones.length,
      peers: peers.keys.cast<String>().toList(),
    );
  }

  /// Exports an encrypted delta against [peerJournalPath] (or the stored
  /// snapshot for [peerDeviceId]). Entries whose plaintext hash already
  /// matches the peer's journal are omitted, so repeated exports shrink to
  /// the actual difference.
  static Future<DeltaExportResult> exportDelta(
    String vault, {
    String? peerDeviceId,
    String? peerJournalFile,
    String? password,
    String? outPath,
    VaultCrypto? crypto,
  }) async {
    if ((peerDeviceId == null) == (peerJournalFile == null)) {
      throw const DeltaSyncException(
        'tentukan salah satu: --peer <deviceId> atau --peer-journal <file>',
      );
    }
    final journal = await readJournal(vault);
    final senderId = _sanitizeDeviceId((journal['deviceId'] as String?) ?? '');
    var peerFiles = const <String, Object?>{};
    var resolvedPeer = '';
    if (peerJournalFile != null) {
      final raw = File(peerJournalFile).readAsStringSync();
      final peer = (jsonDecode(raw) as Map).cast<String, Object?>();
      resolvedPeer = _sanitizeDeviceId((peer['deviceId'] as String?) ?? 'peer');
      peerFiles = ((peer['files'] as Map?) ?? const {}).cast<String, Object?>();
    } else {
      resolvedPeer = _sanitizeDeviceId(peerDeviceId!);
      final stored = File(peerJournalPath(vault, resolvedPeer));
      if (stored.existsSync()) {
        final peer =
            (jsonDecode(stored.readAsStringSync()) as Map).cast<String, Object?>();
        peerFiles = ((peer['files'] as Map?) ?? const {}).cast<String, Object?>();
      }
    }

    final entries = <(String, List<int>)>[];
    var tombstoneCount = 0;
    final localFiles = (journal['files'] as Map?) ?? const {};
    for (final entry in localFiles.entries) {
      final path = entry.key as String;
      final info = (entry.value as Map).cast<String, Object?>();
      final peerInfo = peerFiles[path] as Map?;
      if (peerInfo != null && peerInfo['hash'] == info['hash']) continue;
      final file = File(p.join(vault, path));
      if (!file.existsSync()) continue;
      Uint8List content = await file.readAsBytes();
      if (VaultCrypto.looksEncrypted(content)) {
        if (crypto == null) {
          throw VaultCryptoException(
            'file terenkripsi diekspor tanpa kunci: $path '
            '(set SIMPUL_PASSWORD)',
          );
        }
        content = Uint8List.fromList(crypto.decryptBytes(content));
      }
      entries.add((path, content));
    }
    final tombstones = (journal['tombstones'] as Map?) ?? const {};
    for (final entry in tombstones.entries) {
      final path = entry.key as String;
      final peerInfo = peerFiles[path] as Map?;
      if (peerInfo == null || peerInfo['deleted'] != true) {
        tombstoneCount++;
      }
    }

    final manifest = {
      'senderDeviceId': senderId,
      'formatVersion': formatVersion,
      'files': localFiles,
      'tombstones': tombstones,
    };
    final payload = _pack([
      (manifestEntry, utf8.encode(jsonEncode(manifest))),
      ...entries,
    ]);

    List<int> dataCrate;
    List<int> keyCrate = const [];
    if (password != null) {
      final created = await VaultCrypto.create(password: password);
      dataCrate = created.crypto.encryptBytes(payload);
      keyCrate = created.keyCrate;
    } else {
      dataCrate = payload;
    }

    final out = outPath ??
        p.join(
          Directory.systemTemp.path,
          'simpul-delta-$senderId-${DateTime.now().millisecondsSinceEpoch}.simpuldelta',
        );
    final delta = BytesBuilder()
      ..add(utf8.encode(magic))
      ..addByte(formatVersion)
      ..addByte(password == null ? 0 : 1)
      ..add(_uint32(keyCrate.length))
      ..add(keyCrate)
      ..add(dataCrate);
    await VaultCrypto.writeBytesAtomically(out, delta.toBytes());
    return DeltaExportResult(
      path: out,
      fileCount: entries.length,
      tombstoneCount: tombstoneCount,
      sizeBytes: delta.length,
      peerDeviceId: resolvedPeer,
    );
  }

  /// Applies a delta produced by another device. Returns per-path outcomes;
  /// conflicting paths follow [strategy] and are never silently overwritten.
  static Future<DeltaImportResult> importDelta(
    String vault,
    String deltaPath, {
    String? password,
    VaultCrypto? crypto,
    ConflictStrategy strategy = ConflictStrategy.keepBoth,
  }) async {
    final delta = File(deltaPath).readAsBytesSync();
    if (delta.length < 18 ||
        utf8.decode(delta.sublist(0, 8), allowMalformed: true) != magic) {
      throw const DeltaSyncException('bukan delta simpul (magic SMPLDLT1)');
    }
    if (delta[8] != formatVersion) {
      throw DeltaSyncException('versi format delta tidak dikenal: ${delta[8]}');
    }
    final encrypted = delta[9] == 1;
    final keyCrateLen = _readUint32(delta, 10);
    if (delta.length < 14 + keyCrateLen) {
      throw const DeltaSyncException('delta terpotong (key crate)');
    }
    final keyCrate = delta.sublist(14, 14 + keyCrateLen);
    final dataCrate = delta.sublist(14 + keyCrateLen);
    List<int> payload;
    if (encrypted) {
      if (password == null) {
        throw const DeltaSyncException(
          'delta terenkripsi — wajib --password / SIMPUL_PASSWORD',
        );
      }
      final crypto = await VaultCrypto.open(keyCrate, password: password);
      payload = crypto.decryptBytes(dataCrate);
    } else {
      payload = dataCrate;
    }

    final packed = _unpack(payload);
    if (packed.isEmpty || packed.first.$1 != manifestEntry) {
      throw const DeltaSyncException('delta tanpa manifest');
    }
    final manifest =
        (jsonDecode(utf8.decode(packed.first.$2)) as Map).cast<String, Object?>();
    final senderId = _sanitizeDeviceId((manifest['senderDeviceId'] as String?) ?? '');
    final incomingFiles =
        ((manifest['files'] as Map?) ?? const {}).cast<String, Object?>();
    final incomingTombstones =
        ((manifest['tombstones'] as Map?) ?? const {}).cast<String, Object?>();

    for (final path in incomingFiles.keys) {
      _assertSafeRelativePath(path);
    }
    final journal = await readJournal(vault);
    final localFiles =
        ((journal['files'] as Map?) ?? const {}).cast<String, Object?>();
    final localTombstones =
        ((journal['tombstones'] as Map?) ?? const {}).cast<String, Object?>();
    final peers = ((journal['peers'] as Map?) ?? const {}).cast<String, Object?>();

    final applied = <String>[];
    final skipped = <String>[];
    final conflicts = <String>[];
    final tombstonesApplied = <String>[];
    await Directory(vault).create(recursive: true);

    for (final (path, content) in packed.skip(1)) {
      _assertSafeRelativePath(path);
      if (!path.endsWith('.md')) {
        skipped.add(path);
        continue;
      }
      final target = File(p.join(vault, path));
      final incomingHash = _hash(content);
      final incomingInfo = incomingFiles[path] as Map? ?? const {};
      if (target.existsSync()) {
        final localBytes = await target.readAsBytes();
        final localPlain = VaultCrypto.looksEncrypted(localBytes)
            ? (crypto == null
                ? throw VaultCryptoException(
                    'file lokal terenkripsi tanpa kunci: $path')
                : crypto.decryptBytes(localBytes))
            : localBytes;
        if (_hash(localPlain) == incomingHash) {
          skipped.add(path);
          continue;
        }
        final localJournalHash = ((localFiles[path] as Map?)?['hash']);
        final baseHash = incomingInfo['hash'];
        final bothChanged = localJournalHash != null &&
            baseHash != null &&
            localJournalHash != baseHash;
        if (bothChanged) {
          final resolved = await _resolveConflict(
            vault, path, target, content, senderId, strategy,
            localPlain: localPlain,
          );
          if (resolved == null) {
            conflicts.add(path);
            continue;
          }
          applied.add(resolved);
          continue;
        }
      }
      await VaultCrypto.writeBytesAtomically(p.join(vault, path), content);
      applied.add(path);
    }

    for (final entry in incomingTombstones.entries) {
      final path = entry.key;
      _assertSafeRelativePath(path);
      final target = File(p.join(vault, path));
      if (!target.existsSync()) {
        localTombstones[path] = entry.value;
        tombstonesApplied.add(path);
        continue;
      }
      final localBytes = await target.readAsBytes();
      final tombInfo = (entry.value as Map).cast<String, Object?>();
      final localPlain = VaultCrypto.looksEncrypted(localBytes)
          ? (crypto == null
              ? throw VaultCryptoException(
                  'file lokal terenkripsi tanpa kunci: $path')
              : crypto.decryptBytes(localBytes))
          : localBytes;
      if (tombInfo['hash'] == _hash(localPlain)) {
        await target.delete();
        localFiles.remove(path);
        localTombstones[path] = entry.value;
        tombstonesApplied.add(path);
      } else {
        conflicts.add(path);
      }
    }

    for (final path in applied) {
      final info = (incomingFiles[path] as Map?)?.cast<String, Object?>();
      final bytes = await File(p.join(vault, path)).readAsBytes();
      localFiles[path] = {
        'hash': _hash(bytes),
        'size': bytes.length,
        'mtimeMs': info?['mtimeMs'] ?? DateTime.now().millisecondsSinceEpoch,
        'rev': info?['rev'] ?? 0,
      };
      localTombstones.remove(path);
    }
    peers[senderId] = {'lastSyncMs': DateTime.now().millisecondsSinceEpoch};
    journal['files'] = localFiles;
    journal['tombstones'] = localTombstones;
    journal['peers'] = peers;
    journal['revision'] = ((journal['revision'] as num?)?.toInt() ?? 0) + 1;
    await _writeJournal(vault, journal);

    await Directory(p.dirname(peerJournalPath(vault, senderId)))
        .create(recursive: true);
    await VaultCrypto.writeBytesAtomically(
      peerJournalPath(vault, senderId),
      utf8.encode(jsonEncode({
        'deviceId': senderId,
        'revision': manifest['revision'] ?? 0,
        'files': incomingFiles,
        'tombstones': incomingTombstones,
      })),
    );

    return DeltaImportResult(
      applied: applied,
      skipped: skipped,
      conflicts: conflicts,
      tombstonesApplied: tombstonesApplied,
      senderDeviceId: senderId,
    );
  }

  /// Returns the written conflict path, or null when the strategy drops the
  /// incoming change.
  static Future<String?> _resolveConflict(
    String vault,
    String path,
    File target,
    List<int> incoming,
    String senderId,
    ConflictStrategy strategy, {
    required List<int> localPlain,
  }) async {
    switch (strategy) {
      case ConflictStrategy.ours:
        return null;
      case ConflictStrategy.theirs:
        await VaultCrypto.writeBytesAtomically(target.path, incoming);
        return path;
      case ConflictStrategy.newest:
        final localMtime = (await target.stat()).modified;
        final incomingMtime = DateTime.now();
        if (localMtime.isAfter(incomingMtime)) return null;
        await VaultCrypto.writeBytesAtomically(target.path, incoming);
        return path;
      case ConflictStrategy.keepBoth:
        final dir = p.dirname(path);
        final base = p.basenameWithoutExtension(path);
        final ext = p.extension(path);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final name = '$base.conflict-$senderId-$stamp$ext';
        final conflictPath = dir == '.' ? name : p.join(dir, name);
        await VaultCrypto.writeBytesAtomically(p.join(vault, conflictPath), incoming);
        return conflictPath;
    }
  }

  static void _assertSafeRelativePath(String path) {
    if (p.isAbsolute(path) || path.startsWith('/')) {
      throw DeltaSyncException('entri delta absolut ditolak: $path');
    }
    final segments = path.split(RegExp(r'[\\/]'));
    if (segments.any((s) => s == '..' || s.isEmpty)) {
      throw DeltaSyncException('entri delta keluar dari folder ditolak: $path');
    }
  }

  static List<int> _pack(List<(String, List<int>)> entries) {
    final body = BytesBuilder();
    body.add(_uint32(entries.length));
    for (final (path, content) in entries) {
      final pathBytes = utf8.encode(path);
      if (pathBytes.length > 0xFFFF) {
        throw DeltaSyncException('path terlalu panjang: $path');
      }
      body.addByte(pathBytes.length >> 8);
      body.addByte(pathBytes.length & 0xFF);
      body.add(pathBytes);
      body.add(_uint64(content.length));
      body.add(content);
    }
    return body.toBytes();
  }

  static List<(String, List<int>)> _unpack(List<int> bytes) {
    if (bytes.length < 4) {
      throw const DeltaSyncException('arsip delta terpotong');
    }
    var offset = 0;
    final count = _readUint32(bytes, offset);
    offset += 4;
    final entries = <(String, List<int>)>[];
    for (var i = 0; i < count; i++) {
      if (offset + 2 > bytes.length) {
        throw const DeltaSyncException('arsip delta terpotong (path len)');
      }
      final pathLen = (bytes[offset] << 8) | bytes[offset + 1];
      offset += 2;
      if (offset + pathLen + 8 > bytes.length) {
        throw const DeltaSyncException('arsip delta terpotong (path)');
      }
      final path = utf8.decode(bytes.sublist(offset, offset + pathLen));
      offset += pathLen;
      final contentLen = _readUint64(bytes, offset);
      offset += 8;
      if (offset + contentLen > bytes.length) {
        throw const DeltaSyncException('arsip delta terpotong (konten)');
      }
      entries.add((path, bytes.sublist(offset, offset + contentLen)));
      offset += contentLen;
    }
    return entries;
  }

  static Uint8List _uint32(int value) => Uint8List(4)
    ..[0] = (value >> 24) & 0xFF
    ..[1] = (value >> 16) & 0xFF
    ..[2] = (value >> 8) & 0xFF
    ..[3] = value & 0xFF;

  static Uint8List _uint64(int value) {
    final out = Uint8List(8);
    for (var i = 7; i >= 0; i--) {
      out[i] = value & 0xFF;
      value >>= 8;
    }
    return out;
  }

  static int _readUint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _readUint64(List<int> bytes, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}
