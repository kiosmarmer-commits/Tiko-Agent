import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'http_client.dart';
import '../registry.dart';

/// Handler for server-initiated JSON-RPC requests received via MCP SSE.
///
/// When an MCP server sends a request with an 'id' field on the event stream,
/// this handler processes it and returns a response. This enables full
/// bidirectional communication with MCP servers that support server-initiated
/// requests (similar to Hermes Agent's implementation).
class McpServerRequestHandler {
  McpServerRequestHandler({
    required this.client,
    required this.toolRegistry,
    required this.onServerRequest,
    this.onSampling,
    this.maxSamplingPerMinute = 10,
    this.maxConcurrentRequests = 10,
    this.requestTimeout = const Duration(seconds: 30),
  });

  /// The HTTP MCP client that receives server requests.
  final HttpMcpClient client;

  /// Registry of available tools for handling server requests.
  final ToolRegistry toolRegistry;

  /// Callback for server requests that cannot be handled automatically.
  /// This allows custom handling of server-initiated requests.
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
    String requestId,
  )? onServerRequest;

  /// Callback for `sampling/createMessage` server requests (MCP sampling).
  /// Receives the request params and must return the sampled message result
  /// (`{"role": ..., "content": {"type": "text", "text": ...}, ...}`).
  /// Returning null declines the request with a method-not-found error.
  final Future<Map<String, dynamic>?> Function(
    Map<String, dynamic> params,
    String requestId,
  )? onSampling;

  /// Maximum `sampling/createMessage` requests answered per sliding minute.
  /// Excess requests are declined with a rate-limit error (P1-7).
  final int maxSamplingPerMinute;

  /// Maximum concurrent server request handlers.
  final int maxConcurrentRequests;

  /// Timeout for handling server requests.
  final Duration requestTimeout;

  bool _isRunning = false;
  final _activeRequests = <String, Completer<Map<String, dynamic>>>{};
  final _samplingWindow = <DateTime>[];
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Starts handling server requests from the SSE event stream.
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    // Subscribe to server requests
    _subscription = client.serverEvents.listen(_handleServerEvent);
  }

  /// Stops handling server requests.
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    // Cancel all active requests
    for (final entry in _activeRequests.entries) {
      entry.value.completeError(
        Exception('Server request handler stopped'),
      );
    }
    _activeRequests.clear();

    await _subscription?.cancel();
    _subscription = null;
  }

  /// Handles a server event from the SSE stream.
  Future<void> _handleServerEvent(Map<String, dynamic> event) async {
    // Check if this is a server-initiated request (has an 'id' field)
    if (event.containsKey('id') && event.containsKey('method')) {
      await _handleServerRequest(event);
    }
  }

  /// Handles a server-initiated JSON-RPC request.
  Future<void> _handleServerRequest(Map<String, dynamic> request) async {
    final requestId = request['id']?.toString();
    final method = request['method']?.toString();
    final params = request['params'] as Map<String, dynamic>? ?? {};

    if (requestId == null || method == null) {
      return; // Ignore malformed requests
    }

    // Check if we're already handling this request
    if (_activeRequests.containsKey(requestId)) {
      return; // Already being processed
    }

    // Check concurrency limit
    if (_activeRequests.length >= maxConcurrentRequests) {
      // Send error response for rate limiting
      await _sendResponse(requestId, {
        'jsonrpc': '2.0',
        'id': requestId,
        'error': {
          'code': -32603, // Internal error
          'message': 'Server request handler busy',
        },
      });
      return;
    }

    // Create a completer for tracking the request. It is diagnostic only:
    // errors are reported to the server via _sendResponse, so the future is
    // ignored to avoid unhandled async errors when stop() completes it.
    final completer = Completer<Map<String, dynamic>>();
    completer.future.ignore();
    _activeRequests[requestId] = completer;

    try {
      // Handle the request with timeout
      final response = await _processRequest(method, params, requestId)
          .timeout(requestTimeout);

      // Send the response
      await _sendResponse(requestId, {
        'jsonrpc': '2.0',
        'id': requestId,
        'result': response,
      });

      if (!completer.isCompleted) completer.complete(response);
    } catch (e) {
      // Send error response
      await _sendResponse(requestId, {
        'jsonrpc': '2.0',
        'id': requestId,
        'error': {
          'code': _errorCodeFor(e),
          'message': e.toString(),
        },
      });

      if (!completer.isCompleted) completer.completeError(e);
    } finally {
      _activeRequests.remove(requestId);
    }
  }

  static int _errorCodeFor(Object error) {
    if (error is McpSamplingRateLimitException) return -32005;
    if (error is McpSamplingUnsupportedException) return -32601;
    return -32603;
  }

  /// Processes a server-initiated request.
  Future<Map<String, dynamic>> _processRequest(
    String method,
    Map<String, dynamic> params,
    String requestId,
  ) async {
    // First, try custom handler
    if (onServerRequest != null) {
      try {
        final result = await onServerRequest!(method, params, requestId);
        if (result.isNotEmpty) {
          return result;
        }
      } catch (e) {
        // Fall through to default handling
      }
    }

    // Handle known MCP server request methods
    switch (method) {
      case 'tools/call':
        return await _handleToolCall(params);

      case 'tools/list':
        return await _handleToolsList();

      case 'resources/list':
        return await _handleResourcesList(params);

      case 'resources/read':
        return await _handleResourceRead(params);

      case 'sampling/createMessage':
        return await _handleSampling(params, requestId);

      default:
        // Unknown method - return method not found error
        throw Exception('Unknown MCP server request method: $method');
    }
  }

  /// Handles a tool call request from the server.
  Future<Map<String, dynamic>> _handleToolCall(
    Map<String, dynamic> params,
  ) async {
    final name = params['name'] as String?;
    final arguments = params['arguments'] as Map<String, dynamic>? ?? {};

    if (name == null) {
      throw ArgumentError('Tool name is required');
    }

    // Get the tool from registry
    final tool = toolRegistry.get(name);
    if (tool == null) {
      throw Exception('Tool not found: $name');
    }

    // Execute the tool
    final ctx = ToolContext(
      session: Session(
        id: 'mcp_${DateTime.now().millisecondsSinceEpoch}',
        channel: 'mcp',
        userKey: 'mcp-server',
      ),
      workspacePath: Directory.current.path,
    );
    final result = await tool.run(arguments, ctx);

    // Format the response
    return {
      'content': [
        {'type': 'text', 'text': result.content},
      ],
    };
  }

  /// Handles a tools/list request from the server.
  Future<Map<String, dynamic>> _handleToolsList() async {
    return {
      'tools': toolRegistry.specs
          .map((spec) => {
                'name': spec.name,
                'description': spec.description,
                'inputSchema': spec.inputSchema,
              })
          .toList(),
    };
  }

  /// Handles a resources/list request from the server.
  Future<Map<String, dynamic>> _handleResourcesList(
    Map<String, dynamic> params,
  ) async {
    // For now, return empty list as resources are not fully implemented
    // This can be extended when resource support is added
    return {
      'resources': [],
    };
  }

  /// Handles a `sampling/createMessage` request from the server (P1-7).
  /// Enforces a sliding-window rate limit before delegating to [onSampling].
  Future<Map<String, dynamic>> _handleSampling(
    Map<String, dynamic> params,
    String requestId,
  ) async {
    final now = DateTime.now();
    _samplingWindow.removeWhere(
      (t) => now.difference(t) >= const Duration(minutes: 1),
    );
    if (_samplingWindow.length >= maxSamplingPerMinute) {
      throw const McpSamplingRateLimitException();
    }
    _samplingWindow.add(now);

    if (onSampling == null) {
      throw const McpSamplingUnsupportedException();
    }
    final result = await onSampling!(params, requestId);
    if (result == null) {
      throw const McpSamplingUnsupportedException();
    }
    return result;
  }

  /// Handles a resources/read request from the server.
  Future<Map<String, dynamic>> _handleResourceRead(
    Map<String, dynamic> params,
  ) async {
    final uri = params['uri'] as String?;
    
    if (uri == null) {
      throw ArgumentError('Resource URI is required');
    }

    // For now, return error as resources are not fully implemented
    throw Exception('Resource reading not yet implemented');
  }

  /// Sends a JSON-RPC response back to the server by POSTing it to the MCP
  /// endpoint (Streamable HTTP permits responses on POST). The response is
  /// retained on the client for diagnostics; transport failures are recorded
  /// but never propagate to the request pipeline.
  Future<void> _sendResponse(
    String requestId,
    Map<String, dynamic> response,
  ) async {
    client.serverRequests.add({
      'id': requestId,
      'response': response,
      'timestamp': DateTime.now().toIso8601String(),
    });
    await client.postServerResponse(response);
  }

  /// Gets the current status of the handler.
  Map<String, dynamic> getStatus() {
    return {
      'isRunning': _isRunning,
      'activeRequests': _activeRequests.length,
      'maxConcurrentRequests': maxConcurrentRequests,
      'requestTimeout': requestTimeout.inSeconds,
    };
  }

  /// Gets statistics about handled requests.
  Map<String, dynamic> getStatistics() {
    return {
      'totalRequests': client.serverRequests.length,
      'totalNotifications': client.notifications.length,
      'totalTransportErrors': client.transportErrors.length,
      'lastRequestTime': client.serverRequests.isNotEmpty
          ? client.serverRequests.last['timestamp']
          : null,
    };
  }
}

