import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// HTTP DecisionProvider for TypeSafe Jev / Laya `laya-serve` (TASK-02-02).
///
/// Endpoint shape (best-effort, verify with curl on your server):
///   POST {baseUrl}/v1/systemone
///   body: { "model": "...", "state": "...", "questions": { name: Question } }
///
/// Field names for auth/state may differ by vendor — adapter is isolated.
class SystemOneDecisionProvider implements DecisionProvider {
  SystemOneDecisionProvider({
    required this.baseUrl,
    this.model = 'jev-latest',
    this.apiKey,
    this.httpClient,
    this.path = '/v1/systemone',
  });

  final String baseUrl;
  final String model;
  final String? apiKey;
  final http.Client? httpClient;
  final String path;

  @override
  Future<DecisionResult> decide(
    String state,
    Map<String, Question> questions,
  ) async {
    final uri = Uri.parse(
      baseUrl.endsWith('/')
          ? '${baseUrl.substring(0, baseUrl.length - 1)}$path'
          : '$baseUrl$path',
    );

    final body = {
      'model': model,
      'state': state,
      'questions': questions.map((k, q) => MapEntry(k, q.toJson())),
    };

    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (apiKey != null && apiKey!.isNotEmpty)
                'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode >= 400) {
        throw StateError('SystemOne HTTP ${res.statusCode}: ${res.body}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return DecisionResult.fromJson(json);
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
