library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'skills.dart';

// Tool interface berada di interfaces.dart.
import 'interfaces.dart';

/// D5 — Federated-lite: paket skill portabel + merge metrik CRDT LWW.
///
/// **Posisi yang jujur** (vs wishlist Qwen "Federated Swarm Learning"):
/// - BUKAN federated learning sungguhan — tidak ada gradient update, tidak
///   ada jaringan swarm, tidak ada server agregasi.
/// - Yang ada: **ekspor/impor skill secara manual** sebagai paket JSON yang
///   diverifikasi (redaksi rahasia fail-closed, trust direset ke draft), plus
///   **merge metrik LWW-Register** (last-write-wins per snapshot timestamp)
///   agar dua instance bisa saling bertukar pengalaman agregat (counter
///   uses/successes) tanpa konflik.
/// - Privasi: hanya konten skill + counter agregat yang ikut — tidak ada
///   transkrip, data user, atau path mesin.

/// Format paket skill portabel.
const String skillPackageFormat = 'tiko-skill-package';
const int skillPackageFormatVersion = 1;

/// Exception untuk paket skill tidak valid / tidak layak dibagikan.
class SkillPackageException implements Exception {
  SkillPackageException(this.message);
  final String message;

  @override
  String toString() => 'SkillPackageException: $message';
}

/// Snapshot metrik agregat satu skill (untuk merge LWW).
class SkillMetricsSnapshot {
  const SkillMetricsSnapshot({
    required this.uses,
    required this.successes,
    required this.goldenScore,
    required this.goldenTotal,
    required this.updatedAt,
  });

  final int uses;
  final int successes;
  final double goldenScore;
  final double goldenTotal;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'uses': uses,
        'successes': successes,
        'golden_score': goldenScore,
        'golden_total': goldenTotal,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static SkillMetricsSnapshot fromJson(Map<String, dynamic> json) {
    final updatedAtRaw = json['updated_at'];
    final updatedAt = updatedAtRaw is String
        ? DateTime.tryParse(updatedAtRaw)?.toUtc()
        : null;
    if (updatedAt == null) {
      throw SkillPackageException('metrics.updated_at tidak valid');
    }
    final uses = json['uses'];
    final successes = json['successes'];
    if (uses is! int || uses < 0 || successes is! int || successes < 0) {
      throw SkillPackageException('metrics.uses/successes harus int >= 0');
    }
    if (successes > uses) {
      throw SkillPackageException(
          'metrics.successes tidak boleh melebihi uses');
    }
    final goldenScore = json['golden_score'];
    final goldenTotal = json['golden_total'];
    if (goldenScore is! num || goldenTotal is! num || goldenScore < 0) {
      throw SkillPackageException('metrics.golden_* harus angka >= 0');
    }
    return SkillMetricsSnapshot(
      uses: uses,
      successes: successes,
      goldenScore: goldenScore.toDouble(),
      goldenTotal: goldenTotal.toDouble(),
      updatedAt: updatedAt,
    );
  }
}

/// Hasil merge LWW-Register: snapshot pemenang + sumbernya.
class LwwMergeResult {
  const LwwMergeResult({
    required this.winner,
    required this.metrics,
  });

  /// 'local' | 'remote' — seri (timestamp sama) deterministik ke local.
  final String winner;
  final SkillMetricsSnapshot metrics;
}

/// Paket skill portabel: konten + metrik agregat, TANPA data trust
/// (status/approval) dan TANPA data mesin (path/sha256).
class SkillPackage {
  SkillPackage({
    required this.slug,
    required this.name,
    required this.description,
    required this.body,
    this.triggers = const [],
    this.tools = const [],
    this.version = 1,
    this.metrics,
    required this.exportedAt,
    this.instanceId,
  });

  final String slug;
  final String name;
  final String description;
  final String body;
  final List<String> triggers;
  final List<String> tools;
  final int version;
  final SkillMetricsSnapshot? metrics;
  final DateTime exportedAt;
  final String? instanceId;

