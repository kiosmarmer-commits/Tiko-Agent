import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'vault_crypto.dart';

/// Encryption modes from PRD `06-enkripsi.md` (SEC-01 staged migration
/// M0→M1→M2→M3): M0 plaintext, M1 index artifacts only, M2 adds notes in
/// selected folders, M3 encrypts every note in the vault.
enum VaultEncryptionMode { m0, m1, m2, m3 }

class VaultLockResult {
  const VaultLockResult({
    required this.mode,
    required this.kdf,
    required this.folders,
    required this.encrypted,
    required this.keyCratePath,
  });

  final String mode;
  final Map<String, Object?> kdf;
  final List<String> folders;
  final List<String> encrypted;
  final String keyCratePath;
}

class VaultUnlockResult {
  const VaultUnlockResult({required this.decrypted});

  final List<String> decrypted;
}

class VaultModeStatus {
  const VaultModeStatus({
    required this.mode,
    required this.locked,
    required this.kdf,
    required this.folders,
    required this.indexFiles,
    required this.encryptedNotes,
    required this.totalNotes,
  });

  final String mode;
  final bool locked;
  final Map<String, Object?>? kdf;
  final List<String> folders;
  final Map<String, bool> indexFiles;
  final int encryptedNotes;
  final int totalNotes;
}

/// Vault-wide lock/unlock operations (SEC-01/03/05/07-12): one vault key
/// crate per vault, index artifacts encrypted at M1+, notes at M2/M3. The
/// mode marker (`.simpul/vault-mode.json`) records mode, KDF params, and —
/// for M2 — the encrypted folder list, so unlock is mode-agnostic.
abstract final class VaultModes {
  static const indexFiles = ['index.json', 'vectors.json', 'graph_cache.json'];
  static const markerName = 'vault-mode.json';

  static File markerFile(String vault) =>
      File(p.join(vault, '.simpul', markerName));

  static bool isLocked(String vault) => markerFile(vault).existsSync();

  static Future<VaultLockResult> lock(
    String vault, {
    required String password,
    String mode = 'm1',
    List<String> folders = const [],
  }) async {
    final marker = markerFile(vault);
    if (marker.existsSync()) {
      throw StateError('vault sudah terkunci — jalankan: simpul unlock <vault>');
    }
    final parsed = _parseMode(mode);
    if (parsed == VaultEncryptionMode.m0) {
      throw ArgumentError('mode m0 berarti tanpa enkripsi (pilihan: m1, m2, m3)');
    }
    final resolvedFolders = <String>[];
    if (parsed == VaultEncryptionMode.m2) {
      if (folders.isEmpty) {
        throw ArgumentError('mode m2 butuh daftar folder (parameter --folders)');
      }
      for (final folder in folders) {
        if (!Directory(p.join(vault, folder)).existsSync()) {
          throw StateError('folder tidak ditemukan di vault: $folder');
        }
        resolvedFolders.add(_normalizeFolder(folder));
      }
    }
    final indexDb = File(p.join(vault, '.simpul', 'index.db'));
    if (indexDb.existsSync()) {
      throw StateError(
        'backend sqlite belum didukung enkripsi (SQLCipher belum tersedia) '
        '\u2014 hapus index.db atau jalankan ulang dengan backend JSON',
      );
    }
    final dir = p.join(vault, '.simpul');
    final created = await VaultCrypto.create(password: password);
    final crypto = created.crypto;
    final encrypted = <String>[];
    for (final name in indexFiles) {
      final file = File(p.join(dir, name));
      if (file.existsSync()) {
        await crypto.encryptFileInPlace(file.path);
        encrypted.add(name);
      }
    }
    if (parsed == VaultEncryptionMode.m2 || parsed == VaultEncryptionMode.m3) {
      await for (final file in noteFiles(vault, folders: resolvedFolders)) {
        await crypto.encryptFileInPlace(file.path);
        encrypted.add(p.relative(file.path, from: vault).replaceAll('\\', '/'));
      }
    }
    final cratePath = p.join(dir, 'vault-key.crate');
    await Directory(dir).create(recursive: true);
    await File(cratePath).writeAsBytes(created.keyCrate, flush: true);
    await VaultCrypto.writeBytesAtomically(
      marker.path,
      utf8.encode(jsonEncode({
        'mode': _modeName(parsed),
        'kdf': crypto.kdf.toJson(),
        if (parsed == VaultEncryptionMode.m2) 'folders': resolvedFolders,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      })),
    );
    return VaultLockResult(
      mode: _modeName(parsed),
      kdf: crypto.kdf.toJson(),
      folders: resolvedFolders,
      encrypted: encrypted,
      keyCratePath: cratePath,
    );
  }

