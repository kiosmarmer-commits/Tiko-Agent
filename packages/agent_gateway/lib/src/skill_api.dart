import 'dart:async';
import 'dart:io';

/// Abstract interface for skill management operations (P1-03).
/// Implementations provide concrete storage and retrieval for skill definitions,
/// metrics, and approval workflows.
abstract class SkillApi {
  /// List all available skills.
  Future<Map<String, dynamic>> listSkills(HttpRequest req);

  /// Get a specific skill by slug.
  Future<Map<String, dynamic>> getSkill(HttpRequest req, String slug);

  /// Get the history of a specific skill.
  Future<Map<String, dynamic>> getSkillHistory(HttpRequest req, String slug);

  /// Get metrics for a specific skill.
  Future<Map<String, dynamic>> getSkillMetrics(HttpRequest req, String slug);

  /// Record feedback for a skill.
  Future<Map<String, dynamic>> recordFeedback(HttpRequest req, String slug);

  /// Evaluate a skill.
  Future<Map<String, dynamic>> evaluateSkill(HttpRequest req, String slug);

  /// Approve a skill.
  Future<Map<String, dynamic>> approveSkill(HttpRequest req, String slug);

  /// Rollback a skill to a previous version.
  Future<Map<String, dynamic>> rollbackSkill(HttpRequest req, String slug);
}