  /// Buat paket dari skill lokal. Fail-closed: skill yang gagal validasi
  /// keamanan (rahasia terdeteksi / terlalu besar) TIDAK boleh diekspor.
  factory SkillPackage.fromSkill(
    Skill skill, {
    String? instanceId,
    DateTime? clock,
    DateTime? metricsUpdatedAt,
  }) {
    final err = SkillValidator.validate(skill);
    if (err != null) {
      throw SkillPackageException('skill tidak layak diekspor: $err');
    }
    return SkillPackage(
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      body: skill.body,
      triggers: List.unmodifiable(skill.triggers),
      tools: List.unmodifiable(skill.tools),
      version: skill.version,
      metrics: SkillMetricsSnapshot(
        uses: skill.uses,
        successes: skill.successes,
        goldenScore: skill.goldenScore,
        goldenTotal: skill.goldenTotal,
        updatedAt: metricsUpdatedAt ?? clock ?? DateTime.now(),
      ),
      exportedAt: clock ?? DateTime.now(),
      instanceId: instanceId,
    );
  }

  Map<String, dynamic> toJson() => {
        'format': skillPackageFormat,
        'format_version': skillPackageFormatVersion,
        'exported_at': exportedAt.toUtc().toIso8601String(),
        if (instanceId != null) 'instance_id': instanceId,
        'skill': {
          'slug': slug,
          'name': name,
          'description': description,
          'body': body,
          'triggers': triggers,
          'tools': tools,
          'version': version,
          if (metrics != null) 'metrics': metrics!.toJson(),
        },
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// Parse ketat (fail-closed): format salah, field hilang, atau nilai
  /// tidak valid → [SkillPackageException].
  static SkillPackage parse(Object? raw) {
    final Map<String, dynamic> json;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw SkillPackageException('paket harus berupa objek JSON');
        }
        json = decoded;
      } on FormatException catch (e) {
        throw SkillPackageException('paket bukan JSON valid: ${e.message}');
      }
    } else if (raw is Map<String, dynamic>) {
      json = raw;
    } else {
      throw SkillPackageException('paket harus JSON string atau map');
    }

    if (json['format'] != skillPackageFormat) {
      throw SkillPackageException(
          "format tidak dikenal (harus '$skillPackageFormat')");
    }
    if (json['format_version'] != skillPackageFormatVersion) {
      throw SkillPackageException(
          'format_version tidak didukung: ${json['format_version']}');
    }
    final exportedAt = DateTime.tryParse('${json['exported_at'] ?? ''}');
    if (exportedAt == null) {
      throw SkillPackageException('exported_at tidak valid');
    }
    final skillJson = json['skill'];
    if (skillJson is! Map<String, dynamic>) {
      throw SkillPackageException('field skill hilang / bukan objek');
    }

    final slug = skillJson['slug'];
    if (slug is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(slug)) {
      throw SkillPackageException('skill.slug tidak valid: $slug');
    }
    final name = skillJson['name'];
    final description = skillJson['description'];
    final body = skillJson['body'];
    if (name is! String || name.isEmpty) {
      throw SkillPackageException('skill.name wajib diisi');
    }
    if (description is! String || description.isEmpty) {
      throw SkillPackageException('skill.description wajib diisi');
    }
    if (body is! String || body.isEmpty) {
      throw SkillPackageException('skill.body wajib diisi');
    }
    final triggers = _stringList(skillJson['triggers'], 'triggers');
    final tools = _stringList(skillJson['tools'], 'tools');
    final version = skillJson['version'];
    if (version is! int || version < 1) {
      throw SkillPackageException('skill.version harus int >= 1');
    }
    final metricsJson = skillJson['metrics'];
    final metrics = metricsJson == null
        ? null
        : SkillMetricsSnapshot.fromJson(
            metricsJson is Map<String, dynamic>
                ? metricsJson
                : throw SkillPackageException(
                    'skill.metrics harus berupa objek'),
          );

    // Redaksi keamanan pada konten impor (pola rahasia SkillValidator).
    final probe = Skill(
      slug: slug,
      name: name,
      description: description,
      body: body,
      triggers: triggers,
      tools: tools,
      version: version,
    );
    final err = SkillValidator.validate(probe);
    if (err != null) {
      throw SkillPackageException('konten paket ditolak: $err');
    }

    return SkillPackage(
      slug: slug,
      name: name,
      description: description,
      body: body,
      triggers: triggers,
      tools: tools,
      version: version,
      metrics: metrics,
      exportedAt: exportedAt.toUtc(),
      instanceId: json['instance_id'] is String
          ? json['instance_id'] as String
          : null,
    );
  }

  static List<String> _stringList(Object? raw, String field) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw SkillPackageException('skill.$field harus berupa daftar');
    }
    return raw.map((e) {
      if (e is! String) {
        throw SkillPackageException('skill.$field harus daftar string');
      }
      return e;
    }).toList();
  }

  /// Konversi ke [Skill] — status SELALU draft dan approval direset
  /// (trust tidak ikut berpindah antar instance).
  Skill toSkill({String? path}) {
    final skill = Skill(
      slug: slug,
      name: name,
      description: description,
      body: body,
      triggers: triggers,
      tools: tools,
      version: version,
      status: SkillStatus.draft,
      uses: metrics?.uses ?? 0,
      successes: metrics?.successes ?? 0,
      path: path,
    );
    skill.goldenScore = metrics?.goldenScore ?? 0;
    skill.goldenTotal = metrics?.goldenTotal ?? 0;
    return skill;
  }

  /// Markdown SKILL.md untuk persistensi (status draft eksplisit).
  String toMarkdown() {
    final buf = StringBuffer();
    buf.writeln('---');
    buf.writeln('name: $name');
    buf.writeln('description: $description');
    if (triggers.isNotEmpty) {
      buf.writeln('triggers: [${triggers.map((t) => '"$t"').join(', ')}]');
    }
    if (tools.isNotEmpty) {
      buf.writeln('tools: [${tools.join(', ')}]');
    }
    buf.writeln('version: $version');
    buf.writeln('status: draft');
    buf.writeln('---');
    buf.writeln();
    buf.write(body);
    return buf.toString();
  }
}

