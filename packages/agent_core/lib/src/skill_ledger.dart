import 'dart:convert';
import 'dart:io';

import 'skills.dart';

/// Satu record durabel evaluasi/approval skill (AGD-06 SL-01/02).
///
/// [SkillLedgerRecord.action] salah satu dari: evaluated, trial, approved,
/// rolled_back, retired, eval_failed.
class SkillLedgerRecord {
  SkillLedgerRecord({
    required this.slug,
    required this.action,
    required this.actor,
    required this.fingerprint,
    required this.at,
    this.reason,
    this.goldenScore = 0,
    this.goldenTotal = 0,
  });

  final String slug;
  final String action;
  final String actor;
  final String fingerprint;
  final DateTime at;
  final String? reason;
  final double goldenScore;
  final double goldenTotal;

  factory SkillLedgerRecord.fromJson(Map<String, dynamic> json) {
    return SkillLedgerRecord(
      slug: json['slug'] as String? ?? '',
      action: json['action'] as String? ?? '',
      actor: json['actor'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      at: DateTime.tryParse(json['at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      reason: json['reason'] as String?,
      goldenScore: (json['golden_score'] as num?)?.toDouble() ?? 0,
      goldenTotal: (json['golden_total'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'action': action,
        'actor': actor,
        'fingerprint': fingerprint,
        'at': at.toIso8601String(),
        if (reason != null) 'reason': reason,
        'golden_score': goldenScore,
        'golden_total': goldenTotal,
      };
}

/// Ledger approval skill durabel (perbaikan: "persistent skill approval
/// records"). SkillRegistry.loadFromDirectory memang mereset setiap skill
/// ke draft karena status frontmatter YAML bisa diedit user dan bukan
/// record approval. Ledger ini satu-satunya sumber pemulihan status
/// approved/trial/retired setelah restart, dan hanya berlaku selama
/// fingerprint konten skill masih cocok dengan yang dievaluasi.
class SkillApprovalLedger {
  SkillApprovalLedger(this.path, {this.maxRecords = 500})
      : assert(maxRecords >= 10);

  final String path;
  final int maxRecords;
  final List<SkillLedgerRecord> records = [];

  /// Memuat record dari file; file hilang berarti ledger kosong. File korup
  /// gagal tertutup (fail-closed): semua skill tetap draft sampai ada
  /// evaluasi + approval baru yang tercatat.
  Future<void> load() async {
    records.clear();
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final raw = decoded is Map ? decoded['records'] : null;
      if (raw is! List) return;
      for (final item in raw) {
        if (item is Map) {
          records.add(SkillLedgerRecord.fromJson(
            Map<String, dynamic>.from(item),
          ));
        }
      }
    } catch (_) {
      records.clear();
    }
  }

  /// Menambah record, memangkas record terlama bila melebihi batas, lalu
  /// menyimpan file secara atomik (tulis-then-rename).
  Future<void> append(SkillLedgerRecord record) async {
    records.add(record);
    while (records.length > maxRecords) {
      records.removeAt(0);
    }
    await _flush();
  }

  /// Record terakhir untuk [slug], atau null.
  SkillLedgerRecord? latest(String slug) {
    for (var i = records.length - 1; i >= 0; i--) {
      if (records[i].slug == slug) return records[i];
    }
    return null;
  }

  /// Memulihkan status durabel ke [registry], dipanggil tepat setelah
  /// loadFromDirectory me-reset semua skill ke draft. Record hanya
  /// berlaku bila fingerprint masih cocok dengan konten skill; ketidakcocokan
  /// biarkan skill di draft (wajib evaluasi + approval ulang).
  void applyTo(SkillRegistry registry) {
    for (final skill in registry.all) {
      final record = latest(skill.slug);
      if (record == null) continue;
      if (record.fingerprint != fingerprintOf(skill)) continue;
      switch (record.action) {
        case 'approved':
          skill.status = SkillStatus.approved;
          skill.approvedBy = record.actor;
        case 'trial':
          skill.status = SkillStatus.trial;
        case 'retired':
          skill.status = SkillStatus.retired;
        case 'rolled_back':
          skill.status = _statusNamed(record.reason) ?? SkillStatus.draft;
          skill.approvedBy = null;
        default:
          break;
      }
      if (record.goldenTotal > 0) {
        skill.goldenScore = record.goldenScore;
        skill.goldenTotal = record.goldenTotal;
      }
    }
  }

  static SkillStatus? _statusNamed(String? name) {
    if (name == null) return null;
    for (final status in SkillStatus.values) {
      if (status.name == name) return status;
    }
    return null;
  }

  /// Fingerprint konten (FNV-1a 64-bit atas field kanonik skill).
  /// Sengaja tanpa dependensi baru (AGD-08): hanya perlu mendeteksi edit,
  /// bukan menahan pencarian collision adversarial.
  static String fingerprintOf(Skill skill) {
    final basis = jsonEncode([
      skill.slug,
      skill.name,
      skill.description,
      skill.body,
      skill.triggers,
      skill.tools,
      skill.version,
    ]);
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(basis)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<void> _flush() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      jsonEncode({'records': records.map((r) => r.toJson()).toList()}),
    );
    await tmp.rename(path);
  }
}
