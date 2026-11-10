import 'dart:convert';

/// Stable 32-bit FNV-1a over UTF-8 bytes, hex encoded. A short tamper
/// marker for tool outputs bound to claims (NEW-04): the raw output
/// is never stored, so the ledger itself can never leak tool output.
String evidenceHash(String output) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(output)) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// One executed tool call whose output hash was recorded.
class EvidenceRecord {
  const EvidenceRecord({
    required this.id,
    required this.tool,
    required this.hash,
    required this.recordedAt,
  });

  final String id;
  final String tool;
  final String hash;
  final String recordedAt;
}

/// Claim + the output hashes it was bound to at claim time.
class ClaimRecord {
  ClaimRecord({required this.text, required Map<String, String> bound})
      : bound = Map.unmodifiable(bound),
        claimedAt = DateTime.now().toUtc().toIso8601String();

  final String text;
  final Map<String, String> bound;
  final String claimedAt;
}

/// Outcome of verifying one claim against the ledger.
class ClaimVerification {
  const ClaimVerification({
    required this.claim,
    required this.supported,
    required this.missing,
    required this.stale,
  });

  final ClaimRecord claim;
  final bool supported;
  final List<String> missing;
  final List<String> stale;
}

/// evidence_ledger (NEW-04): every executed tool call is recorded by
/// output hash; claims must cite recorded call IDs and are re-verified
/// on demand, so a statement like "semua tes lulus" has to point at
/// the call that proves it. A re-executed call whose output hash
/// changed after the claim marks the evidence stale.
class EvidenceLedger {
  final Map<String, EvidenceRecord> _calls = {};
  final List<ClaimRecord> _claims = [];
  int _counter = 0;

  /// Records (or re-records) one tool call's output hash and returns
  /// the evidence ID that claims should cite.
  String recordCall(String callId, String tool, String output) {
    final id = callId.isEmpty ? 'call-${_counter + 1}' : callId;
    if (callId.isEmpty) _counter++;
    _calls[id] = EvidenceRecord(
      id: id,
      tool: tool,
      hash: evidenceHash(output),
      recordedAt: DateTime.now().toUtc().toIso8601String(),
    );
    return id;
  }

  /// True when [id] has been recorded.
  bool has(String id) => _calls.containsKey(id);

  /// Binds a claim to the current hash of each cited call ID.
  /// Returns the list of unknown IDs, or null on success.
  List<String>? addClaim(String text, List<String> evidenceIds) {
    final unknown = evidenceIds.where((id) => !has(id)).toList();
    if (unknown.isNotEmpty) return unknown;
    final bound = <String, String>{};
    for (final id in evidenceIds) {
      bound[id] = _calls[id]!.hash;
    }
    _claims.add(ClaimRecord(text: text, bound: bound));
    return null;
  }

  /// Re-verifies every claim: cited IDs must exist and must still
  /// hash to the value bound at claim time.
  List<ClaimVerification> verify() {
    final out = <ClaimVerification>[];
    for (final c in _claims) {
      final missing = <String>[];
      final stale = <String>[];
      for (final id in c.bound.keys) {
        final rec = _calls[id];
        if (rec == null) {
          missing.add(id);
        } else if (rec.hash != c.bound[id]) {
          stale.add(id);
        }
      }
      out.add(ClaimVerification(
        claim: c,
        supported: missing.isEmpty && stale.isEmpty,
        missing: missing,
        stale: stale,
      ));
    }
    return out;
  }

  /// Ledger sizes for tests and admin views.
  int get callCount => _calls.length;
  int get claimCount => _claims.length;
}
