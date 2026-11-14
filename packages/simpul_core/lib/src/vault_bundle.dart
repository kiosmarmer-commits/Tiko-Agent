import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'vault_crypto.dart';

class VaultBundleException implements Exception {
  const VaultBundleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VaultBundleExportResult {
  const VaultBundleExportResult({
    required this.path,
    required this.fileCount,
    required this.sizeBytes,
  });

  final String path;
  final int fileCount;
  final int sizeBytes;
}

class VaultBundleImportResult {
  const VaultBundleImportResult({
    required this.dir,
    required this.fileCount,
  });

  final String dir;
  final int fileCount;
}

/// Encrypted end-to-end vault bundle (SEC-20..22): the whole vault (notes +
/// index artifacts) sealed into one portable `.simpulbag` file. Plaintext
/// never touches the wire — the bag is a versioned container
/// `SMPLBAG1 | version(1) | keyCrateLen(4) | keyCrate | dataCrate` where the
/// key crate wraps a fresh vault key under the Argon2id KEK of the given
/// password (SEC-05/07) and the data crate is the archive encrypted with
/// XChaCha20-Poly1305 under that vault key (SEC-03/08).
///
/// Transport is deliberately out of scope (local-first, no server): move the
/// bag with any channel (usb, syncthing, rsync); only the password opens it.
abstract final class VaultBundle {
  static const magic = 'SMPLBAG1';
  static const formatVersion = 1;
  static const indexArtifacts = [
    'index.json',
    'vectors.json',
    'graph_cache.json',
    'ai-permissions.json',
  ];

  /// Packs [vault] into an encrypted bag at [outPath]. A locked vault needs
  /// [crypto] (from `SIMPUL_PASSWORD`) to decrypt notes in memory; the bag
  /// itself is always sealed with [password].
  static Future<VaultBundleExportResult> exportBundle(
    String vault, {
    required String password,
    required String outPath,
    VaultCrypto? crypto,
  }) async {
    if (!Directory(vault).existsSync()) {
      throw VaultBundleException('vault tidak ditemukan: $vault');
    }
    final entries = <(String, List<int>)>[];
    await for (final file in _noteFiles(vault)) {
      entries.add((
        p.relative(file.path, from: vault).replaceAll('\\', '/'),
        await _readPlaintext(file, crypto),
      ));
    }
    final simpulDir = Directory(p.join(vault, '.simpul'));
    if (simpulDir.existsSync()) {
      for (final name in indexArtifacts) {
        final file = File(p.join(simpulDir.path, name));
        if (file.existsSync()) {
          entries.add(('.simpul/$name', await _readPlaintext(file, crypto)));
        }
      }
    }
    if (entries.isEmpty) {
      throw const VaultBundleException('vault kosong — tidak ada yang diekspor');
    }

    final created = await VaultCrypto.create(password: password);
    final dataCrate = created.crypto.encryptBytes(_packArchive(entries));
    final keyCrate = created.keyCrate;

    final bag = BytesBuilder()
      ..add(utf8.encode(magic))
      ..addByte(formatVersion)
      ..add(_uint32(keyCrate.length))
      ..add(keyCrate)
      ..add(dataCrate);
    await VaultCrypto.writeBytesAtomically(outPath, bag.toBytes());
    return VaultBundleExportResult(
      path: outPath,
      fileCount: entries.length,
      sizeBytes: bag.length,
    );
  }

