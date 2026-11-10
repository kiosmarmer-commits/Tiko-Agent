import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:math';

/// API Server configuration
class ApiServerConfig {
  const ApiServerConfig({
    this.enabled = false,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.basePath = '/api/v1',
    this.authToken,
    this.corsOrigins = const ['*'],
    this.maxRequestSize = 1024 * 1024 * 10, // 10MB
    this.timeoutSeconds = 300,
    this.enableSwagger = true,
    this.sslEnabled = false,
    this.sslCertPath,
    this.sslKeyPath,
  });

  final bool enabled;
  final String host;
  final int port;
  final String basePath;
  final String? authToken;
  final List<String> corsOrigins;
  final int maxRequestSize;
  final int timeoutSeconds;
  final bool enableSwagger;
  final bool sslEnabled;
  final String? sslCertPath;
  final String? sslKeyPath;

  String get url => sslEnabled ? 'https://$host:$port$basePath' : 'http://$host:$port$basePath';

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'port': port,
        'basePath': basePath,
        'authToken': authToken != null ? '***' : null,
        'corsOrigins': corsOrigins,
        'maxRequestSize': maxRequestSize,
        'timeoutSeconds': timeoutSeconds,
        'enableSwagger': enableSwagger,
        'sslEnabled': sslEnabled,
        'url': url,
      };
}

/// API Server status
enum ApiServerStatus {
  stopped('stopped'),
  starting('starting'),
  running('running'),
  stopping('stopping'),
  error('error');

  const ApiServerStatus(this.value);
  final String value;
}

/// Request method
enum ApiMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  delete('DELETE'),
  patch('PATCH'),
  head('HEAD'),
  options('OPTIONS');

  const ApiMethod(this.value);
  final String value;
  
  static ApiMethod fromValue(String value) {
    return values.firstWhere(
      (m) => m.value.toLowerCase() == value.toLowerCase(),
      orElse: () => get,
    );
  }
}

/// API Route definition
class ApiRoute {
  const ApiRoute({
    required this.path,
    required this.method,
    required this.handler,
    this.middleware = const [],
    this.authRequired = false,
    this.description = '',
    this.parameters = const [],
    this.responseSchema,
  });

  final String path;
  final ApiMethod method;
  final Future<ApiResponse> Function(ApiRequest) handler;
  final List<Middleware> middleware;
  final bool authRequired;
  final String description;
  final List<ApiParameter> parameters;
  final Map<String, dynamic>? responseSchema;

  String get fullPath => path;

  Map<String, dynamic> toOpenApiJson(String basePath) {
    return {
      '${method.value.toLowerCase()}': {
        'summary': description.isNotEmpty ? description : path,
        'description': description,
        'parameters': parameters.map((p) => p.toOpenApiJson()).toList(),
        'responses': {
          '200': {
            'description': 'Success',
            'content': {
              'application/json': {
                'schema': responseSchema ?? {'type': 'object'},
              },
            },
          },
        },
        if (authRequired)
          'security': [{'bearerAuth': []}],
      },
    };
  }
}

/// API Parameter definition
class ApiParameter {
  const ApiParameter({
    required this.name,
    required this.type,
    required this.location,
    this.required = false,
    this.description = '',
    this.defaultValue,
  });

  final String name;
  final String type; // 'string', 'integer', 'boolean', etc.
  final String location; // 'query', 'path', 'header', 'body'
  final bool required;
  final String description;
  final dynamic defaultValue;

  Map<String, dynamic> toOpenApiJson() {
    return {
      'name': name,
      'in': location,
      'type': type,
      'required': required,
      'description': description,
      if (defaultValue != null) 'default': defaultValue,
    };
  }
}

/// Middleware function type
typedef Middleware = Future<bool> Function(ApiRequest request, ApiResponse response);