/// Declined a `sampling/createMessage` request because the per-minute
/// sampling budget is exhausted.
class McpSamplingRateLimitException implements Exception {
  const McpSamplingRateLimitException();

  @override
  String toString() => 'MCP sampling rate limit exceeded';
}

/// Declined a `sampling/createMessage` request because no sampling callback
/// is configured or the callback declined.
class McpSamplingUnsupportedException implements Exception {
  const McpSamplingUnsupportedException();

  @override
  String toString() => 'MCP sampling/createMessage is not supported';
}

/// Enhanced HTTP MCP client with full server request handling.
///
/// This extends the basic HttpMcpClient to properly handle server-initiated
/// requests, similar to Hermes Agent's implementation.
class EnhancedHttpMcpClient extends HttpMcpClient {
  EnhancedHttpMcpClient({
    required super.baseUrl,
    super.headers,
    super.httpClient,
    super.protocolVersion = '2025-11-25',
    super.maxOutputChars = 100000,
    super.maxReadRetries = 2,
    super.maxEventChars = 262144,
    super.maxObservedEvents = 100,
    this.toolRegistry,
    this.onServerRequest,
    this.onSampling,
    this.maxSamplingPerMinute = 10,
    this.maxConcurrentRequests = 10,
    this.requestTimeout = const Duration(seconds: 30),
  });

  final ToolRegistry? toolRegistry;
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
    String requestId,
  )? onServerRequest;
  final Future<Map<String, dynamic>?> Function(
    Map<String, dynamic> params,
    String requestId,
  )? onSampling;
  final int maxSamplingPerMinute;
  final int maxConcurrentRequests;
  final Duration requestTimeout;

  late final McpServerRequestHandler _serverHandler;

  @override
  Future<void> start() async {
    await super.start();

    // Initialize server request handler if we have a tool registry
    if (toolRegistry != null) {
      _serverHandler = McpServerRequestHandler(
        client: this,
        toolRegistry: toolRegistry!,
        onServerRequest: onServerRequest,
        onSampling: onSampling,
        maxSamplingPerMinute: maxSamplingPerMinute,
        maxConcurrentRequests: maxConcurrentRequests,
        requestTimeout: requestTimeout,
      );
      await _serverHandler.start();
    }
  }

  @override
  Future<void> close() async {
    if (toolRegistry != null) {
      await _serverHandler.stop();
    }
    await super.close();
  }

  /// Gets the server request handler (if initialized).
  McpServerRequestHandler? get serverHandler => 
      toolRegistry != null ? _serverHandler : null;
}
