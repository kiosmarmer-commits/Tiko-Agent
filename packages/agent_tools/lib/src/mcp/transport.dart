import 'dart:async';

/// Abstract MCP transport (DEC-06) — stdio first, Streamable HTTP later.
abstract class McpTransport {
  Future<void> start();
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]);
  Future<void> notify(String method, [Map<String, dynamic>? params]);
  Future<void> close();
}
