import 'dart:async';

import 'package:http/http.dart' as http;

import '../agent_api_client.dart';
import 'api_error.dart';
import 'models.dart';

/// Lapisan repository typed (GUI-P0-03): halaman UI memakai DTO, bukan
/// Map mentah. Test dapat mengganti implementasi ini dengan fake.
abstract class AgentRepository {
  Future<bool> health();
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> capabilities();

  /// Baris doctor tetap Map karena payload per-check heterogen.
  Future<List<Map<String, dynamic>>> doctor();
  Future<List<SessionSummary>> sessions();
  Future<List<SessionMessage>> sessionMessages(
    String sessionId, {
    int limit,
    int offset,
  });
  Future<bool> deleteSession(String sessionId);
  Future<bool> renameSession(String sessionId, String title);
  Future<List<ApprovalSummary>> approvals();
  Future<bool> decideApproval(String id, bool approve);
  Future<List<RuntimeEvent>> events();
  Future<List<TaskItem>> tasks();
  Future<List<LogFileInfo>> logs();
  Future<LogFileContent> logContent(String name);
  Future<List<SkillItem>> skills();
  Future<bool> skillFeedback(String slug, bool positive);
  Future<SkillGateOutcome> evaluateSkill(String slug);
  Future<SkillGateOutcome> approveSkill(String slug);
  Future<SkillGateOutcome> rollbackSkill(String slug);
  Future<List<SkillHistoryEntry>> skillHistory(String slug);
  Future<ProvidersSnapshot> providers();
  Future<bool> setSessionProvider(String sessionId, String providerArg);
  Future<List<BotProfileItem>> bots();
  Future<BotProfileItem> createBot(Map<String, dynamic> body);
  Future<BotProfileItem> updateBot(String id, Map<String, dynamic> body);
  Future<bool> deleteBot(String id);
  Future<Map<String, String>> botBindings();
  Future<bool> bindBot(String botId, String sessionId);
  Future<bool> unbindBot(String botId, String sessionId);
  Future<List<MemoryFact>> memories();
  Future<bool> deleteMemory(String id);
  Future<String> sendMessage(String text, {String sessionKey});
  Future<String> submitUiAction(
    String sessionKey,
    String actionId,
    Map<String, dynamic> values,
  );
  Stream<Map<String, dynamic>> streamChat(String text, {String sessionKey});
}

/// Implementasi HTTP di atas [AgentApiClient]; menerjemahkan kegagalan
/// transport menjadi [ApiError] (network/timeout) tanpa mengubah error lain.
class HttpAgentRepository implements AgentRepository {
  HttpAgentRepository(this._client);