/// Merge metrik LWW-Register: snapshot dengan `updated_at` terbaru menang.
///
/// Trade-off yang didokumentasikan: ini BUKAN PN-Counter — kenaikan counter
/// yang terjadi di KEDUA sisi sejak snapshot terakhir bisa hilang bila satu
/// sisi jauh lebih baru. Dipilih karena sederhana, konvergen, dan cukup
/// untuk skenario berbagi manual antar instance.
class SkillMetricsMerger {
  /// [local] boleh null (skill belum punya metrik lokal) → remote menang.
  /// Timestamp sama → local menang (deterministik, didokumentasikan).
  static LwwMergeResult merge({
    required SkillMetricsSnapshot? local,
    required SkillMetricsSnapshot remote,
  }) {
    if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
      return LwwMergeResult(winner: 'remote', metrics: remote);
    }
    return LwwMergeResult(winner: 'local', metrics: local);
  }
}

/// Tool `skill_share` (D5, federated-lite) — aksi: export|import.
///
/// - `export` (slug) → paket JSON (divalidasi + redaksi fail-closed).
/// - `import` (package, as_slug?) → daftarkan skill sebagai DRAFT di
///   registry; bila [skillsRoot] tersedia, skill juga dipersist ke
///   `skills/<slug>/SKILL.md` (hanya bila direktori belum ada — tidak
///   pernah menimpa skill lokal). Metrik di-merge dengan LWW.
class SkillShareTool implements Tool {
  SkillShareTool({
    required SkillRegistry registry,
    this.skillsRoot,
    this.instanceId,
    DateTime Function()? clock,
  })  : _registry = registry,
        _clock = clock ?? DateTime.now;