  /// Opens [bagPath] with [password] and unpacks every entry under [outDir]
  /// (created when missing). Path traversal entries ('..', absolute) are
  /// rejected before anything is written.
  static Future<VaultBundleImportResult> importBundle(
    String bagPath, {
    required String password,
    required String outDir,
  }) async {
    final bag = File(bagPath).readAsBytesSync();
    if (bag.length < 17 ||
        utf8.decode(bag.sublist(0, 8), allowMalformed: true) != magic) {
      throw const VaultBundleException('bukan bundle simpul (magic SMPLBAG1)');
    }
    if (bag[8] != formatVersion) {
      throw VaultBundleException(
        'versi format bundle tidak dikenal: ${bag[8]}',
      );
    }
    final keyCrateLen = _readUint32(bag, 9);
    if (bag.length < 13 + keyCrateLen) {
      throw const VaultBundleException('bundle terpotong (key crate)');
    }
    final keyCrate = bag.sublist(13, 13 + keyCrateLen);
    final dataCrate = bag.sublist(13 + keyCrateLen);
    final crypto = await VaultCrypto.open(keyCrate, password: password);
    final entries = _unpackArchive(crypto.decryptBytes(dataCrate));
    for (final (path, _) in entries) {
      _assertSafeRelativePath(path);
    }
    await Directory(outDir).create(recursive: true);
    for (final (path, content) in entries) {
      await VaultCrypto.writeBytesAtomically(
        p.join(outDir, path),
        content,
      );
    }
    return VaultBundleImportResult(dir: outDir, fileCount: entries.length);
  }

  static Future<List<int>> _readPlaintext(File file, VaultCrypto? crypto) async {
    final bytes = await file.readAsBytes();
    if (!VaultCrypto.looksEncrypted(bytes)) return bytes;
    if (crypto == null) {
      throw VaultCryptoException(
        'file terenkripsi diekspor tanpa kunci: ${file.path} '
        '(set SIMPUL_PASSWORD)',
      );
    }
    return crypto.decryptBytes(bytes);
  }

  static Stream<File> _noteFiles(String vault) async* {
    await for (final entity
        in Directory(vault).list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final relative = p.relative(entity.path, from: vault);
      final segments = relative.split(RegExp(r'[\\/]'));
      if (segments.any((s) => s.startsWith('.'))) continue;
      yield entity;
    }
  }

  static void _assertSafeRelativePath(String path) {
    if (p.isAbsolute(path) || path.startsWith('/')) {
      throw VaultBundleException('entri bundle absolut ditolak: $path');
    }
    final segments = path.split(RegExp(r'[\\/]'));
    if (segments.any((s) => s == '..' || s.isEmpty)) {
      throw VaultBundleException('entri bundle keluar dari folder ditolak: $path');
    }
  }

  /// Archive layout: count(4) then per entry
  /// pathLen(2) | path(utf8) | contentLen(8) | content.
  static List<int> _packArchive(List<(String, List<int>)> entries) {
    final body = BytesBuilder();
    body.add(_uint32(entries.length));
    for (final (path, content) in entries) {
      final pathBytes = utf8.encode(path);
      if (pathBytes.length > 0xFFFF) {
        throw VaultBundleException('path terlalu panjang: $path');
      }
      body.addByte(pathBytes.length >> 8);
      body.addByte(pathBytes.length & 0xFF);
      body.add(pathBytes);
      body.add(_uint64(content.length));
      body.add(content);
    }
    return body.toBytes();
  }

  static List<(String, List<int>)> _unpackArchive(List<int> bytes) {
    if (bytes.length < 4) {
      throw const VaultBundleException('arsip terpotong');
    }
    var offset = 0;
    final count = _readUint32(bytes, offset);
    offset += 4;
    final entries = <(String, List<int>)>[];
    for (var i = 0; i < count; i++) {
      if (offset + 2 > bytes.length) {
        throw const VaultBundleException('arsip terpotong (path len)');
      }
      final pathLen = (bytes[offset] << 8) | bytes[offset + 1];
      offset += 2;
      if (offset + pathLen + 8 > bytes.length) {
        throw const VaultBundleException('arsip terpotong (path)');
      }
      final path = utf8.decode(bytes.sublist(offset, offset + pathLen));
      offset += pathLen;
      final contentLen = _readUint64(bytes, offset);
      offset += 8;
      if (offset + contentLen > bytes.length) {
        throw const VaultBundleException('arsip terpotong (konten)');
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
