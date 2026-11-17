library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// E3 — installer skill dari sumber LOKAL (tanpa registry server).
///
/// Sumber yang diterima:
/// 1. Berkas `.json` berisi paket `tiko-skill-package` (hasil export D5).
/// 2. Direktori berisi `SKILL.md`.
/// 3. Berkas markdown SKILL.md tunggal.
///
/// Keamanan (fail-closed):
/// - Verifikasi SHA-256 opsional: bila [SkillLocalInstaller.install]
///   diberi `expectedSha256`, byte sumber harus cocok persis (konstanta
///   waktu) sebelum apa pun diproses.
/// - SkillPackage.parse ketat (format/field/tipe) + rescan rahasia.
/// - SkillValidator.validate dipanggil lagi setelah parse.
/// - Status SELALU draft, approvedBy SELALU null (trust tidak ikut file).
/// - Collision ditolak: direktori tujuan yang sudah ada TIDAK pernah
///   ditimpa (beda dengan import D5 yang merge; install lokal gagal
///   keras agar operator sadar).
/// - Path safety: slug hasil parse divalidasi tetap di dalam direktori
///   skills.
class SkillLocalInstallException implements Exception {
  const SkillLocalInstallException(this.message);
  final String message;

  @override
  String toString() => 'SkillLocalInstallException: $message';
}

/// Hasil install lokal.
class SkillLocalInstallResult {
  const SkillLocalInstallResult({
    required this.slug,
    required this.path,
    required this.sha256,
    required this.source,
  });

  final String slug;

  /// Path SKILL.md yang dihasilkan.
  final String path;

  /// SHA-256 hex dari byte sumber yang terbaca.
  final String sha256;

  /// 'package' | 'markdown' | 'directory'.
  final String source;

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'path': path,
        'sha256': sha256,
        'source': source,
      };
}

class SkillLocalInstaller {
  SkillLocalInstaller({
    required this.skillsDirectory,
    this.onChanged,
  });

  final String skillsDirectory;

  /// Callback pasca-install (mis. hot-reload registry). Gagal callback
  /// tidak menggagalkan install (file sudah aman tertulis).
  final Future<void> Function(String slug)? onChanged;

  /// Install skill dari [sourcePath] lokal.
  ///
  /// [expectedSha256] — bila diberikan, hex SHA-256 byte sumber harus
  /// cocok (perbandingan konstanta-waktu); mismatch → exception, tidak
  /// ada file yang ditulis.
  Future<SkillLocalInstallResult> install(
    String sourcePath, {
    String? expectedSha256,
  }) async {
    final sourceType = FileSystemEntity.typeSync(sourcePath);
    if (sourceType == FileSystemEntityType.notFound) {
      throw const SkillLocalInstallException('sumber tidak ditemukan');
    }

    final isDirectory = sourceType == FileSystemEntityType.directory;
    File sourceFile;
    String source;
    if (isDirectory) {
      sourceFile = File(p.join(sourcePath, 'SKILL.md'));
      if (!sourceFile.existsSync()) {
        throw const SkillLocalInstallException(
            'direktori sumber tidak berisi SKILL.md');
      }
      source = 'directory';
    } else {
      sourceFile = File(sourcePath);
      source =
          sourcePath.toLowerCase().endsWith('.json') ? 'package' : 'markdown';
    }

    final bytes = sourceFile.readAsBytesSync();
    final digest = sha256.convert(bytes).toString();
    if (expectedSha256 != null &&
        !_constantTimeEquals(digest, expectedSha256.trim().toLowerCase())) {
      throw const SkillLocalInstallException(
          'verifikasi SHA-256 gagal (byte sumber tidak cocok)');
    }

    final content = utf8.decode(bytes, allowMalformed: false);

    final Skill skill;
    if (source == 'package') {
      final pkg = SkillPackage.parse(content);
      skill = pkg.toSkill();
    } else {
      // Hint slug HANYA untuk sumber direktori (nama direktori). Berkas
      // markdown tunggal memakai slug dari frontmatter name (hint nama
      // file seperti 'SKILL.md' tidak bermakna).
      final slugHint =
          source == 'directory' ? _sanitizeSlug(p.basename(p.normalize(sourcePath))) : null;
      final parsed = SkillParser.parse(content, slug: slugHint);
      if (parsed == null) {
        throw const SkillLocalInstallException(
            'SKILL.md tidak dapat diparse (frontmatter hilang/tidak valid)');
      }
      skill = parsed;
    }

    // Trust tidak pernah ikut file: selalu draft tanpa approval.
    // (sha256 tidak di-set ke objek — field Skill final; integritas
    // dilaporkan lewat [SkillLocalInstallResult.sha256] + frontmatter.)
    skill
      ..status = SkillStatus.draft
      ..approvedBy = null;

    final err = SkillValidator.validate(skill);
    if (err != null) {
      throw SkillLocalInstallException('skill gagal validasi keamanan: $err');
    }
    if (skill.slug.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(skill.slug)) {
      throw SkillLocalInstallException(
          "slug tidak valid: '${skill.slug}' (harus [a-z0-9-], maks 64)");
    }

    final targetDir = Directory(p.join(skillsDirectory, skill.slug));
    final absBase = p.normalize(p.absolute(skillsDirectory));
    final absTarget = p.normalize(p.absolute(targetDir.path));
    if (!absTarget.startsWith('$absBase${p.separator}')) {
      throw const SkillLocalInstallException(
          'path tujuan keluar dari direktori skills');
    }
    if (targetDir.existsSync()) {
      throw SkillLocalInstallException(
          'skill sudah ada: ${skill.slug} (hapus dulu atau ganti slug)');
    }

    targetDir.createSync(recursive: true);
    final targetFile = File(p.join(targetDir.path, 'SKILL.md'));
    var markdown = source == 'package'
        ? SkillPackage.parse(content).toMarkdown()
        : content;
    // Status dipaksa draft di file juga (restart tidak boleh memuat
    // status approved dari sumber tak terverifikasi).
    markdown = markdown.replaceFirstMapped(
      RegExp(r'^status:\s*\S+', multiLine: true),
      (_) => 'status: draft',
    );
    targetFile.writeAsStringSync(_withSha256Frontmatter(markdown, digest));

    try {
      await onChanged?.call(skill.slug);
    } catch (_) {
      // Hot-reload gagal tidak boleh menggagalkan install.
    }

    return SkillLocalInstallResult(
      slug: skill.slug,
      path: targetFile.path,
      sha256: digest,
      source: source,
    );
  }

  /// Sisipkan `sha256:` ke frontmatter bila belum ada (informasi integritas
  /// untuk restart; parser frontmatter mengabaikan kunci tak dikenal).
  String _withSha256Frontmatter(String markdown, String digest) {
    if (markdown.contains(RegExp(r'^sha256:', multiLine: true))) return markdown;
    final end = markdown.indexOf('\n---', 3);
    if (!markdown.startsWith('---') || end < 0) return markdown;
    return '${markdown.substring(0, end)}\nsha256: $digest'
        '${markdown.substring(end)}';
  }

  static String _sanitizeSlug(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
