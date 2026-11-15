import 'dart:convert';
import 'dart:io';

/// Capability consent untuk plugin (rekomendasi #5): izin yang diminta
/// manifest plugin hanya aktif setelah administrator memberikan persetujuan
/// eksplisit per plugin. Default **fail-closed**: permission yang belum
/// ditanyakan dianggap ditolak.
///
/// Store persisten (JSON, tulis atomik tmp+rename) di
/// `<dataDir>/plugins/consents.json`.
class PluginConsentStore {
  PluginConsentStore({required String path}) : _path = path;

  final String _path;

  /// plugin name -> set permission name yang disetujui.
  final Map<String, Set<String>> _grants = {};

  String get path => _path;

  Future<void> load() async {
    _grants.clear();
    final file = File(_path);
    if (!await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final entry in json.entries) {
        final perms = (entry.value as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toSet();
        if (perms.isNotEmpty) _grants[entry.key] = perms;
      }
    } on FormatException {
      _grants.clear();
    }
  }

  /// True hanya bila **semua** permission yang diminta sudah disetujui.
  bool allGranted(String plugin, Iterable<String> permissions) {
    final granted = _grants[plugin];
    if (granted == null) return false;
    for (final p in permissions) {
      if (!granted.contains(p)) return false;
    }
    return true;
  }

  /// True bila plugin punya minimal satu grant tersimpan.
  bool hasAnyGrant(String plugin) => _grants[plugin]?.isNotEmpty ?? false;

  Set<String> grantsOf(String plugin) => Set<String>.unmodifiable(
        _grants[plugin] ?? const <String>{},
      );

  Future<void> grant(String plugin, Iterable<String> permissions) async {
    final perms = permissions.toSet();
    if (perms.isEmpty) return;
    (_grants[plugin] ??= {}).addAll(perms);
    await _persist();
  }

  /// Hapus permission tertentu; bila store kosong, entri plugin dihapus.
  Future<void> revoke(String plugin, {Iterable<String>? permissions}) async {
    if (permissions == null) {
      _grants.remove(plugin);
    } else {
      final granted = _grants[plugin];
      if (granted == null) return;
      granted.removeAll(permissions);
      if (granted.isEmpty) _grants.remove(plugin);
    }
    await _persist();
  }

  Future<void> _persist() async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    final tmp = File('$_path.tmp');
    final sorted = <String, List<String>>{
      for (final e in _grants.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)))
        e.key: (e.value.toList()..sort()),
    };
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sorted),
    );
    await tmp.rename(file.path);
  }
}