  final AgentApiClient _client;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiError {
      rethrow;
    } on TimeoutException catch (e) {
      throw ApiError.timeout(e.message ?? 'koneksi timeout');
    } on http.ClientException catch (e) {
      throw ApiError.network(e.message);
    }
  }

  @override
  Future<bool> health() => _guard(_client.health);

  @override
  Future<Map<String, dynamic>> status() => _guard(_client.status);

  @override
  Future<Map<String, dynamic>> capabilities() => _guard(_client.capabilities);

  @override
  Future<List<Map<String, dynamic>>> doctor() => _guard(_client.doctor);

  @override
  Future<List<SessionSummary>> sessions() async =>
      (await _guard(_client.listSessions))
          .map(SessionSummary.fromMap)
          .toList();

  @override
  Future<List<SessionMessage>> sessionMessages(
    String sessionId, {
    int limit = 50,
    int offset = 0,
  }) async =>
      (await _guard(() => _client.fetchSessionMessages(
            sessionId,
            limit: limit,
            offset: offset,
          )))
          .map(SessionMessage.fromMap)
          .toList();

  @override
  Future<bool> deleteSession(String sessionId) =>
      _guard(() => _client.deleteSession(sessionId));

  @override
  Future<bool> renameSession(String sessionId, String title) =>
      _guard(() => _client.renameSession(sessionId, title));

  @override
  Future<List<ApprovalSummary>> approvals() async =>
      (await _guard(_client.listApprovals))
          .map(ApprovalSummary.fromMap)
          .toList();

  @override
  Future<bool> decideApproval(String id, bool approve) =>
      _guard(() => _client.decideApproval(id, approve));

  @override
  Future<List<RuntimeEvent>> events() async => (await _guard(_client.listEvents))
      .map(RuntimeEvent.fromMap)
      .toList();

  @override
  Future<List<TaskItem>> tasks() async =>
      (await _guard(_client.listTasks)).map(TaskItem.fromMap).toList();

  @override
  Future<List<LogFileInfo>> logs() async =>
      (await _guard(_client.listLogs)).map(LogFileInfo.fromMap).toList();

  @override
  Future<LogFileContent> logContent(String name) async =>
      LogFileContent.fromMap(await _guard(() => _client.fetchLogContent(name)));

  @override
  Future<List<SkillItem>> skills() async =>
      (await _guard(_client.listSkills)).map(SkillItem.fromMap).toList();

  @override
  Future<bool> skillFeedback(String slug, bool positive) async {
    final result =
        await _guard(() => _client.sendSkillFeedback(slug, positive));
    return result['recorded'] == true;
  }

  @override
  Future<SkillGateOutcome> evaluateSkill(String slug) async =>
      SkillGateOutcome.fromMap(await _guard(() => _client.evaluateSkill(slug)));

  @override
  Future<SkillGateOutcome> approveSkill(String slug) async =>
      SkillGateOutcome.fromMap(await _guard(() => _client.approveSkill(slug)));

  @override
  Future<SkillGateOutcome> rollbackSkill(String slug) async =>
      SkillGateOutcome.fromMap(await _guard(() => _client.rollbackSkill(slug)));

  @override
  Future<List<SkillHistoryEntry>> skillHistory(String slug) async =>
      (await _guard(() => _client.fetchSkillHistory(slug)))
          .map(SkillHistoryEntry.fromMap)
          .toList();

  @override
  Future<List<BotProfileItem>> bots() async =>
      (await _guard(_client.listBots)).map(BotProfileItem.fromMap).toList();

  @override
  Future<ProvidersSnapshot> providers() async =>
      ProvidersSnapshot.fromMap(await _guard(_client.fetchProviders));

  @override
  Future<bool> setSessionProvider(String sessionId, String providerArg) =>
      _guard(() => _client.setSessionProvider(sessionId, providerArg));

  @override
  Future<BotProfileItem> createBot(Map<String, dynamic> body) async =>
      BotProfileItem.fromMap(await _guard(() => _client.createBot(body)));

  @override
  Future<BotProfileItem> updateBot(String id, Map<String, dynamic> body) async =>
      BotProfileItem.fromMap(await _guard(() => _client.updateBot(id, body)));

  @override
  Future<bool> deleteBot(String id) => _guard(() => _client.deleteBot(id));

  @override
  Future<Map<String, String>> botBindings() =>
      _guard(_client.listBotBindings);

  @override
  Future<bool> bindBot(String botId, String sessionId) =>
      _guard(() => _client.bindBot(botId, sessionId));

  @override
  Future<bool> unbindBot(String botId, String sessionId) =>
      _guard(() => _client.unbindBot(botId, sessionId));

  @override
  Future<List<MemoryFact>> memories() async => (await _guard(_client.listMemories))
      .map(MemoryFact.fromMap)
      .toList();

  @override
  Future<bool> deleteMemory(String id) => _guard(() => _client.deleteMemory(id));

  @override
  Future<String> sendMessage(String text, {String sessionKey = 'flutter:default'}) =>
      _guard(() => _client.sendMessage(text, sessionKey: sessionKey));

  @override
  Future<String> submitUiAction(
    String sessionKey,
    String actionId,
    Map<String, dynamic> values,
  ) =>
      _guard(() => _client.submitUiAction(sessionKey, actionId, values));

  @override
  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
  }) =>
      _client.streamChat(text, sessionKey: sessionKey);
}
