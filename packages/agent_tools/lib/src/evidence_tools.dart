import 'package:agent_core/agent_core.dart';

/// claim (NEW-04) — bind a statement about the work to executed
/// tool-call evidence IDs; unsupported claims are rejected.
class ClaimTool implements Tool {
  ClaimTool({required this.ledger});

  final EvidenceLedger ledger;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'claim',
    description:
        'Nyatakan klaim hasil kerja dan ikat ke ID bukti (call ID) '
        'yang mendukungnya. Klaim tanpa bukti yang valid ditolak.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'Isi klaim.'},
        'evidence': {
          'type': 'array',
          'description': 'ID bukti (call ID) yang mendukung klaim.',
        },
      },
      'required': ['text', 'evidence'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final text = (args['text'] as String?)?.trim() ?? '';
    final raw = args['evidence'];
    if (text.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'text wajib',
        isError: true,
      );
    }
    if (text.length > 500) {
      return const ToolResult(
        callId: '',
        content: 'maksimal 500 karakter',
        isError: true,
      );
    }
    if (raw is! List || raw.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'evidence wajib array ID bukti',
        isError: true,
      );
    }
    final ids = raw
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if (ids.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'evidence wajib array ID bukti',
        isError: true,
      );
    }
    final unknown = ledger.addClaim(text, ids);
    if (unknown != null) {
      return ToolResult(
        callId: '',
        content: 'Bukti tidak dikenal: ${unknown.join(', ')}',
        isError: true,
      );
    }
    return ToolResult(
      callId: '',
      content: 'OK klaim #${ledger.claimCount} dicatat '
          '(${ids.length} bukti)',
    );
  }
}

/// verify_claims — re-check every claim against the evidence ledger.
class VerifyClaimsTool implements Tool {
  VerifyClaimsTool({required this.ledger});

  final EvidenceLedger ledger;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'verify_claims',
    description:
        'Uji ulang semua klaim terhadap ledger bukti: ID bukti wajib '
        'ada dan hash output-nya belum berubah sejak klaim dibuat.',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final results = ledger.verify();
    if (results.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Belum ada klaim.',
        isError: true,
      );
    }
    final lines = <String>[];
    var allOk = true;
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (!r.supported) allOk = false;
      final flags = [
        if (r.missing.isNotEmpty) 'hilang: ${r.missing.join(', ')}',
        if (r.stale.isNotEmpty) 'kedaluwarsa: ${r.stale.join(', ')}',
      ].join('; ');
      lines.add(
        '${r.supported ? 'OK  ' : 'FAIL'} klaim #${i + 1}: ${r.claim.text}'
        '${flags.isEmpty ? '' : ' ($flags)'}',
      );
    }
    return ToolResult(
      callId: '',
      content: lines.join('\n'),
      isError: !allOk,
    );
  }
}