/// API Request
class ApiRequest {
  ApiRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.queryParameters,
    required this.body,
    required this.rawBody,
    this.parameters = const {},
    this.clientIp,
    this.sessionId,
  });

  final ApiMethod method;
  final String path;
  final Map<String, String> headers;
  final Map<String, String> queryParameters;
  final Map<String, dynamic> body;
  final String rawBody;
  final Map<String, String> parameters;
  final String? clientIp;
  final String? sessionId;

  /// Get header value
  String? getHeader(String name) => headers[name.toLowerCase()];

  /// Check if request has authentication token
  bool get hasAuthToken => getHeader('authorization') != null;

  /// Get authentication token
  String? get authToken {
    final authHeader = getHeader('authorization');
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      return authHeader.substring(7);
    }
    return null;
  }

  /// Check if content type is JSON
  bool get isJson => 
      getHeader('content-type')?.toLowerCase().contains('application/json') ?? false;

  Map<String, dynamic> toJson() => {
        'method': method.value,
        'path': path,
        'headers': headers,
        'queryParameters': queryParameters,
        'body': body,
        'parameters': parameters,
        'clientIp': clientIp,
        'sessionId': sessionId,
      };
}

/// API Response
class ApiResponse {
  ApiResponse({
    this.statusCode = 200,
    this.body = const {},
    this.headers = const {},
    this.cookies = const [],
  });

  final int statusCode;
  final dynamic body;
  final Map<String, String> headers;
  final List<HttpCookie> cookies;

  /// Check if response is successful
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Check if response is error
  bool get isError => statusCode >= 400;

  /// Convert to HTTP response
  http.Response toHttpResponse() {
    final bodyString = body is String ? body : jsonEncode(body);
    final responseHeaders = <String, String>{};
    responseHeaders.addAll(headers);
    responseHeaders['content-type'] = 'application/json';
    
    return http.Response(bodyString, statusCode, headers: responseHeaders);
  }

