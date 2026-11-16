import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// Skills Hub client (Hermes-style marketplace).
///
/// Browses, installs, audits and uninstalls community skills from a hub
/// speaking a small REST contract:
/// - `GET  {apiBase}/skills?q=<query>` → `{"skills": [{id, name,
///   description, version, checksum, files: {path: content}}...]}`
/// - `GET  {apiBase}/skills/{id}` → single skill record (same shape)
///
/// Install safety pipeline (mirrors local skill lifecycle):
/// 1. payload checksum verification (sha256 over canonical JSON of files);
/// 2. [SkillScanner] static scan of every file — a failing scan aborts;
/// 3. files are written under the target skills directory, never outside;
/// 4. install is recorded in `installed.json` for [uninstall].

/// Hex sha256 of [bytes] (lowercase), used for hub checksums.
String sha256Hex(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

class SkillsHubConfig {
  const SkillsHubConfig({
    required this.apiBaseUrl,
    required this.skillsDirectory,
    this.apiKey,
    this.timeout = const Duration(seconds: 20),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.onChanged,
  });

  final String apiBaseUrl;
  final String skillsDirectory;
  final String? apiKey;
  final Duration timeout;

  /// Batas ukuran body response hub — response lebih besar ditolak
  /// (skill valid maksimal `SkillValidator.maxBytes`, jadi 8 MB longgar).
  final int maxResponseBytes;

  /// Dipanggil setelah install/uninstall berhasil (slug terlibat) — host
  /// memakai ini untuk hot-reload SkillRegistry tanpa restart.
  final Future<void> Function(String slug)? onChanged;
}

/// One skill listing returned by the hub.
class HubSkill {
  const HubSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.files,
    this.version = '1.0.0',
    this.checksum,
  });

  final String id;
  final String name;
  final String description;
  final String version;

  /// path → file content (SKILL.md plus optional scripts/references).
  final Map<String, String> files;
  final String? checksum;

  factory HubSkill.fromJson(Map<String, dynamic> json) => HubSkill(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        version: json['version'] as String? ?? '1.0.0',
        checksum: json['checksum'] as String?,
        files: (json['files'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, v.toString()),
        ),
      );
}

class SkillsHubException implements Exception {
  SkillsHubException(this.message);
  final String message;

  @override
  String toString() => 'SkillsHubException: $message';
}

class SkillsHubClient {
  SkillsHubClient({required this.config, HttpClient? client})
      : _client = client ?? HttpClient();

  final SkillsHubConfig config;
  final HttpClient _client;

  final Map<String, HubSkill> _installed = {};
  bool _loaded = false;

  /// slug → installed skill record.
  Map<String, HubSkill> get installed => Map.unmodifiable(_installed);

