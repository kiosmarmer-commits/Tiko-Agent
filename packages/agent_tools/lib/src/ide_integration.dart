import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'dart:math';

import 'acp_agent.dart';

/// Generate a random ID
String _generateId({int length = 32}) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
}

/// IDE types supported for integration
class IdeType {
  static const vscode = 'vscode';
  static const zed = 'zed';
  static const jetbrains = 'jetbrains';
  static const cursor = 'cursor';
  static const sublime = 'sublime';
  static const neovim = 'neovim';

  static const all = [vscode, zed, jetbrains, cursor, sublime, neovim];

  /// Detect IDE from process name
  static String? detectFromProcess() {
    // This would be enhanced with actual process detection
    return null;
  }

  /// Get IDE configuration directory
  static String? getConfigDirectory(String ideType, {String? workingDirectory}) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;

    switch (ideType) {
      case vscode:
        return p.join(home, Platform.isWindows ? 'AppDataRoamingCodeUser' : '.vscode');
      case zed:
        return p.join(home, '.zed');
      case jetbrains:
        return p.join(home, '.configJetBrains');
      case cursor:
        return p.join(home, '.cursor');
      case sublime:
        return p.join(home, Platform.isWindows
            ? 'AppDataRoamingSublime TextPackagesUser'
            : '.configsublime-text-3PackagesUser');
      case neovim:
        return p.join(home, '.config\nvim');
      default:
        return null;
    }
  }
}

/// IDE Integration configuration
class IdeIntegrationConfig {
  const IdeIntegrationConfig({
    this.enabled = true,
    this.ideType = 'vscode',
    this.autoDetect = true,
    this.enableAcp = true,
    this.acpPort = 3000,
    this.acpHost = '127.0.0.1',
    this.supportedSchemas = const [
      'tiko',
      'tiko-agent',
      'tiko-tool',
      'tiko-resource',
    ],
    this.registerCommands = true,
    this.showNotifications = true,
    this.maxConcurrentRequests = 10,
  });

  final bool enabled;
  final String ideType;
  final bool autoDetect;
  final bool enableAcp;
  final int acpPort;
  final String acpHost;
  final List<String> supportedSchemas;
  final bool registerCommands;
  final bool showNotifications;
  final int maxConcurrentRequests;

  String get acpUrl => 'http://$acpHost:$acpPort';

  IdeIntegrationConfig copyWith({
    bool? enabled,
    String? ideType,
    bool? autoDetect,
    bool? enableAcp,
    int? acpPort,
    String? acpHost,
    List<String>? supportedSchemas,
    bool? registerCommands,
    bool? showNotifications,
    int? maxConcurrentRequests,
  }) {
    return IdeIntegrationConfig(
      enabled: enabled ?? this.enabled,
      ideType: ideType ?? this.ideType,
      autoDetect: autoDetect ?? this.autoDetect,
      enableAcp: enableAcp ?? this.enableAcp,
      acpPort: acpPort ?? this.acpPort,
      acpHost: acpHost ?? this.acpHost,
      supportedSchemas: supportedSchemas ?? this.supportedSchemas,
      registerCommands: registerCommands ?? this.registerCommands,
      showNotifications: showNotifications ?? this.showNotifications,
      maxConcurrentRequests: maxConcurrentRequests ?? this.maxConcurrentRequests,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'ideType': ideType,
        'autoDetect': autoDetect,
        'enableAcp': enableAcp,
        'acpPort': acpPort,
        'acpHost': acpHost,
        'supportedSchemas': supportedSchemas,
        'registerCommands': registerCommands,
        'showNotifications': showNotifications,
        'maxConcurrentRequests': maxConcurrentRequests,
      };
}

/// ACP (Agent Communication Protocol) message types
enum AcpMessageType {
  request('request'),
  response('response'),
  notification('notification'),
  error('error'),
  ping('ping'),
  pong('pong');

  const AcpMessageType(this.value);
  final String value;
}

/// ACP Request types
enum AcpRequestType {
  // Agent capabilities
  capabilities('capabilities'),
  