  final SkillRegistry _registry;
  final String? skillsRoot;
  final String? instanceId;
  final DateTime Function() _clock;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'skill_share',
        description:
            'Berbagi skill antar instance Tiko (federated-lite, manual): '
            'export menghasilkan paket JSON skill (konten + metrik agregat, '
            'tanpa data pribadi/rahasia), import menerima paket JSON dan '
            'mendaftarkannya sebagai DRAFT (trust direset, tidak aktif '
            'sampai approval gate). Metrik di-merge last-write-wins.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['export', 'import'],
            },
            'slug': {'type': 'string', 'description': 'Untuk export'},
            'package': {
              'type': 'string',
              'description': 'JSON paket untuk import',
            },
            'as_slug': {
              'type': 'string',
              'description':
                  'Opsional: slug alternatif bila slug paket sudah ada',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    switch (args['action']?.toString()) {
      case 'export':
        final slug = (args['slug'] as String?)?.trim() ?? '';
        if (slug.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'export butuh slug',
            isError: true,
          );
        }
        final skill = _registry.get(slug);
        if (skill == null) {
          return ToolResult(
            callId: '',
            content: 'skill tidak ditemukan: $slug',
            isError: true,
          );
        }
        try {
          final pkg = SkillPackage.fromSkill(
            skill,
            instanceId: instanceId,
            clock: _clock(),
          );
          return ToolResult(callId: '', content: pkg.toJsonString());
        } on SkillPackageException catch (e) {
          return ToolResult(callId: '', content: '$e', isError: true);
        }

      case 'import':
        final rawPackage = args['package'];
        if (rawPackage == null || rawPackage.toString().trim().isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'import butuh package (JSON paket)',
            isError: true,
          );
        }
        final SkillPackage pkg;
        try {
          pkg = SkillPackage.parse(rawPackage);
        } on SkillPackageException catch (e) {
          return ToolResult(callId: '', content: '$e', isError: true);
        }

        final targetSlug =
            ((args['as_slug'] as String?)?.trim().isNotEmpty ?? false)
                ? (args['as_slug'] as String).trim()
                : pkg.slug;
        if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(targetSlug)) {
          return ToolResult(
            callId: '',
            content: 'as_slug tidak valid: $targetSlug',
            isError: true,
          );
        }

        final existing = _registry.get(targetSlug);
        if (existing != null && existing.body.trim() != pkg.body.trim()) {
          return ToolResult(
            callId: '',
            content:
                'slug $targetSlug sudah dipakai skill lokal dengan isi '
                'berbeda; ulangi import dengan as_slug yang lain',
            isError: true,
          );
        }

        // Merge metrik LWW bila skill lokal sudah ada.
        var mergeNote = '';
        if (existing != null && pkg.metrics != null) {
          final localSnapshot = SkillMetricsSnapshot(
            uses: existing.uses,
            successes: existing.successes,
            goldenScore: existing.goldenScore,
            goldenTotal: existing.goldenTotal,
            // Skill lokal tidak menyimpan updated_at; pakai waktu sekarang
            // agar counter lokal (yang lebih segar) menang atas paket lama.
            updatedAt: _clock(),
          );
          final merged = SkillMetricsMerger.merge(
            local: localSnapshot,
            remote: pkg.metrics!,
          );
          if (merged.winner == 'remote') {
            existing.uses = merged.metrics.uses;
            existing.successes = merged.metrics.successes;
            existing.goldenScore = merged.metrics.goldenScore;
            existing.goldenTotal = merged.metrics.goldenTotal;
          }
          mergeNote =
              ' metrik: merge LWW → ${merged.winner} '
              '(uses=${merged.metrics.uses}, '
              'successes=${merged.metrics.successes})';
        }

        // Persist ke disk (hanya bila direktori belum ada — tidak pernah
        // menimpa skill lokal di disk).
        var persisted = false;
        if (skillsRoot != null && existing == null) {
          final dir = Directory(p.join(skillsRoot!, targetSlug));
          if (!dir.existsSync()) {
            try {
              await dir.create(recursive: true);
              await File(p.join(dir.path, 'SKILL.md'))
                  .writeAsString(pkg.toMarkdown(), flush: true);
              persisted = true;
            } catch (_) {
              // best-effort; skill tetap terdaftar in-memory sebagai draft
            }
          }
        }

        // Daftarkan sebagai draft (toSkill mereset trust). Skill lokal
        // yang sudah ada TIDAK ditimpa objeknya — hanya metriknya yang
        // di-merge LWW di atas (isi identik sudah diverifikasi).
        final imported = pkg.toSkill(
          path: persisted
              ? p.join(skillsRoot!, targetSlug, 'SKILL.md')
              : null,
        );
        if (existing == null) {
          if (targetSlug != pkg.slug) {
            // Skill dengan slug alias: pertahankan slug target.
            _registry.register(Skill(
              slug: targetSlug,
              name: imported.name,
              description: imported.description,
              body: imported.body,
              triggers: imported.triggers,
              tools: imported.tools,
              version: imported.version,
              status: SkillStatus.draft,
              uses: imported.uses,
              successes: imported.successes,
              path: imported.path,
            ));
          } else {
            _registry.register(imported);
          }
        }

        final statusNote = existing == null
            ? 'status=draft, perlu approval gate sebelum aktif'
            : 'skill lokal dipertahankan (isi identik), metrik di-merge';
        return ToolResult(
          callId: '',
          content:
              'OK skill "${pkg.name}" diimpor sebagai slug=$targetSlug '
              '($statusNote).'
              '$mergeNote'
              '${persisted ? ' Tersimpan ke skills/$targetSlug/SKILL.md.' : ''}',
        );

      default:
        return const ToolResult(
          callId: '',
          content:
              'aksi tidak dikenal; gunakan export (slug) atau import '
              '(package)',
          isError: true,
        );
    }
  }
}