  Future<void> _loadInstalled() async {
    if (_loaded) return;
    _loaded = true;
    final f = File(p.join(config.skillsDirectory, 'installed.json'));
    if (!await f.exists()) return;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      for (final entry in json.entries) {
        final v = entry.value;
        if (v is! Map<String, dynamic>) continue;
        _installed[entry.key] = HubSkill(
          id: v['id'] as String? ?? entry.key,
          name: v['name'] as String? ?? '',
          description: v['description'] as String? ?? '',
          version: v['version'] as String? ?? '1.0.0',
          checksum: v['checksum'] as String?,
          files: const {},
        );
      }
    } catch (e) {
      stderr.writeln('skills_hub: installed.json korup, daftar direset: $e');
    }
  }

  Future<void> _saveInstalled() async {
    final f = File(p.join(config.skillsDirectory, 'installed.json'));
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      for (final e in _installed.entries)
        e.key: {
          'id': e.value.id,
          'name': e.value.name,
          'description': e.value.description,
          'version': e.value.version,
          if (e.value.checksum != null) 'checksum': e.value.checksum,
          'files': e.value.files.keys.toList(),
        },
    }));
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final uri = Uri.parse('${config.apiBaseUrl}$path');
    final req = await _client.getUrl(uri)
      ..headers.set('Accept', 'application/json');
    if (config.apiKey != null) {
      req.headers.set('Authorization', 'Bearer ${config.apiKey}');
    }
    final res = await req.close().timeout(config.timeout);
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length > config.maxResponseBytes) {
        throw SkillsHubException(
            'response hub melebihi ${config.maxResponseBytes} byte');
      }
    }
    final body = utf8.decode(bytes);
    if (res.statusCode >= 400) {
      throw SkillsHubException('hub HTTP ${res.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Searches the hub. Empty [query] lists everything the hub returns.
  Future<List<HubSkill>> search(String query) async {
    final json = await _get('/skills?q=${Uri.encodeQueryComponent(query)}');
    final skills = json['skills'] as List<dynamic>? ?? const [];
    return [
      for (final raw in skills)
        if (raw is Map<String, dynamic>) HubSkill.fromJson(raw),
    ];
  }

  /// Id skill hub valid: `[a-z0-9][a-z0-9-]{0,63}` — mencegah injeksi
  /// path/query pada URL `GET /skills/{id}`.
  static bool isValidId(String id) =>
      RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(id);

  void _ensureValidId(String id) {
    if (!isValidId(id)) {
      throw SkillsHubException('id skill hub tidak valid: "$id"');
    }
  }

  /// Fetches a single skill record from the hub.
  Future<HubSkill> fetch(String id) async {
    _ensureValidId(id);
    return HubSkill.fromJson(await _get('/skills/$id'));
  }

  /// Verifies the checksum of [skill] against its declared checksum.
  /// Returns true when both are absent (hub without checksums) or equal.
  static bool verifyChecksum(HubSkill skill) {
    final declared = skill.checksum;
    if (declared == null || declared.isEmpty) return true;
    final canonical = jsonEncode(skill.files);
    final actual = sha256Hex(utf8.encode(canonical));
    return actual == declared;
  }

  /// Installs [skill] into the skills directory after audit. Returns the
  /// installed directory path.
  Future<String> install(HubSkill skill) async {
    if (skill.files.isEmpty) {
      throw SkillsHubException('skill ${skill.id} has no files');
    }
    if (!verifyChecksum(skill)) {
      throw SkillsHubException('checksum mismatch for ${skill.id}');
    }
    final skillMd = skill.files['SKILL.md'];
    if (skillMd == null) {
      throw SkillsHubException('skill ${skill.id} is missing SKILL.md');
    }
    final parsed = AgentSkillManifest.parse(skillMd);
    if (parsed.errors.isNotEmpty) {
      throw SkillsHubException(
          'skill ${skill.id} failed manifest validation: '
          '${parsed.errors.join('; ')}');
    }
    for (final entry in skill.files.entries) {
      final rel = entry.key.replaceAll('\\', '/');
      if (rel.contains('..') || p.isAbsolute(rel)) {
        throw SkillsHubException('unsafe file path in skill: $rel');
      }
    }
    for (final entry in skill.files.entries) {
      final scan = SkillScanner.scanContent(entry.value);
      if (!scan.ok) {
        throw SkillsHubException(
            'skill ${skill.id} failed safety scan (${entry.key}): '
            '${scan.findings.join('; ')}');
      }
    }
    final targetDir = p.join(config.skillsDirectory, parsed.manifest.name);
    if (!_within(config.skillsDirectory, targetDir)) {
      throw SkillsHubException('install path escapes skills directory');
    }
    for (final entry in skill.files.entries) {
      final rel = entry.key.replaceAll('\\', '/');
      final file = File(p.join(targetDir, rel));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    _installed[parsed.manifest.name] = skill;
    await _saveInstalled();
    return targetDir;
  }

  /// Convenience: fetch from the hub then install.
  Future<String> installFromHub(String id) async {
    final skill = await fetch(id);
    final dir = await install(skill);
    try {
      await config.onChanged?.call(skill.id);
    } catch (_) {
      // Hot-reload gagal tidak boleh menggagalkan install (file sudah aman
      // tertulis; registry akan memuat saat restart).
    }
    return dir;
  }

  /// Removes an installed skill's files and record. Returns true when the
  /// skill existed.
  Future<bool> uninstall(String slug) async {
    _ensureValidId(slug);
    await _loadInstalled();
    final record = _installed.remove(slug);
    final dir = Directory(p.join(config.skillsDirectory, slug));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    if (record == null && !await dir.exists()) return false;
    await _saveInstalled();
    try {
      await config.onChanged?.call(slug);
    } catch (_) {
      // Hot-reload gagal tidak boleh menggagalkan uninstall.
    }
    return true;
  }

  /// Loads previously installed skills from `installed.json`.
  Future<void> refreshInstalled() async {
    _loaded = false;
    await _loadInstalled();
  }

  static bool _within(String base, String target) {
    final absBase = p.normalize(p.absolute(base));
    final absTarget = p.normalize(p.absolute(target));
    return absTarget == absBase ||
        absTarget.startsWith('$absBase${p.separator}');
  }

  Future<void> close() async => _client.close(force: true);
}
