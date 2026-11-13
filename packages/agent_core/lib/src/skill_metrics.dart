import 'dart:convert';
import 'dart:io';

import 'skills.dart';

/// Metrik penggunaan durabel untuk satu skill.
class SkillUsageMetrics {
  SkillUsageMetrics({
    this.uses = 0,
    this.successes = 0,
    this.positive = 0,
    this.negative = 0,
    this.lastUsedAt,
  });

  int uses;
  int successes;
  int positive;
  int negative;
  DateTime? lastUsedAt;

  factory SkillUsageMetrics.fromJson(Map<String, dynamic> json) {
    return SkillUsageMetrics(
      uses: (json['uses'] as num?)?.toInt() ?? 0,
      successes: (json['successes'] as num?)?.toInt() ?? 0,
      positive: (json['positive'] as num?)?.toInt() ?? 0,
      negative: (json['negative'] as num?)?.toInt() ?? 0,
      lastUsedAt: DateTime.tryParse(json['last_used_at'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'uses': uses,
        'successes': successes,
        'positive': positive,
        'negative': negative,
        if (lastUsedAt != null) 'last_used_at': lastUsedAt!.toIso8601String(),
      };
}

/// Ledger metrik penggunaan skill yang bertahan restart (perbaikan:
/// "uses/successes hanya hidup di memori"). Sama seperti skill approval,
/// metrik tidak pernah dipercaya dari frontmatter YAML; file JSON di
/// dataDir adalah satu-satunya sumber pemulihan. File korup gagal
/// tertutup: ledger dianggap kosong dan mulai menghitung ulang —
/// kehilangan telemetri lebih baik daripada menampilkan angka palsu.
class SkillMetricsLedger {
  SkillMetricsLedger(this.path, {this.maxSkills = 2000})
      : assert(maxSkills >= 10);

  final String path;
  final int maxSkills;
  final Map<String, SkillUsageMetrics> metrics = {};

  /// Memuat metrik dari file; file hilang berarti ledger kosong.
  Future<void> load() async {
    metrics.clear();
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final raw = decoded is Map ? decoded['metrics'] : null;
      if (raw is! Map) return;
      for (final e in raw.entries) {
        final key = e.key;
        if (key is String && e.value is Map) {
          metrics[key] = SkillUsageMetrics.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
    } catch (_) {
      metrics.clear();
    }
  }

  /// Memulihkan uses/successes ke registry. Hanya angka yang dipulihkan;
  /// status skill tetap dikelola SkillApprovalLedger (pemisahan sumber
  /// kebenaran: telemetri tidak pernah mempromosikan skill).
  void applyTo(SkillRegistry registry) {
    for (final skill in registry.all) {
      final m = metrics[skill.slug];
      if (m == null) continue;
      skill.uses = m.uses;
      skill.successes = m.successes;
    }
  }

  /// Metrik untuk [slug], atau null bila belum pernah tercatat.
  SkillUsageMetrics? of(String slug) => metrics[slug];

  Future<void> recordUse(String slug, {required bool success}) async {
    final m = metrics.putIfAbsent(slug, SkillUsageMetrics.new);
    m.uses++;
    if (success) m.successes++;
    m.lastUsedAt = DateTime.now().toUtc();
    _prune(keep: slug);
    await flush();
  }

  Future<void> recordFeedback(String slug, {required bool positive}) async {
    final m = metrics.putIfAbsent(slug, SkillUsageMetrics.new);
    if (positive) {
      m.positive++;
    } else {
      m.negative++;
    }
    _prune(keep: slug);
    await flush();
  }

  /// Membuang entri terlama saat melebihi [maxSkills], tanpa pernah
  /// membuang entri yang baru saja dicatat.
  void _prune({required String keep}) {
    if (metrics.length <= maxSkills) return;
    for (final key in metrics.keys.toList()) {
      if (metrics.length <= maxSkills) break;
      if (key == keep) continue;
      metrics.remove(key);
    }
  }

  /// Menulis keadaan metrik saat ini ke disk (tmp+rename atomik). Dipanggil
  /// host yang butuh kepastian durabilitas segera, mis. setelah feedback user.
  ///
  /// Tulisan diserialisasi lewat rantai future: flush konkuren (sink
  /// fire-and-forget + flush eksplisit host) tidak boleh saling menimpa file
  /// .tmp — tanpa ini, rename kedua gagal PathNotFound dan event hilang.
  Future<void> _flushChain = Future<void>.value();

  Future<void> flush() {
    final next = _flushChain.then((_) => _flushOnce());
    _flushChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _flushOnce() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'metrics': {
          for (final e in metrics.entries) e.key: e.value.toJson(),
        },
      }),
    );
    await tmp.rename(path);
  }
}
