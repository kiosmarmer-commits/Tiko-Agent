import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';

/// Fase 46 — CRITIC universal final-claim gate: heuristik deterministik yang
/// memeriksa klaim pada jawaban final turn sebelum diserahkan ke user.
///
/// Konvensi repo:
/// - Deterministik-first: verifikasi file path langsung terhadap workspace;
///   klaim sukses tanpa bukti verifikasi ditandai jujur.
/// - Mode `llm` opsional (berbiaya) via callback judge terinjeksi.
/// - Event telemetri bebas-konten; tidak pernah me-rethrow.
class ClaimFinding {
  const ClaimFinding({
    required this.claim,
    required this.kind,
    required this.verdict,
    this.detail = '',
  });

  final String claim;
  final String kind; // file_path | success_assertion | llm
  final String verdict; // verified | unverified
  final String detail;

  Map<String, dynamic> toJson() => {
        'claim': claim,
        'kind': kind,
        'verdict': verdict,
        if (detail.isNotEmpty) 'detail': detail,
      };
}

class ClaimCriticReport {
  const ClaimCriticReport({
    required this.findings,
    required this.flagged,
  });

  final List<ClaimFinding> findings;

  /// Temuan dengan verdict `unverified`.
  final List<ClaimFinding> flagged;

  bool get ok => flagged.isEmpty;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'claims_checked': findings.length,
        'flagged': [for (final f in flagged) f.toJson()],
      };

  String toMarkdown() {
    if (ok) {
      return '**Critic review**: ${findings.length} klaim diperiksa — semua '
          'terverifikasi deterministik.';
    }
    final buf = StringBuffer(
        '**Critic review**: ${flagged.length} dari ${findings.length} klaim '
        'TIDAK terverifikasi deterministik — mohon diverifikasi sebelum '
        'dipakai:\n');
    for (final f in flagged.take(5)) {
      buf.writeln('- [${f.kind}] ${f.claim}${f.detail.isEmpty ? '' : ' — ${f.detail}'}');
    }
    if (flagged.length > 5) buf.writeln('- …(+${flagged.length - 5} lagi)');
    return buf.toString();
  }
}

class FinalClaimCritic {
  const FinalClaimCritic({
    this.maxClaims = 16,
    this.maxClaimChars = 240,
    this.judge,
  });

  final int maxClaims;
  final int maxClaimChars;

  /// Mode `llm`: host menyuntikkan LLM auxiliar; balasan diharapkan memuat
  /// baris `VERDICT: pass|fail` + alasan. Null berarti mode deterministik.
  final Future<String?> Function(String prompt)? judge;

  static final RegExp _filePath = RegExp(
    r'[A-Za-z0-9_\-./]+\.(dart|md|json|yaml|yml|ts|tsx|js|jsx|py|txt|xml|'
    r'gradle|kt|java|go|rs|sh|toml|lock|html|css)',
    caseSensitive: false,
  );

  static final RegExp _successAssert = RegExp(
    r'\b(berhasil|sudah (selesai|diperbaiki|dihapus|dibuat|ditambahkan)|'
    r'lulus semua|semua (test|tes) lulus|all tests? pass|fixed|terverifikasi|'
    r'sudah (lulus|fix))\b',
    caseSensitive: false,
  );

  /// Potongan kalimat klaim — split pragmatis pada akhir kalimat.
  static List<String> _sentences(String text) {
    final cleaned = text.replaceAll('```', ' ');
    return cleaned
        .split(RegExp(r'(?<=[.!?])\s+|\n'))
        .map((s) => s.trim())
        .where((s) => s.length >= 8)
        .toList();
  }