  /// Create a JSON response
  static ApiResponse json({
    required dynamic data,
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) {
    return ApiResponse(
      statusCode: statusCode,
      body: data,
      headers: headers,
    );
  }

  /// Create an error response
  static ApiResponse error({
    required String message,
    int statusCode = 400,
    dynamic errorDetails,
  }) {
    return ApiResponse(
      statusCode: statusCode,
      body: {
        'error': true,
        'message': message,
        if (errorDetails != null) 'details': errorDetails,
      },
    );
  }

  /// Create a success response
  static ApiResponse success({
    required dynamic data,
    int statusCode = 200,
    String message = 'Success',
  }) {
    return ApiResponse(
      statusCode: statusCode,
      body: {
        'success': true,
        'message': message,
        'data': data,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'statusCode': statusCode,
        'body': body,
        'headers': headers,
      };
}

/// API Server for Tiko-Agent
class ApiServer {
  ApiServer({
    this.config = const ApiServerConfig(),
    this.agentLoop,
    this.routes = const [],
    this.middleware = const [],
    this.onStart,
    this.onStop,
    this.onError,
  });

  final ApiServerConfig config;
  final AgentLoop? agentLoop;
  final List<ApiRoute> routes;
  final List<Middleware> middleware;
  final Future<void> Function(ApiServer)? onStart;
  final Future<void> Function(ApiServer)? onStop;
  final Future<void> Function(ApiServer, dynamic)? onError;

  ApiServerStatus _status = ApiServerStatus.stopped;
  HttpServer? _server;
  int? _port;

  ApiServerStatus get status => _status;
  int? get port => _port;
  String? get url => _server != null ? 'http://${_server!.address.host}:${_server!.port}' : null;

  /// Start the API server
  Future<void> start() async {
    if (_status != ApiServerStatus.stopped) {
      throw Exception('Server is already running or in transition');
    }

    _status = ApiServerStatus.starting;

    try {
      // Create HTTP server
      _server = await HttpServer.bind(
        config.host,
        config.port,
        shared: true,
      );

      _port = _server!.port;
      _status = ApiServerStatus.running;

      // Setup request handling
      await for (final request in _server!) {
        try {
          await _handleRequest(request);
        } catch (e) {
          // Log error but don't crash
          if (onError != null) {
            await onError!(this, e);
          }
          // Return 500 error
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write(jsonEncode({
              'error': true,
              'message': 'Internal server error',
            }))
            ..close();
        }
      }

      // Call onStart callback
      if (onStart != null) {
        await onStart!(this);
      }
    } catch (e) {
      _status = ApiServerStatus.error;
      rethrow;
    }
  }

  /// Stop the API server
  Future<void> stop() async {
    if (_status == ApiServerStatus.stopped) {
      return;
    }

    _status = ApiServerStatus.stopping;

    try {
      await _server?.close();
      _server = null;
      _port = null;
      _status = ApiServerStatus.stopped;

      // Call onStop callback
      if (onStop != null) {
        await onStop!(this);
      }
    } catch (e) {
      _status = ApiServerStatus.error;
      rethrow;
    }
  }

  /// Restart the API server
  Future<void> restart() async {
    await stop();
    await start();
  }

  /// Handle incoming HTTP request
  Future<void> _handleRequest(HttpRequest request) async {
    // Parse request
    final apiRequest = await _parseRequest(request);

    // Apply middleware
    for (final mw in [...middleware, ..._getRouteMiddleware(apiRequest.path, apiRequest.method)]) {
      final response = ApiResponse();
      final shouldContinue = await mw(apiRequest, response);
      if (!shouldContinue) {
        await _sendResponse(request, response);
        return;
      }
    }

    // Check authentication
    if (_requiresAuth(apiRequest.path, apiRequest.method) && 
        !_validateAuth(apiRequest)) {
      await _sendResponse(request, ApiResponse.error(
        message: 'Unauthorized',
        statusCode: HttpStatus.unauthorized,
      ));
      return;
    }

    // Find and execute route handler
    final route = _findRoute(apiRequest.path, apiRequest.method);
    if (route != null) {
      try {
        final response = await route.handler(apiRequest);
        await _sendResponse(request, response);
      } catch (e) {
        await _sendResponse(request, ApiResponse.error(
          message: e.toString(),
          statusCode: HttpStatus.internalServerError,
        ));
      }
    } else {
      // Handle 404
      await _sendResponse(request, ApiResponse.error(
        message: 'Not found',
        statusCode: HttpStatus.notFound,
      ));
    }
  }

  /// Parse HTTP request to ApiRequest
  Future<ApiRequest> _parseRequest(HttpRequest request) async {
    final method = ApiMethod.fromValue(request.method);
    final path = request.uri.path;
    final queryParameters = request.uri.queryParameters;
    
    // Read body
    String rawBody = '';
    Map<String, dynamic> body = {};
    
    if (request.contentLength > 0) {
      rawBody = await request.transform(utf8.decoder).join();
      
      if (request.headers.contentType?.mimeType == 'application/json') {
        try {
          body = jsonDecode(rawBody) as Map<String, dynamic>;
        } catch (_) {
          // Invalid JSON, keep raw body
        }
      }
    }

    // Parse headers
    final headers = <String, String>{};
    for (final entry in request.headers.entries) {
      headers[entry.key.toLowerCase()] = entry.value.join(', ');
    }

    return ApiRequest(
      method: method,
      path: path,
      headers: headers,
      queryParameters: queryParameters,
      body: body,
      rawBody: rawBody,
      clientIp: request.connectionInfo?.remoteAddress.address,
    );
  }

  /// Send API response
  Future<void> _sendResponse(HttpRequest request, ApiResponse response) async {
    request.response
      ..statusCode = response.statusCode
      ..headers.contentType = ContentType.json;

    // Add custom headers
    for (final entry in response.headers.entries) {
      request.response.headers.set(entry.key, entry.value);
    }

    // Add cookies
    for (final cookie in response.cookies) {
      request.response.cookies.add(cookie);
    }

    // Write body
    if (response.body != null) {
      if (response.body is String) {
        request.response.write(response.body as String);
      } else {
        request.response.write(jsonEncode(response.body));
      }
    }

    await request.response.close();
  }

  /// Find route for path and method
  ApiRoute? _findRoute(String path, ApiMethod method) {
    // Normalize path
    final normalizedPath = path.replaceAll(RegExp(r'\/$'), '');
    
    for (final route in routes) {
      // Simple path matching (could be enhanced with regex)
      if (route.method == method) {
        if (route.path == normalizedPath) {
          return route;
        }
        
        // Check if route path matches with parameters
        if (_matchPathWithParams(route.path, normalizedPath)) {
          return route;
        }
      }
    }
    
    return null;
  }

  /// Check if path matches route path with parameters
  bool _matchPathWithParams(String routePath, String requestPath) {
    final routeParts = routePath.split('/');
    final requestParts = requestPath.split('/');
    
    if (routeParts.length != requestParts.length) {
      return false;
    }
    
    for (var i = 0; i < routeParts.length; i++) {
      if (routeParts[i].startsWith(':')) {
        continue; // Parameter, matches anything
      }
      if (routeParts[i] != requestParts[i]) {
        return false;
      }
    }
    
    return true;
  }

  /// Get middleware for specific route
  List<Middleware> _getRouteMiddleware(String path, ApiMethod method) {
    final route = _findRoute(path, method);
    return route?.middleware ?? [];
  }

  /// Check if route requires authentication
  bool _requiresAuth(String path, ApiMethod method) {
    final route = _findRoute(path, method);
    return route?.authRequired ?? false;
  }

  /// Validate authentication token
  bool _validateAuth(ApiRequest request) {
    if (config.authToken == null || config.authToken!.isEmpty) {
      return true; // No auth configured
    }
    
    final token = request.authToken;
    return token == config.authToken;
  }

  /// Generate OpenAPI/Swagger specification
  Map<String, dynamic> generateOpenApiSpec() {
    return {
      'openapi': '3.0.0',
      'info': {
        'title': 'Tiko-Agent API',
        'version': '1.0.0',
        'description': 'API Server for Tiko-Agent',
      },
      'servers': [
        {
          'url': config.url,
          'description': 'Local server',
        },
      ],
      'paths': _generatePathsSpec(),
      if (config.authToken != null)
        'components': {
          'securitySchemes': {
            'bearerAuth': {
              'type': 'http',
              'scheme': 'bearer',
              'bearerFormat': 'JWT',
            },
          },
        },
    };
  }

  /// Generate paths specification for OpenAPI
  Map<String, dynamic> _generatePathsSpec() {
    final paths = <String, dynamic>{};
    
    for (final route in routes) {
      final pathKey = route.path;
      if (!paths.containsKey(pathKey)) {
        paths[pathKey] = {};
      }
      
      paths[pathKey][route.method.value.toLowerCase()] = {
        'summary': route.description.isNotEmpty ? route.description : route.path,
        'responses': {
          '200': {
            'description': 'Success',
            'content': {
              'application/json': {
                'schema': route.responseSchema ?? {'type': 'object'},
              },
            },
          },
        },
        if (route.authRequired)
          'security': [{'bearerAuth': []}],
      };
    }
    
    return paths;
  }

  /// Get server information
  Map<String, dynamic> getInfo() => {
        'status': _status.value,
        'port': _port,
        'url': url,
        'config': config.toJson(),
        'routes': routes.map((r) => {
          'path': r.path,
          'method': r.method.value,
          'authRequired': r.authRequired,
        }).toList(),
      };
}

/// API Server Tool for Tiko-Agent
class ApiServerTool implements Tool {
  ApiServerTool({
    this.server,
    this.config = const ApiServerConfig(),
    this.agentLoop,
    this.workingDirectory,
  }) : _server = server ?? ApiServer(
          config: config,
          agentLoop: agentLoop,
        );

  final ApiServer? server;
  final ApiServerConfig config;
  final AgentLoop? agentLoop;
  final String? workingDirectory;
  late final ApiServer _server;

  @override
  String get name => 'api_server';

  @override
  String get description =>
      'Manage the API server for Tiko-Agent. Start, stop, and configure '
      'the HTTP endpoint for programmatic access to the agent.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['start', 'stop', 'restart', 'status', 'configure'],
              'description': 'The action to perform',
            },
            'host': {
              'type': 'string',
              'description': 'Host to bind to',
              'default': '127.0.0.1',
            },
            'port': {
              'type': 'integer',
              'description': 'Port to listen on',
              'default': 8080,
              'minimum': 1,
              'maximum': 65535,
            },
            'basePath': {
              'type': 'string',
              'description': 'Base path for API endpoints',
              'default': '/api/v1',
            },
            'authToken': {
              'type': 'string',
              'description': 'Authentication token for protected endpoints',
            },
            'enableSwagger': {
              'type': 'boolean',
              'description': 'Enable Swagger/OpenAPI documentation',
              'default': true,
            },
            'timeout': {
              'type': 'integer',
              'description': 'Request timeout in seconds',
              'default': 300,
            },
          },
          'required': ['action'],
        },
        outputSchema: {
          'type': 'object',
          'properties': {
            'success': {'type': 'boolean'},
            'action': {'type': 'string'},
            'status': {'type': 'string'},
            'port': {'type': 'integer'},
            'url': {'type': 'string'},
            'config': {'type': 'object'},
            'error': {'type': 'string'},
          },
        },
        risk: 'high',
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String? ?? 'status';

