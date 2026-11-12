/// Enhanced security layer (Tirith companion): prompt-injection detection,
/// output leak filtering, and rate anomaly detection.
///
/// Complements [TirithSecurityLayer] which covers tool/approval policy.
/// This module guards the *content* plane:
/// - [PromptGuard.inspectInput]: untrusted text (web, email, MCP, memory)
///   is scanned for injection techniques before it reaches the LLM.
/// - [PromptGuard.inspectOutput]: model/tool output is scanned for secret
///   and PII leakage before it leaves the process.
/// - [AnomalyDetector]: sliding-window event rate per key flags runaway
///   loops and credential-stuffing patterns.
library;

import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';

enum GuardSeverity { none, low, medium, high, critical }

enum GuardAction { allow, sanitize, block }

/// One matched detection rule.
class GuardFinding {
  const GuardFinding({
    required this.ruleId,
    required this.description,
    required this.severity,
    required this.excerpt,
  });

  final String ruleId;
  final String description;
  final GuardSeverity severity;

  /// Matched substring, truncated for safe logging.
  final String excerpt;

  Map<String, dynamic> toJson() => {
        'rule_id': ruleId,
        'description': description,
        'severity': severity.name,
        'excerpt': excerpt,
      };
}

/// Verdict of a guard inspection.
class GuardVerdict {
  const GuardVerdict({
    required this.action,
    required this.severity,
    this.findings = const [],
    this.sanitizedText,
  });

  final GuardAction action;
  final GuardSeverity severity;
  final List<GuardFinding> findings;

  /// Populated when [action] is [GuardAction.sanitize]: the safe
  /// replacement text. Null otherwise.
  final String? sanitizedText;

  bool get blocked => action == GuardAction.block;

  Map<String, dynamic> toJson() => {
        'action': action.name,
        'severity': severity.name,
        'findings': findings.map((f) => f.toJson()).toList(),
        if (sanitizedText != null) 'sanitized_text': sanitizedText,
      };
}

/// Content-plane guard with deterministic heuristic rules.
class PromptGuard {
  const PromptGuard({
    this.blockThreshold = GuardSeverity.high,
    this.sanitizeThreshold = GuardSeverity.low,
  });

  /// Findings at or above this severity block the text outright.
  final GuardSeverity blockThreshold;

  /// Findings at or above this severity (but below [blockThreshold])
  /// trigger sanitization instead of a plain allow.
  final GuardSeverity sanitizeThreshold;

  static final List<({String id, RegExp pattern, GuardSeverity severity,
      String description})> _injectionRules = [
    (
      id: 'PI-001',
      pattern: RegExp(
        r'ignore\s+(all\s+)?(previous|prior|above)\s+(instructions|prompts|rules)',
        caseSensitive: false,
      ),
      severity: GuardSeverity.critical,
      description: 'Instruction override attempt',
    ),
    (
      id: 'PI-002',
      pattern: RegExp(
        r'(reveal|show|print|repeat)\s+(me\s+)?(your\s+)?(system\s+)?'
        r'(prompt|instructions|rules)',
        caseSensitive: false,
      ),
      severity: GuardSeverity.high,
      description: 'System prompt extraction attempt',
    ),
    (
      id: 'PI-003',
      pattern: RegExp(
        r'(<\|im_start\|>|<\|endoftext\|>|\[INST\]|###\s*system)',
        caseSensitive: false,
      ),
      severity: GuardSeverity.high,
      description: 'Chat-template delimiter injection',
    ),
    (
      id: 'PI-004',
      pattern: RegExp(
        r'(you\s+are\s+now|act\s+as|pretend\s+to\s+be)\s+(a\s+)?'
        r'(dan|jailbreak|unrestricted|developer\s+mode)',
        caseSensitive: false,
      ),
      severity: GuardSeverity.high,
      description: 'Role hijack / jailbreak persona attempt',
    ),
    (
      id: 'PI-005',
      pattern: RegExp(r'\b[A-Za-z0-9+/]{120,}={0,2}\b'),
      severity: GuardSeverity.medium,
      description: 'Long base64 blob (possible encoded payload)',
    ),
    (
      id: 'PI-006',
      pattern: RegExp(
        r'(call|invoke|execute)\s+(the\s+)?(tool|function)\s+'
        r'(named\s+)?["\x27]?\w+["\x27]?\s+(with|using)\s+',
        caseSensitive: false,
      ),
      severity: GuardSeverity.medium,
      description: 'Tool invocation instruction embedded in content',
    ),
  ];