  static Future<VaultUnlockResult> unlock(
    String vault, {
    required String password,
  }) async {
    final marker = markerFile(vault);
    if (!marker.existsSync()) throw StateError('vault tidak terkunci');
    final crateFile = File(p.join(vault, '.simpul', 'vault-key.crate'));
    if (!crateFile.existsSync()) {
      throw VaultCryptoException(
        'crate kunci vault tidak ditemukan: ${crateFile.path}',
      );
    }
    final crypto =
        await VaultCrypto.open(crateFile.readAsBytesSync(), password: password);
    final decrypted = <String>[];
    for (final name in indexFiles) {
      final file = File(p.join(vault, '.simpul', name));
      if (file.existsSync() && VaultCrypto.isFileEncrypted(file.path)) {
        await crypto.decryptFileInPlace(file.path);
        decrypted.add(name);
      }
    }
    await for (final file in noteFiles(vault)) {
      if (VaultCrypto.isFileEncrypted(file.path)) {
        await crypto.decryptFileInPlace(file.path);
        decrypted.add(p.relative(file.path, from: vault).replaceAll('\\', '/'));
      }
    }
    crateFile.deleteSync();
    marker.deleteSync();
    return VaultUnlockResult(decrypted: decrypted);
  }

  static Future<VaultModeStatus> status(String vault) async {
    final marker = markerFile(vault);
    final locked = marker.existsSync();
    var mode = 'm0';
    Map<String, Object?>? kdf;
    final folders = <String>[];
    if (locked) {
      final decoded =
          (jsonDecode(marker.readAsStringSync()) as Map).cast<String, Object?>();
      mode = decoded['mode'] as String? ?? 'm1';
      kdf = (decoded['kdf'] as Map?)?.cast<String, Object?>();
      folders.addAll([
        for (final f in (decoded['folders'] as List? ?? const [])) '$f',
      ]);
    }
    final dir = p.join(vault, '.simpul');
    var encryptedNotes = 0;
    var totalNotes = 0;
    await for (final file in noteFiles(vault)) {
      totalNotes++;
      if (VaultCrypto.isFileEncrypted(file.path)) encryptedNotes++;
    }
    return VaultModeStatus(
      mode: mode,
      locked: locked,
      kdf: kdf,
      folders: folders,
      indexFiles: {
        for (final name in indexFiles)
          name: VaultCrypto.isFileEncrypted(p.join(dir, name)),
      },
      encryptedNotes: encryptedNotes,
      totalNotes: totalNotes,
    );
  }

  /// Every `.md` file under [vault] (or under [folders], relative to the
  /// vault, when given). Hidden folders (`.obsidian`, `.simpul`, `.git`) are
  /// skipped, mirroring [VaultScanner].
  static Stream<File> noteFiles(
    String vault, {
    List<String>? folders,
  }) async* {
    final roots = (folders == null || folders.isEmpty)
        ? <String>[vault]
        : [for (final folder in folders) p.join(vault, folder)];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.md')) continue;
        final relative = p.relative(entity.path, from: vault);
        final segments = relative.split(RegExp(r'[\\/]'));
        if (segments.any((s) => s.startsWith('.'))) continue;
        yield entity;
      }
    }
  }

  static VaultEncryptionMode _parseMode(String value) =>
      switch (value.trim().toLowerCase()) {
        'm1' => VaultEncryptionMode.m1,
        'm2' => VaultEncryptionMode.m2,
        'm3' => VaultEncryptionMode.m3,
        _ => throw ArgumentError(
            'mode tidak dikenal: $value (pilihan: m1, m2, m3)'),
      };

  static String _modeName(VaultEncryptionMode mode) => switch (mode) {
        VaultEncryptionMode.m0 => 'm0',
        VaultEncryptionMode.m1 => 'm1',
        VaultEncryptionMode.m2 => 'm2',
        VaultEncryptionMode.m3 => 'm3',
      };

  static String _normalizeFolder(String folder) =>
      p.normalize(folder).replaceAll('\\', '/');
}
