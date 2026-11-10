import 'dart:io';

import 'package:path/path.dart' as p;

import '../registry.dart';
import '../sandbox.dart';
import 'http_client.dart';
import 'stdio_client.dart';

/// Loads only explicitly allowlisted MCP tools. No configuration means no
/// tools; an empty allowlist is never interpreted as allow-all.
///
/// Two transports are supported (DEC-06):
/// - `stdio`: local child process, sandboxed, private per-server workspace;
/// - `http`: remote Streamable HTTP endpoint (admin-configured URL + header
///   SecretRefs). Remote endpoints are administrator-declared, so the SSRF
/// guard is intentionally not applied here; the tool allowlist and risk
///   floor remain mandatory.
class McpToolLoader {
  McpToolLoader(this.registry, {required this.sandbox});

  final ToolRegistry registry;
  final SandboxRunner sandbox;
  final List<McpToolServer> _clients = [];
  final List<Map<String, dynamic>> _statuses = [];

  List<Map<String, dynamic>> get statuses => _statuses.map((status) => Map<String, dynamic>.unmodifiable(status)).toList();

  /// Config entry: id, type (stdio|http), command+args (stdio) or
  /// url+headers (http), allow (required non-empty), risk, enabled.
  /// Risk is at least medium because MCP crosses a process/trust boundary.
  Future<int> loadServers(List<Map<String, dynamic>> servers) async {
    var count = 0;
    final seenIds = <String>{};
    for (final cfg in servers.take(8)) {
      final id = cfg['id'];
      final type = cfg['type'] is String ? cfg['type'] as String : 'stdio';
      final rawAllow = cfg['allow'];
      final risk = cfg['risk'] ?? 'high';
      final enabled = cfg['enabled'] ?? true;

      if (enabled is! bool) {
        _statuses.add({'id': '$id', 'status': 'invalid', 'detail': 'enabled must be boolean'});
        continue;
      }
      if (!enabled) {
        _statuses.add({'id': '$id', 'status': 'disabled', 'detail': cfg['disabled_reason'] ?? 'disabled by configuration'});
        continue;
      }
      if (id is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(id) ||
          !seenIds.add(id)) {
        _statuses.add({'id': '$id', 'status': 'invalid', 'detail': 'server id invalid/duplicate'});
        continue;
      }
      if (rawAllow is! List || rawAllow.isEmpty || rawAllow.length > 128 ||
          rawAllow.any((v) => v is! String || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$').hasMatch(v))) {
        _statuses.add({'id': id, 'status': 'disabled', 'detail': 'explicit non-empty allowlist required'});
        continue;
      }
      if (risk is! String || !const {'medium', 'high', 'critical'}.contains(risk)) {
        _statuses.add({'id': id, 'status': 'invalid', 'detail': 'MCP risk must be medium/high/critical'});
        continue;
      }

      final allow = rawAllow.cast<String>().toSet();
      final McpToolServer? client = type == 'http'
          ? _httpClient(id, cfg)
          : await _stdioClient(id, cfg);
      if (client == null) continue;

      try {
        await client.start();
        final tools = await client.listTools();
        final selected = tools.where((tool) => allow.contains(tool.name)).toList();
        if (selected.isEmpty) {
          await client.close();
          _statuses.add({'id': id, 'status': 'empty', 'detail': 'no returned tool matched the allowlist'});
          continue;
        }
        if (client is StdioMcpClient) {
          client.allowedTools = selected.map((tool) => tool.name).toSet();
        }
        final proxies = selected.map((tool) => McpProxyTool(
          client: client,
          info: tool,
          serverId: id,
          risk: risk,
        )).toList();
        final proxyNames = proxies.map((tool) => tool.spec.name).toList();
        if (proxyNames.toSet().length != proxyNames.length) {
          await client.close();
          _statuses.add({
            'id': id,
            'status': 'failed',
            'detail': 'MCP server returned duplicate tool names after namespacing',
          });
          continue;
        }
        // Registry registration also preflights the whole batch atomically.
        final collisions = proxies.where((tool) => registry.get(tool.spec.name) != null).toList();
        if (collisions.isNotEmpty) {
          await client.close();
          _statuses.add({'id': id, 'status': 'failed', 'detail': 'tool name collision'});
          continue;
        }
        registry.registerAll(proxies);
        _clients.add(client);
        count += proxies.length;
        _statuses.add({'id': id, 'status': 'ready', 'transport': type, 'tools': proxies.length});
      } catch (error) {
        await client.close();
        _statuses.add({'id': id, 'status': 'failed', 'detail': '$error'});
      }
    }
    if (servers.length > 8) {
      _statuses.add({'id': '*', 'status': 'limited', 'detail': 'maximum 8 MCP servers per runtime'});
    }
    return count;
  }

  /// stdio transport: sandboxed local child process with a private
  /// per-server workspace. Never mounts the user's project root or
  /// credential files into an extension process.
  Future<McpToolServer?> _stdioClient(String id, Map<String, dynamic> cfg) async {
    final command = cfg['command'];
    final rawArgs = cfg['args'] ?? const <String>[];
    if (command is! String || command.trim().isEmpty || command.contains('\u0000')) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'command invalid'});
      return null;
    }
    if (rawArgs is! List || rawArgs.length > 32 || rawArgs.any((v) => v is! String || v.length > 2048 || v.contains('\u0000'))) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'args invalid'});
      return null;
    }
    if (sandbox.kind == SandboxKind.none) {
      _statuses.add({'id': id, 'status': 'disabled', 'detail': 'OS sandbox unavailable'});
      return null;
    }
    final rawEnvironment = cfg['environment'] ?? const <String, String>{};
    if (rawEnvironment is! Map || rawEnvironment.entries.any((entry) => entry.key is! String || entry.value is! String)) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'environment must be a string mapping'});
      return null;
    }
    final privateWorkspace = await _privateWorkspace(id);
    if (privateWorkspace == null) {
      _statuses.add({'id': id, 'status': 'disabled', 'detail': 'private MCP workspace is unsafe'});
      return null;
    }
    final serverSandbox = SandboxRunner(
      kind: sandbox.kind,
      dockerImage: sandbox.dockerImage,
      workspacePath: privateWorkspace,
    );
    return StdioMcpClient(
      command: command,
      args: rawArgs.cast<String>(),
      environment: Map<String, String>.from(rawEnvironment),
      sandbox: serverSandbox,
    );
  }

  /// http transport: remote Streamable HTTP endpoint. Requires a validated
  /// http(s) URL; optional headers are pre-resolved SecretRefs.
  McpToolServer? _httpClient(String id, Map<String, dynamic> cfg) {
    final url = cfg['url'];
    if (url is! String || url.trim().isEmpty) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'url required for http MCP server'});
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\x7F]').hasMatch(url)) {
      _statuses.add({
        'id': id,
        'status': 'invalid',
        'detail': 'url must be a valid http(s) URL without user-info, fragment, or control characters',
      });
      return null;
    }
    final rawHeaders = cfg['headers'] ?? const <String, String>{};
    const reservedHeaders = {
      'content-type',
      'accept',
      'mcp-session-id',
      'mcp-protocol-version',
    };
    if (rawHeaders is! Map ||
        rawHeaders.length > 32 ||
        rawHeaders.entries.any((entry) {
          if (entry.key is! String || entry.value is! String) return true;
          final key = entry.key as String;
          final value = entry.value as String;
          return !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(key) ||
              reservedHeaders.contains(key.toLowerCase()) ||
              value.length > 8192 ||
              RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);
        })) {
      _statuses.add({
        'id': id,
        'status': 'invalid',
        'detail': 'headers must be a safe string mapping (max 32 headers)',
      });
      return null;
    }
    final protocolVersion = cfg['protocol_version'] ?? '2025-11-25';
    if (protocolVersion is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(protocolVersion)) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'protocol_version must use YYYY-MM-DD'});
      return null;
    }
    final maxReadRetries = cfg['max_read_retries'] ?? 2;
    if (maxReadRetries is! int || maxReadRetries < 0 || maxReadRetries > 3) {
      _statuses.add({'id': id, 'status': 'invalid', 'detail': 'max_read_retries must be an integer from 0 to 3'});
      return null;
    }
    return HttpMcpClient(
      baseUrl: url,
      headers: Map<String, String>.from(rawHeaders),
      protocolVersion: protocolVersion,
      maxReadRetries: maxReadRetries,
    );
  }

  Future<String?> _privateWorkspace(String id) async {
    try {
      // SandboxRunner normally creates this directory at process launch, but
      // the private MCP workspace is prepared before launch. Create and
      // canonicalize the root here so a fresh workspace does not silently
      // disable every configured server.
      final requestedRoot = Directory(sandbox.workspacePath).absolute;
      await requestedRoot.create(recursive: true);
      final root = await requestedRoot.resolveSymbolicLinks();
      var current = root;
      for (final segment in ['.tiko', 'mcp', id]) {
        current = p.join(current, segment);
        final entityType = FileSystemEntity.typeSync(current, followLinks: false);
        if (entityType == FileSystemEntityType.link || entityType == FileSystemEntityType.file) {
          return null;
        }
        if (entityType == FileSystemEntityType.notFound) {
          await Directory(current).create();
        }
        final resolved = await Directory(current).resolveSymbolicLinks();
        if (resolved != root && !p.isWithin(root, resolved)) return null;
        current = resolved;
      }
      return current;
    } catch (_) {
      return null;
    }
  }

  Future<void> closeAll() async {
    final clients = List<McpToolServer>.from(_clients);
    _clients.clear();
    for (final client in clients) {
      try {
        await client.close();
      } catch (_) {
        // Continue shutting down all child processes.
      }
    }
  }
}
