/// Stub entry — wire to Flutter MaterialApp on a device with Flutter SDK:
///
/// ```dart
/// void main() => runApp(AgentApp(token: const String.fromEnvironment('API_TOKEN', defaultValue: '')));
/// ```
///
/// Screens planned:
/// - ChatPage (ChatController)
/// - StatusPage (/v1/status)
/// - MemoriesPage (/v1/memories)
/// - SettingsPage (baseUrl, token)
///
/// Run agentd: `API_TOKEN=<TOKEN_DARI_TERMINAL> dart run apps/agentd/bin/agentd.dart --api`
library;

export 'agent_api_client.dart';
export 'ui/chat_controller.dart';