  /// Review jawaban final. Tidak pernah throw.
  Future<ClaimCriticReport> review({
    required String answer,
    required String workspaceRoot,
  }) async {
    final findings = <ClaimFinding>[];
    final flagged = <ClaimFinding>[];
    void add(ClaimFinding f) {
      if (findings.length >= maxClaims) return;
      final claim = f.claim.length > maxClaimChars
          ? '${f.claim.substring(0, maxClaimChars)}…'
          : f.claim;
      final trimmed = ClaimFinding(
        claim: claim,
        kind: f.kind,
        verdict: f.verdict,
        detail: f.detail,
      );
      findings.add(trimmed);
      if (trimmed.verdict == 'unverified') flagged.add(trimmed);
    }

    for (final sentence in _sentences(answer)) {
      final paths = _filePath.allMatches(sentence)
          .map((m) => m.group(0)!)
          .toSet()
          .toList();
      var anyPathVerified = false;
      for (final path in paths.take(4)) {
        var verified = false;
        try {
          final resolved = PathSafety.resolveInRoot(workspaceRoot, path);
          verified = resolved != null && File(resolved).existsSync();
        } catch (_) {
          verified = false;
        }
        if (verified) {
          anyPathVerified = true;
          add(ClaimFinding(
            claim: sentence,
            kind: 'file_path',
            verdict: 'verified',
            detail: '$path ada di workspace',
          ));
        } else {
          add(ClaimFinding(
            claim: sentence,
            kind: 'file_path',
            verdict: 'unverified',
            detail: 'path $path tidak ditemukan/di luar workspace',
          ));
        }
      }
      if (paths.isEmpty && _successAssert.hasMatch(sentence)) {
        add(ClaimFinding(
          claim: sentence,
          kind: 'success_assertion',
          verdict: 'unverified',
          detail:
              'klaim sukses tanpa bukti file/verifikasi yang bisa dicek '
              'deterministik',
        ));
      } else if (anyPathVerified && _successAssert.hasMatch(sentence)) {
        add(ClaimFinding(
          claim: sentence,
          kind: 'success_assertion',
          verdict: 'verified',
          detail: 'didukung file yang ada di workspace',
        ));
      }
    }

    final judgeFn = judge;
    if (judgeFn != null && flagged.isNotEmpty) {
      final flaggedText = flagged
          .map((f) => '- ${f.claim}')
          .join('\n')
          .replaceAll(RegExp(r'```'), '');
      try {
        final verdict = await judgeFn('''
Periksa klaim berikut dari jawaban asisten. Untuk setiap klaim, tentukan
apakah benar-benar didukung bukti. Balas dengan format persis:
VERDICT: pass  (atau VERDICT: fail)
REASON: <maks 300 char>

Klaim yang diragukan:
$flaggedText''');
        final v = (verdict ?? '').toUpperCase();
        if (v.contains('VERDICT: FAIL') || v.contains('VERDICT:FAIL')) {
          final reasonLine = verdict!
              .split('\n')
              .firstWhere((l) => l.toUpperCase().startsWith('REASON'),
                  orElse: () => '');
          add(ClaimFinding(
            claim: reasonLine.isEmpty
                ? '(evaluasi LLM gagal)'
                : reasonLine.replaceFirst(RegExp(r'^REASON:\s*', caseSensitive: false), ''),
            kind: 'llm',
            verdict: 'unverified',
            detail: 'LLM judge menilai klaim tidak terdukung',
          ));
        }
      } catch (_) {
        // fail-open: judge gagal → hasil deterministik tetap dipakai.
      }
    }

    return ClaimCriticReport(findings: findings, flagged: flagged);
  }
}

/// Tool `critic` — review manual sebuah teks (deterministik, selalu
/// terdaftar, risk low).
class CriticTool implements Tool {
  const CriticTool();

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'critic',
        description:
            'Periksa klaim pada sebuah teks secara deterministik (file path '
            'diverifikasi ke workspace, klaim sukses tanpa bukti ditandai). '
            'Output laporan Markdown.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'Teks/jawaban yang ingin diperiksa klaimnya.',
            },
          },
          'required': ['text'],
        },
        risk: 'low',
        timeoutSec: 30,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final text = '${args['text'] ?? ''}'.trim();
    if (text.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'argumen `text` wajib.',
        isError: true,
      );
    }
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: text,
      workspaceRoot: ctx.workspacePath,
    );
    return ToolResult(
      callId: '',
      content:
          '${report.toMarkdown()}\n\n${const JsonEncoder.withIndent('  ').convert(report.toJson())}',
    );
  }
}
