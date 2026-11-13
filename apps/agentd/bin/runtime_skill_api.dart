import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Concrete [SkillApi] backed by the live [TikoRuntime] state.
///
/// Closes the feedback loop end-to-end: `POST /v1/skills/<slug>/feedback` now
/// reaches [SkillRegistry.applyFeedback], which updates in-memory reliability
/// and writes through the durable [SkillMetricsLedger] sink. Metrics are
/// telemetry only — feedback never promotes a draft/trial skill.
class RuntimeSkillApi implements SkillApi {
  RuntimeSkillApi(this._rt);

  final TikoRuntime _rt;

  SkillRegistry get _skills => _rt.skills;

  Map<String, dynamic> _metricsJson(String slug) {
    final m = _rt.skillMetrics.of(slug);
    return {
      'uses': m?.uses ?? 0,
      'successes': m?.successes ?? 0,
      'positive': m?.positive ?? 0,
      'negative': m?.negative ?? 0,
      'last_used_at': m?.lastUsedAt?.toIso8601String(),
    };
  }

  Map<String, dynamic> _skillJson(Skill s) => {
        ...s.toJson(),
        'metrics': _metricsJson(s.slug),
      };

  @override
  Future<Map<String, dynamic>> listSkills(HttpRequest req) async => {
        'skills': [for (final s in _skills.all) _skillJson(s)],
      };

  @override
  Future<Map<String, dynamic>> getSkill(HttpRequest req, String slug) async {
    final s = _skills.get(slug);
    if (s == null) return {'error': 'skill not found: $slug'};
    return _skillJson(s);
  }

  @override
  Future<Map<String, dynamic>> getSkillHistory(
    HttpRequest req,
    String slug,
  ) async => {
        'slug': slug,
        'history': [
          for (final r in _rt.skillLedger.records)
            if (r.slug == slug) r.toJson(),
        ],
      };

  @override
  Future<Map<String, dynamic>> getSkillMetrics(
    HttpRequest req,
    String slug,
  ) async =>
      {'slug': slug, 'metrics': _metricsJson(slug)};

  @override
  Future<Map<String, dynamic>> recordFeedback(HttpRequest req, String slug) async {
    final s = _skills.get(slug);
    if (s == null) return {'error': 'skill not found: $slug'};
    if (s.status == SkillStatus.draft || s.status == SkillStatus.retired) {
      return {
        'error': 'skill $slug is ${s.status.name}; feedback applies to '
            'active skills only',
      };
    }
    Map<String, dynamic> body;
    try {
      final raw = await utf8.decoder.bind(req).join();
      body = raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {'error': 'invalid JSON body'};
    }
    final positive = body['positive'];
    if (positive is! bool) {
      return {'error': "field 'positive' (bool) is required"};
    }
    _skills.applyFeedback(slug, positive: positive);
    // The registry tracks sink writes; awaiting them guarantees the durable
    // metrics ledger has absorbed this feedback before the response returns.
    await _skills.flushPendingSinks();
    return {
      'slug': slug,
      'recorded': true,
      'positive': positive,
      'metrics': _metricsJson(slug),
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSkill(HttpRequest req, String slug) async {
    try {
      final result = await _rt.evaluateSkill(slug, actor: 'api');
      return {'slug': slug, ...result.toJson()};
    } on ArgumentError {
      return {'error': 'skill not found: $slug'};
    }
  }

  @override
  Future<Map<String, dynamic>> approveSkill(HttpRequest req, String slug) async {
    try {
      final result = await _rt.approveSkill(slug, actor: 'api');
      return {'slug': slug, ...result.toJson()};
    } on ArgumentError {
      return {'error': 'skill not found: $slug'};
    }
  }

  @override
  Future<Map<String, dynamic>> rollbackSkill(HttpRequest req, String slug) async {
    try {
      final result = await _rt.rollbackSkill(slug, actor: 'api');
      return {'slug': slug, ...result.toJson()};
    } on ArgumentError {
      return {'error': 'skill not found: $slug'};
    }
  }
}
