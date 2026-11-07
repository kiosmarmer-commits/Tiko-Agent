import 'dart:io';

import 'package:path/path.dart' as p;

/// Stores the local daemon API credential outside the YAML config.
///
/// The file is intentionally kept in the runtime data directory, not logged,
/// committed, or returned by status endpoints. On POSIX hosts it is restricted
/// to owner read/write permissions.
class ApiTokenStore {
  ApiTokenStore._();

  static String pathFor(String dataDir) => p.join(dataDir, 'api.token');

  static Future<void> write(String dataDir, String token) async {
    final value = token.trim();
    if (value.length < 32) {
      throw ArgumentError('API token harus berisi minimal 32 karakter.');
    }
    final directory = Directory(dataDir);
    await directory.create(recursive: true);
    final target = File(pathFor(dataDir));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString('$value\n', flush: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        try {
          await temporary.delete();
        } catch (_) {}
        throw StateError(
          'Tidak dapat mengamankan permission file token: ${result.stderr}',
        );
      }
    }
    try {
      await temporary.rename(target.path);
    } on FileSystemException {
      // Windows does not always allow replacing an existing destination.
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    }
  }

  static Future<String?> read(
    String dataDir, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final configured = env['API_TOKEN']?.trim();
    if (configured != null && configured.isNotEmpty) return configured;

    final file = File(pathFor(dataDir));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('API token file tidak boleh berupa symlink', file.path);
    }
    if (!await file.exists()) return null;
    if (await file.length() > 4096) {
      throw FileSystemException('API token file terlalu besar', file.path);
    }
    final token = (await file.readAsString()).trim();
    return token.isEmpty ? null : token;
  }
}