  static final List<({String id, RegExp pattern, GuardSeverity severity,
      String description, String replacement})> _outputRules = [
    (
      id: 'OF-001',
      pattern: RegExp(r'\bsk-[A-Za-z0-9]{20,}\b'),
      severity: GuardSeverity.critical,
      description: 'OpenAI-style API key',
      replacement: '[REDACTED:api-key]',
    ),
    (
      id: 'OF-002',
      pattern: RegExp(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
      severity: GuardSeverity.critical,
      description: 'GitHub token',
      replacement: '[REDACTED:github-token]',
    ),
    (
      id: 'OF-003',
      pattern: RegExp(r'-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'),
      severity: GuardSeverity.critical,
      description: 'Private key material',
      replacement: '[REDACTED:private-key]',
    ),
    (
      id: 'OF-004',
      pattern: RegExp(r'\bBearer\s+[A-Za-z0-9._\-]{16,}\b',
          caseSensitive: false),
      severity: GuardSeverity.high,
      description: 'Bearer token',
      replacement: '[REDACTED:bearer]',
    ),
    (
      id: 'OF-005',
      pattern: RegExp(
        r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
      severity: GuardSeverity.low,
      description: 'Email address (PII)',
      replacement: '[REDACTED:email]',
    ),
    (
      id: 'OF-006',
      pattern: RegExp(r'\b(?:\+62|62|0)8\d{2}[\s-]?\d{4}[\s-]?\d{3,5}\b'),
      severity: GuardSeverity.low,
      description: 'Indonesian phone number (PII)',
      replacement: '[REDACTED:phone]',
    ),
  ];

  /// Scans untrusted input for prompt-injection techniques. Untrusted
  /// provenance ([Provenance.web], [Provenance.email], [Provenance.mcp],
  /// [Provenance.unknown]) escalates every finding by one severity level.
  GuardVerdict inspectInput(
    String text, {
    Provenance provenance = Provenance.unknown,
  }) {
    final untrusted = _isUntrusted(provenance);
    final findings = <GuardFinding>[];
    for (final rule in _injectionRules) {
      final match = rule.pattern.firstMatch(text);
      if (match == null) continue;
      var severity = rule.severity;
      if (untrusted) {
        severity = _escalate(severity);
      }
      findings.add(GuardFinding(
        ruleId: rule.id,
        description: rule.description,
        severity: severity,
        excerpt: _excerpt(match.group(0) ?? ''),
      ));
    }
    return _verdict(text, findings);
  }

  /// Scans outbound text for secrets and PII. Findings below the sanitize
  /// threshold still produce a sanitized copy when any rule matched.
  GuardVerdict inspectOutput(String text) {
    final findings = <GuardFinding>[];
    var sanitized = text;
    for (final rule in _outputRules) {
      final matches = rule.pattern.allMatches(text);
      if (matches.isEmpty) continue;
      findings.add(GuardFinding(
        ruleId: rule.id,
        description: rule.description,
        severity: rule.severity,
        excerpt: _excerpt(matches.first.group(0) ?? ''),
      ));
      sanitized = sanitized.replaceAll(rule.pattern, rule.replacement);
    }
    return _verdict(text, findings, sanitizedText: sanitized);
  }

  GuardVerdict _verdict(
    String text,
    List<GuardFinding> findings, {
    String? sanitizedText,
  }) {
    if (findings.isEmpty) {
      return const GuardVerdict(action: GuardAction.allow,
          severity: GuardSeverity.none);
    }
    final maxSeverity = findings
        .map((f) => f.severity.index)
        .reduce(math.max);
    final severity = GuardSeverity.values[maxSeverity];
    if (severity.index >= blockThreshold.index) {
      return GuardVerdict(action: GuardAction.block, severity: severity,
          findings: findings);
    }
    if (severity.index >= sanitizeThreshold.index) {
      return GuardVerdict(
        action: GuardAction.sanitize,
        severity: severity,
        findings: findings,
        sanitizedText: sanitizedText,
      );
    }
    return GuardVerdict(action: GuardAction.allow, severity: severity,
        findings: findings);
  }

  static bool _isUntrusted(Provenance provenance) => switch (provenance) {
        Provenance.trustedConfig || Provenance.user => false,
        Provenance.localFile ||
        Provenance.web ||
        Provenance.email ||
        Provenance.mcp ||
        Provenance.memory ||
        Provenance.agent ||
        Provenance.unknown =>
          true,
      };

  static GuardSeverity _escalate(GuardSeverity severity) {
    final next = math.min(severity.index + 1, GuardSeverity.critical.index);
    return GuardSeverity.values[next];
  }

  static String _excerpt(String raw) {
    final flat = raw.replaceAll('\n', ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 77)}...';
  }
}

/// Sliding-window rate anomaly detector. Tracks event timestamps per key
/// and flags keys whose event count within [window] exceeds [maxEvents].
class AnomalyDetector {
  AnomalyDetector({
    this.maxEvents = 30,
    this.window = const Duration(minutes: 1),
  }) : _events = {};

  final int maxEvents;
  final Duration window;
  final Map<String, List<DateTime>> _events;

  /// Records an event at [now] and prunes the window.
  void record(String key, DateTime now) {
    final list = _events.putIfAbsent(key, () => <DateTime>[]);
    list.add(now.toUtc());
    _prune(list, now);
  }

  /// True when [key] exceeded [maxEvents] within [window] as of [now].
  bool isAnomalous(String key, DateTime now) {
    final list = _events[key];
    if (list == null) return false;
    _prune(list, now);
    return list.length > maxEvents;
  }

  /// Current event count for [key] inside the window.
  int count(String key, DateTime now) {
    final list = _events[key];
    if (list == null) return 0;
    _prune(list, now);
    return list.length;
  }

  void reset([String? key]) {
    if (key == null) {
      _events.clear();
    } else {
      _events.remove(key);
    }
  }

  void _prune(List<DateTime> list, DateTime now) {
    final cutoff = now.toUtc().subtract(window);
    list.removeWhere((t) => t.isBefore(cutoff));
  }
}