      switch (action) {
        case 'start':
          return await _handleStart(args);
        case 'stop':
          return await _handleStop(args);
        case 'restart':
          return await _handleRestart(args);
        case 'status':
          return await _handleStatus(args);
        case 'configure':
          return await _handleConfigure(args);
        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'success': false,
              'error': 'Unknown action: $action',
            }),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        isError: true,
      );
    }
  }

  Future<ToolResult> _handleStart(Map<String, dynamic> args) async {
    // Update config if provided
    final config = _updateConfigFromArgs(args);
    
    if (_server.status != ApiServerStatus.stopped) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'Server is already running',
          'currentStatus': _server.status.value,
        }),
        isError: true,
      );
    }

    await _server.start();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'start',
        'status': _server.status.value,
        'port': _server.port,
        'url': _server.url,
      }),
    );
  }

  Future<ToolResult> _handleStop(Map<String, dynamic> args) async {
    if (_server.status == ApiServerStatus.stopped) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'Server is already stopped',
        }),
        isError: true,
      );
    }

    await _server.stop();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'stop',
        'status': _server.status.value,
      }),
    );
  }

  Future<ToolResult> _handleRestart(Map<String, dynamic> args) async {
    // Update config if provided
    final config = _updateConfigFromArgs(args);
    
    await _server.restart();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'restart',
        'status': _server.status.value,
        'port': _server.port,
        'url': _server.url,
      }),
    );
  }

  Future<ToolResult> _handleStatus(Map<String, dynamic> args) async {
    final info = _server.getInfo();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'status',
        ...info,
      }),
    );
  }

  Future<ToolResult> _handleConfigure(Map<String, dynamic> args) async {
    final config = _updateConfigFromArgs(args);

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'configure',
        'config': config.toJson(),
        'message': 'Configuration updated. Restart server for changes to take effect.',
      }),
    );
  }

  /// Update server config from tool arguments
  ApiServerConfig _updateConfigFromArgs(Map<String, dynamic> args) {
    return ApiServerConfig(
      enabled: true,
      host: args['host'] as String? ?? _server.config.host,
      port: args['port'] as int? ?? _server.config.port,
      basePath: args['basePath'] as String? ?? _server.config.basePath,
      authToken: args['authToken'] as String? ?? _server.config.authToken,
      enableSwagger: args['enableSwagger'] as bool? ?? _server.config.enableSwagger,
      timeoutSeconds: args['timeout'] as int? ?? _server.config.timeoutSeconds,
    );
  }
}

/// Factory for creating API server tools
class ApiServerToolFactory {
  static ApiServerTool create({
    ApiServer? server,
    ApiServerConfig? config,
    AgentLoop? agentLoop,
    String? workingDirectory,
  }) {
    return ApiServerTool(
      server: server,
      config: config ?? const ApiServerConfig(),
      agentLoop: agentLoop,
      workingDirectory: workingDirectory,
    );
  }
}

/// Exception for API server errors
class ApiServerException implements Exception {
  const ApiServerException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => 'ApiServerException: $message${code != null ? ' ($code)' : ''}';
}