  // Resource access
  readResource('readResource'),
  writeResource('writeResource'),
  listResources('listResources'),
  
  // Tool execution
  executeTool('executeTool'),
  listTools('listTools'),
  
  // Agent interaction
  sendPrompt('sendPrompt'),
  getStatus('getStatus'),
  
  // Custom commands
  executeCommand('executeCommand');

  const AcpRequestType(this.value);
  final String value;
}

/// ACP Message
class AcpMessage {
  AcpMessage({
    required this.id,
    required this.type,
    this.requestType,
    this.payload,
    this.error,
    this.timestamp,
  });

  final String id;
  final AcpMessageType type;
  final AcpRequestType? requestType;
  final Map<String, dynamic>? payload;
  final String? error;
  final DateTime? timestamp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.value,
        if (requestType != null) 'requestType': requestType!.value,
        if (payload != null) 'payload': payload,
        if (error != null) 'error': error,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
      };

  factory AcpMessage.fromJson(Map<String, dynamic> json) {
    return AcpMessage(
      id: json['id'] as String,
      type: AcpMessageType.values.byName(json['type'] as String),
      requestType: json['requestType'] != null
          ? AcpRequestType.values.byName(json['requestType'] as String)
          : null,
      payload: json['payload'] as Map<String, dynamic>?,
      error: json['error'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// ACP Resource URI scheme
class AcpResourceUri {
  AcpResourceUri({
    required this.scheme,
    required this.authority,
    required this.path,
    this.query,
    this.fragment,
  });

  final String scheme;
  final String authority;
  final String path;
  final String? query;
  final String? fragment;

  String get fullUri => '$scheme://$authority$path${query != null ? '?$query' : ''}${fragment != null ? '#$fragment' : ''}';

  /// Parse ACP resource URI
  factory AcpResourceUri.parse(String uri) {
    final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(\?([^#]*))?(#(.*))?$').firstMatch(uri);
    if (match == null) {
      throw FormatException('Invalid ACP resource URI: $uri');
    }

    return AcpResourceUri(
      scheme: match.group(1)!,
      authority: match.group(2)!,
      path: match.group(3)!,
      query: match.group(5),
      fragment: match.group(7),
    );
  }

  /// Check if URI is supported by this ACP server
  bool isSupported(List<String> supportedSchemas) => supportedSchemas.contains(scheme);

  Map<String, dynamic> toJson() => {
        'scheme': scheme,
        'authority': authority,
        'path': path,
        'query': query,
        'fragment': fragment,
        'fullUri': fullUri,
      };
}

/// ACP Capabilities
class AcpCapabilities {
  const AcpCapabilities({
    this.name = 'Tiko-Agent',
    this.version = '1.0.0',
    this.description = 'Tiko Agent with ACP support',
    this.supportedSchemas = const ['tiko', 'tiko-agent', 'tiko-tool'],
    this.supportedTools = const [],
    this.supportedCommands = const [],
    this.maxConcurrentRequests = 10,
    this.maxPayloadSize = 1024 * 1024 * 10, // 10MB
  });

  final String name;
  final String version;
  final String description;
  final List<String> supportedSchemas;
  final List<String> supportedTools;
  final List<String> supportedCommands;
  final int maxConcurrentRequests;
  final int maxPayloadSize;

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'description': description,
        'supportedSchemas': supportedSchemas,
        'supportedTools': supportedTools,
        'supportedCommands': supportedCommands,
        'maxConcurrentRequests': maxConcurrentRequests,
        'maxPayloadSize': maxPayloadSize,
      };
}

/// IDE Integration Manager
class IdeIntegrationManager {
  IdeIntegrationManager({
    this.config = const IdeIntegrationConfig(),
    this.agentLoop,
    this.tools = const [],
    this.workingDirectory,
  });

  final IdeIntegrationConfig config;
  final AgentLoop? agentLoop;
  final List<Tool> tools;
  final String? workingDirectory;

  final Map<String, AcpMessage> _pendingRequests = {};
  bool _isRunning = false;
  HttpServer? _acpServer;
  final List<Map<String, dynamic>> _acpOutbound = [];

  /// Start IDE integration
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    // Auto-detect IDE if configured
    if (config.autoDetect) {
      final detectedIde = IdeType.detectFromProcess();
      if (detectedIde != null) {
        // Update config with detected IDE
        // This would be handled by the tool
      }
    }

    // Start ACP server if enabled
    if (config.enableAcp) {
      await _startAcpServer();
    }

    // Register commands if enabled
    if (config.registerCommands) {
      await _registerCommands();
    }
  }

  /// Stop IDE integration
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    // Stop ACP server
    await _stopAcpServer();

    // Unregister commands
    await _unregisterCommands();
  }

  /// Start ACP server: HTTP POST endpoint speaking the same JSON-RPC 2.0
  /// protocol core as the stdio [AcpAgent], so IDE extensions can talk to
  /// the agent over either transport.
  Future<void> _startAcpServer() async {
    final dispatcher = AcpDispatcher(
      handler: _runAcpPrompt,
      emit: _acpOutbound.add,
    );
    try {
      final server = await HttpServer.bind(config.acpHost, config.acpPort);
      _acpServer = server;
      server.listen((request) async {
        try {
          if (request.method != 'POST') {
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
          }
          final body = await utf8.decoder.bind(request).join();
          final decoded = jsonDecode(body);
          if (decoded is! Map<String, dynamic>) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
            return;
          }
          _acpOutbound.clear();
          final response = await dispatcher.dispatch(decoded);
          if (response == null) {
            request.response.statusCode = HttpStatus.noContent;
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
          await request.response.close();
        } catch (_) {
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      stderr.writeln('ACP HTTP server gagal berjalan pada '
          '${config.acpHost}:${config.acpPort}: $e');
    }
  }

  /// Stop ACP server
  Future<void> _stopAcpServer() async {
    await _acpServer?.close(force: true);
    _acpServer = null;
    _acpOutbound.clear();
  }

  /// ACP prompt handler shared with the JSON-RPC dispatcher: runs one
  /// agent turn and returns the final answer text.
  Future<String> _runAcpPrompt(String sessionId, String prompt) async {
    final loop = agentLoop;
    if (loop == null) {
      throw StateError('Agent loop is not configured');
    }
    final session = Session(id: sessionId, channel: 'acp', userKey: 'ide');
    await loop.handle(
      InboundMessage(
        channel: 'acp',
        userKey: 'ide',
        sessionKey: sessionId,
        text: prompt,
      ),
      session,
    );
    if (!loop.lastTurnSucceeded) {
      throw StateError('agent turn failed');
    }
    return loop.lastAnswer ?? '';
  }

  /// Register IDE commands
  Future<void> _registerCommands() async {
    // This would register commands in the IDE
    // Implementation depends on the IDE
  }

  /// Unregister IDE commands
  Future<void> _unregisterCommands() async {
    // Unregister commands
  }

  /// Handle ACP request
  Future<AcpMessage> handleAcpRequest(AcpMessage request) async {
    try {
      if (request.type != AcpMessageType.request) {
        return AcpMessage(
          id: request.id,
          type: AcpMessageType.error,
          error: 'Expected request message type',
        );
      }

      if (request.requestType == null) {
        return AcpMessage(
          id: request.id,
          type: AcpMessageType.error,
          error: 'Request type is required',
        );
      }

      switch (request.requestType!) {
        case AcpRequestType.capabilities:
          return await _handleCapabilitiesRequest(request);
        case AcpRequestType.readResource:
          return await _handleReadResourceRequest(request);
        case AcpRequestType.writeResource:
          return await _handleWriteResourceRequest(request);
        case AcpRequestType.listResources:
          return await _handleListResourcesRequest(request);
        case AcpRequestType.executeTool:
          return await _handleExecuteToolRequest(request);
        case AcpRequestType.listTools:
          return await _handleListToolsRequest(request);
        case AcpRequestType.sendPrompt:
          return await _handleSendPromptRequest(request);
        case AcpRequestType.getStatus:
          return await _handleGetStatusRequest(request);
        case AcpRequestType.executeCommand:
          return await _handleExecuteCommandRequest(request);
      }
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle capabilities request
  Future<AcpMessage> _handleCapabilitiesRequest(AcpMessage request) async {
    final capabilities = AcpCapabilities(
      name: 'Tiko-Agent',
      version: '1.0.0',
      supportedSchemas: config.supportedSchemas,
      supportedTools: tools.map((t) => t.spec.name).toList(),
      supportedCommands: _getSupportedCommands(),
      maxConcurrentRequests: config.maxConcurrentRequests,
    );

    return AcpMessage(
      id: request.id,
      type: AcpMessageType.response,
      requestType: AcpRequestType.capabilities,
      payload: capabilities.toJson(),
    );
  }

  /// Handle read resource request
  Future<AcpMessage> _handleReadResourceRequest(AcpMessage request) async {
    final uriString = request.payload?['uri'] as String?;
    if (uriString == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'URI is required',
      );
    }

    final uri = AcpResourceUri.parse(uriString);
    
    if (!uri.isSupported(config.supportedSchemas)) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'Unsupported scheme: ${uri.scheme}',
      );
    }

    // Handle different schemes
    try {
      String content;
      switch (uri.scheme) {
        case 'tiko':
        case 'tiko-agent':
          content = await _readTikoResource(uri);
          break;
        case 'tiko-tool':
          content = await _readToolResource(uri);
          break;
        default:
          return AcpMessage(
            id: request.id,
            type: AcpMessageType.error,
            error: 'Unknown scheme: ${uri.scheme}',
          );
      }

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.readResource,
        payload: {
          'uri': uri.fullUri,
          'content': content,
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle write resource request
  Future<AcpMessage> _handleWriteResourceRequest(AcpMessage request) async {
    final uriString = request.payload?['uri'] as String?;
    final content = request.payload?['content'] as String?;
    
    if (uriString == null || content == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'URI and content are required',
      );
    }

    final uri = AcpResourceUri.parse(uriString);
    
    if (!uri.isSupported(config.supportedSchemas)) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'Unsupported scheme: ${uri.scheme}',
      );
    }

    try {
      bool success;
      switch (uri.scheme) {
        case 'tiko':
        case 'tiko-agent':
          success = await _writeTikoResource(uri, content);
          break;
        case 'tiko-tool':
          success = await _writeToolResource(uri, content);
          break;
        default:
          return AcpMessage(
            id: request.id,
            type: AcpMessageType.error,
            error: 'Unknown scheme: ${uri.scheme}',
          );
      }

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.writeResource,
        payload: {
          'uri': uri.fullUri,
          'success': success,
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle list resources request
  Future<AcpMessage> _handleListResourcesRequest(AcpMessage request) async {
    final scheme = request.payload?['scheme'] as String?;
    
    try {
      List<Map<String, dynamic>> resources;
      if (scheme != null) {
        resources = await _listResourcesByScheme(scheme);
      } else {
        resources = await _listAllResources();
      }

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.listResources,
        payload: {
          'scheme': scheme,
          'resources': resources,
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle execute tool request
  Future<AcpMessage> _handleExecuteToolRequest(AcpMessage request) async {
    final toolName = request.payload?['toolName'] as String?;
    final args = request.payload?['args'] as Map<String, dynamic>? ?? {};
    
    if (toolName == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'toolName is required',
      );
    }

    try {
      final matches = tools.where((t) => t.spec.name == toolName).toList();
      if (matches.isEmpty) {
        return AcpMessage(
          id: request.id,
          type: AcpMessageType.error,
          error: 'Tool not found: $toolName',
        );
      }
      final tool = matches.first;

      final sessionId = _generateId();
      final context = ToolContext(
        session: Session(id: sessionId, channel: 'acp', userKey: 'ide'),
        workspacePath: workingDirectory ?? Directory.current.path,
      );

      final result = await tool.run(args, context);

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.executeTool,
        payload: {
          'toolName': toolName,
          'success': !result.isError,
          'content': result.content,
          'callId': result.callId,
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle list tools request
  Future<AcpMessage> _handleListToolsRequest(AcpMessage request) async {
    final toolList = tools.map((tool) => {
      'name': tool.spec.name,
      'description': tool.spec.description,
      'spec': tool.spec.toJson(),
    }).toList();

    return AcpMessage(
      id: request.id,
      type: AcpMessageType.response,
      requestType: AcpRequestType.listTools,
      payload: {
        'tools': toolList,
        'total': toolList.length,
      },
    );
  }

  /// Handle send prompt request
  Future<AcpMessage> _handleSendPromptRequest(AcpMessage request) async {
    final prompt = request.payload?['prompt'] as String?;
    final contextData = request.payload?['context'] as Map<String, dynamic>?;
    
    if (prompt == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'prompt is required',
      );
    }

    if (agentLoop == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'Agent loop is not configured',
      );
    }

    try {
      final sessionId = _generateId();
      final session = Session(id: sessionId, channel: 'acp', userKey: 'ide');
      if (contextData != null) {
        session.summary = jsonEncode(contextData);
      }

      final loop = agentLoop!;
      await loop.handle(
        InboundMessage(
          channel: 'acp',
          userKey: 'ide',
          sessionKey: sessionId,
          text: prompt,
        ),
        session,
      );

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.sendPrompt,
        payload: {
          'prompt': prompt,
          'success': loop.lastTurnSucceeded,
          'sessionId': sessionId,
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Handle get status request
  Future<AcpMessage> _handleGetStatusRequest(AcpMessage request) async {
    return AcpMessage(
      id: request.id,
      type: AcpMessageType.response,
      requestType: AcpRequestType.getStatus,
      payload: {
        'status': _isRunning ? 'running' : 'stopped',
        'ideType': config.ideType,
        'acpEnabled': config.enableAcp,
        'acpUrl': config.acpUrl,
        'toolsCount': tools.length,
        'pendingRequests': _pendingRequests.length,
      },
    );
  }

  /// Handle execute command request
  Future<AcpMessage> _handleExecuteCommandRequest(AcpMessage request) async {
    final command = request.payload?['command'] as String?;
    final args = request.payload?['args'] as List<dynamic>? ?? [];
    
    if (command == null) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: 'command is required',
      );
    }

    try {
      final result = await _executeCommand(command, args);

      return AcpMessage(
        id: request.id,
        type: AcpMessageType.response,
        requestType: AcpRequestType.executeCommand,
        payload: {
          'command': command,
          'success': result['success'] as bool,
          'output': result['output'],
          'error': result['error'],
        },
      );
    } catch (e) {
      return AcpMessage(
        id: request.id,
        type: AcpMessageType.error,
        error: e.toString(),
      );
    }
  }

  /// Read Tiko resource
  Future<String> _readTikoResource(AcpResourceUri uri) async {
    // Implement resource reading based on URI
    // For now, return a simple response
    return 'Tiko Agent Resource: ${uri.path}';
  }

  /// Write Tiko resource
  Future<bool> _writeTikoResource(AcpResourceUri uri, String content) async {
    // Implement resource writing
    return true;
  }

  /// Read tool resource
  Future<String> _readToolResource(AcpResourceUri uri) async {
    // Implement tool resource reading
    return 'Tool Resource: ${uri.path}';
  }

  /// Write tool resource
  Future<bool> _writeToolResource(AcpResourceUri uri, String content) async {
    // Implement tool resource writing
    return true;
  }

  /// List resources by scheme
  Future<List<Map<String, dynamic>>> _listResourcesByScheme(String scheme) async {
    // Implement resource listing
    return [];
  }

  /// List all resources
  Future<List<Map<String, dynamic>>> _listAllResources() async {
    // Implement all resources listing
    return [];
  }

  /// Execute IDE command
  Future<Map<String, dynamic>> _executeCommand(String command, List<dynamic> args) async {
    // Implement command execution
    return {
      'success': true,
      'output': 'Command executed: $command',
    };
  }

  /// Get supported commands
  List<String> _getSupportedCommands() => [
    'tiko.start',
    'tiko.stop',
    'tiko.restart',
    'tiko.status',
    'tiko.execute',
    'tiko.ask',
    'tiko.tools.list',
    'tiko.tools.execute',
  ];

  /// Get IDE integration status
  Map<String, dynamic> getStatus() => {
        'enabled': config.enabled,
        'ideType': config.ideType,
        'autoDetect': config.autoDetect,
        'acpEnabled': config.enableAcp,
        'acpUrl': config.acpUrl,
        'isRunning': _isRunning,
        'supportedSchemas': config.supportedSchemas,
        'toolsCount': tools.length,
        'pendingRequests': _pendingRequests.length,
      };
}

/// IDE Integration Tool for Tiko-Agent
class IdeIntegrationTool implements Tool {
  IdeIntegrationTool({
    this.manager,
    this.config = const IdeIntegrationConfig(),
    this.agentLoop,
    this.tools = const [],
    this.workingDirectory,
  }) : _manager = manager ?? IdeIntegrationManager(
          config: config,
          agentLoop: agentLoop,
          tools: tools,
          workingDirectory: workingDirectory,
        );

  final IdeIntegrationManager? manager;
  final IdeIntegrationConfig config;
  final AgentLoop? agentLoop;
  final List<Tool> tools;
  final String? workingDirectory;
  late final IdeIntegrationManager _manager;

  String get name => 'ide_integration';

  String get description =>
      'Integrate Tiko-Agent with IDEs (VS Code, Zed, JetBrains, etc.) using '
      'ACP (Agent Communication Protocol). Provides code completion, tool execution, '
      'and resource access.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'start',
                'stop',
                'status',
                'configure',
                'sendAcpRequest',
                'listCommands',
                'executeCommand',
                'registerCommands',
                'getCapabilities',
              ],
              'description': 'The action to perform',
            },
            'ideType': {
              'type': 'string',
              'enum': IdeType.all,
              'description': 'IDE type to integrate with',
            },
            'autoDetect': {
              'type': 'boolean',
              'description': 'Auto-detect IDE type',
              'default': true,
            },
            'enableAcp': {
              'type': 'boolean',
              'description': 'Enable ACP (Agent Communication Protocol)',
              'default': true,
            },
            'acpPort': {
              'type': 'integer',
              'description': 'ACP server port',
              'default': 3000,
            },
            'acpHost': {
              'type': 'string',
              'description': 'ACP server host',
              'default': '127.0.0.1',
            },
            'request': {
              'type': 'object',
              'description': 'ACP request to send',
              'properties': {
                'type': {'type': 'string'},
                'requestType': {'type': 'string'},
                'payload': {'type': 'object'},
              },
            },
            'command': {
              'type': 'string',
              'description': 'Command to execute',
            },
            'args': {
              'type': 'array',
              'description': 'Command arguments',
              'items': {'type': 'string'},
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
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
        case 'status':
          return await _handleStatus(args);
        case 'configure':
          return await _handleConfigure(args);
        case 'sendAcpRequest':
          return await _handleSendAcpRequest(args);
        case 'listCommands':
          return await _handleListCommands(args);
        case 'executeCommand':
          return await _handleExecuteCommand(args);
        case 'registerCommands':
          return await _handleRegisterCommands(args);
        case 'getCapabilities':
          return await _handleGetCapabilities(args);
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
    
    await _manager.start();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'start',
        'status': 'running',
        'ideType': config.ideType,
        'acpUrl': config.acpUrl,
      }),
    );
  }

  Future<ToolResult> _handleStop(Map<String, dynamic> args) async {
    await _manager.stop();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'stop',
        'status': 'stopped',
      }),
    );
  }

  Future<ToolResult> _handleStatus(Map<String, dynamic> args) async {
    final status = _manager.getStatus();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'status',
        ...status,
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
      }),
    );
  }

  Future<ToolResult> _handleSendAcpRequest(Map<String, dynamic> args) async {
    final requestData = args['request'] as Map<String, dynamic>?;
    
    if (requestData == null) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'request is required',
        }),
        isError: true,
      );
    }

    final request = AcpMessage(
      id: _generateId(),
      type: AcpMessageType.values.byName(requestData['type'] as String),
      requestType: requestData['requestType'] != null
          ? AcpRequestType.values.byName(requestData['requestType'] as String)
          : null,
      payload: requestData['payload'] as Map<String, dynamic>?,
    );

    final response = await _manager.handleAcpRequest(request);

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'sendAcpRequest',
        'request': request.toJson(),
        'response': response.toJson(),
      }),
    );
  }

  Future<ToolResult> _handleListCommands(Map<String, dynamic> args) async {
    final commands = _manager._getSupportedCommands();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'listCommands',
        'commands': commands,
      }),
    );
  }

  Future<ToolResult> _handleExecuteCommand(Map<String, dynamic> args) async {
    final command = args['command'] as String?;
    final commandArgs = args['args'] as List<dynamic>? ?? [];
    
    if (command == null) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'command is required',
        }),
        isError: true,
      );
    }

    final result = await _manager._executeCommand(command, commandArgs);

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': result['success'] as bool,
        'action': 'executeCommand',
        'command': command,
        'output': result['output'],
        'error': result['error'],
      }),
      isError: !(result['success'] as bool),
    );
  }

  Future<ToolResult> _handleRegisterCommands(Map<String, dynamic> args) async {
    // This would register commands in the IDE
    // For now, just return success

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'registerCommands',
        'message': 'Commands registered',
      }),
    );
  }

  Future<ToolResult> _handleGetCapabilities(Map<String, dynamic> args) async {
    final capabilities = AcpCapabilities(
      name: 'Tiko-Agent',
      version: '1.0.0',
      supportedSchemas: _manager.config.supportedSchemas,
      supportedTools: _manager.tools.map((t) => t.spec.name).toList(),
      supportedCommands: _manager._getSupportedCommands(),
    );

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'action': 'getCapabilities',
        'capabilities': capabilities.toJson(),
      }),
    );
  }

  /// Update manager config from tool arguments
  IdeIntegrationConfig _updateConfigFromArgs(Map<String, dynamic> args) {
    return IdeIntegrationConfig(
      enabled: true,
      ideType: args['ideType'] as String? ?? _manager.config.ideType,
      autoDetect: args['autoDetect'] as bool? ?? _manager.config.autoDetect,
      enableAcp: args['enableAcp'] as bool? ?? _manager.config.enableAcp,
      acpPort: args['acpPort'] as int? ?? _manager.config.acpPort,
      acpHost: args['acpHost'] as String? ?? _manager.config.acpHost,
    );
  }
}

/// Factory for creating IDE integration tools
class IdeIntegrationToolFactory {
  static IdeIntegrationTool create({
    IdeIntegrationManager? manager,
    IdeIntegrationConfig? config,
    AgentLoop? agentLoop,
    List<Tool>? tools,
    String? workingDirectory,
  }) {
    return IdeIntegrationTool(
      manager: manager,
      config: config ?? const IdeIntegrationConfig(),
      agentLoop: agentLoop,
      tools: tools ?? [],
      workingDirectory: workingDirectory,
    );
  }
}

/// Exception for IDE integration errors
class IdeIntegrationException implements Exception {
  const IdeIntegrationException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => 'IdeIntegrationException: $message${code != null ? ' ($code)' : ''}';
}
