import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// FR-03 (Auto Context Expander): expands `@file:`, `@dir:`, `@git:`, and
/// `@url:` references in user input before the text reaches the LLM.
///
/// Expansion is best-effort and fail-closed for safety:
/// - `@file:` / `@dir:` targets must resolve inside [workspaceRoot]
///   (symlinks are resolved; escaping the workspace is refused);
/// - `@url:` accepts http/https only and blocks localhost / private /
///   link-local addresses by default (SSRF guard);
/// - every expansion is wrapped in an envelope tag and size-capped so a
///   single reference cannot blow up the context window.
class ContextExpander {
  ContextExpander({
    required this.workspaceRoot,
    this.maxFileBytes = 32 * 1024,
    this.maxDirEntries = 200,
    this.maxGitLines = 400,
    this.maxUrlBytes = 64 * 1024,
    this.allowPrivateUrls = false,
    this.httpTimeout = const Duration(seconds: 15),
  });

  /// Absolute path of the agent workspace. File/dir references outside
  /// this root are rejected.
  final String workspaceRoot;

  /// Cap for a single expanded file.
  final int maxFileBytes;

  /// Cap for directory listings (files + dirs combined).
  final int maxDirEntries;

  /// Cap for git command outputs.
  final int maxGitLines;

  /// Cap for fetched URL bodies.
  final int maxUrlBytes;

  /// Set to true only for trusted, isolated deployments (e.g. private
  /// networks where the agent is meant to reach internal services).
  final bool allowPrivateUrls;

  /// Timeout for @url fetches.
  final Duration httpTimeout;

  static final _ref = RegExp(
    r'@(file|dir|git|url):([^\s]+)',
    caseSensitive: false,
  );

  /// Expands every supported reference in [text]. Never throws: each
  /// reference that fails expands to nothing and records a warning in
  /// [ContextExpansion.errors], and the original reference token is
  /// preserved so the model can ask about it.
  Future<ContextExpansion> expand(String text) async {
    final errors = <String>[];
    var out = text;
    for (final match in _ref.allMatches(text).toList()) {
      final kind = match.group(1)!.toLowerCase();
      final rawTarget = match.group(2)!;
      try {
        final replacement = await _expandOne(kind, rawTarget, errors);
        out = out.replaceAll(
          match.group(0)!,
          replacement ?? match.group(0)!,
        );
      } catch (e) {
        errors.add('${match.group(0)}: $e');
      }
    }
    return ContextExpansion(text: out, errors: errors);
  }

  Future<String?> _expandOne(
    String kind,
    String target,
    List<String> errors,
  ) async {
    switch (kind) {
      case 'file':
        return _expandFile(target, errors);
      case 'dir':
        return _expandDir(target, errors);
      case 'git':
        return _expandGit(target, errors);
      case 'url':
        return await _expandUrl(target, errors);
    }
    return null;
  }

  // ------------------------------------------------------------------
  // @file:
  // ------------------------------------------------------------------

  Future<String?> _expandFile(String target, List<String> errors) async {
    final resolved = _resolveInWorkspace(target, errors);
    if (resolved == null) return null;
    final f = File(resolved);
    if (!await f.exists()) {
      errors.add('@file:$target: not found');
      return null;
    }
    final stat = await f.length();
    if (stat > maxFileBytes) {
      errors.add(
        '@file:$target: too large (${stat}B > ${maxFileBytes}B cap)',
      );
      return null;
    }
    final content = await f.readAsString(encoding: utf8);
    return _envelope('file', resolved, content);
  }

  // ------------------------------------------------------------------
  // @dir:
  // ------------------------------------------------------------------

  Future<String?> _expandDir(String target, List<String> errors) async {
    final resolved = _resolveInWorkspace(target, errors);
    if (resolved == null) return null;
    final d = Directory(resolved);
    if (!await d.exists()) {
      errors.add('@dir:$target: not found');
      return null;
    }
    final lines = <String>[];
    await for (final e in d.list(recursive: false, followLinks: false)) {
      if (lines.length >= maxDirEntries) {
        lines.add('… (listing truncated at $maxDirEntries entries)');
        break;
      }
      final name = e.uri.pathSegments.last;
      if (name == '.git' || name == '.dart_tool' || name == '.tiko') continue;
      lines.add(e is Directory ? '$name/' : name);
    }
    if (lines.isEmpty) return _envelope('dir', resolved, '(empty directory)');
    return _envelope('dir', resolved, lines.join('\n'));
  }

  // ------------------------------------------------------------------
  // @git:diff | @git:log | @git:status
  // ------------------------------------------------------------------

  Future<String?> _expandGit(String target, List<String> errors) async {
    final mode = target.trim().toLowerCase();
    List<String> args;
    switch (mode) {
      case 'diff':
        args = ['diff'];
        break;
      case 'log':
        args = ['log', '-n', '50', '--oneline'];
        break;
      case 'status':
        args = ['status', '--short', '--branch'];
        break;
      default:
        errors.add('@git:$target: unsupported mode '
            '(use @git:diff, @git:log, or @git:status)');
        return null;
    }
    if (!await Directory(workspaceRoot).exists()) {
      errors.add('@git: workspace not found');
      return null;
    }
    final result = await Process.run(
      'git',
      args,
      workingDirectory: workspaceRoot,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      errors.add('@git:$target: git exited ${result.exitCode}');
      return null;
    }
    var out = (result.stdout as String).trim();
    final allLines = out.split('\n');
    if (allLines.length > maxGitLines) {
      out = '${allLines.take(maxGitLines).join('\n')}\n… (truncated at $maxGitLines lines)';
    }
    if (out.isEmpty) out = '(no output)';
    return _envelope('git:$mode', workspaceRoot, out);
  }

  // ------------------------------------------------------------------
  // @url:
  // ------------------------------------------------------------------

  Future<String?> _expandUrl(String target, List<String> errors) async {
    Uri uri;
    try {
      uri = Uri.parse(target);
    } catch (e) {
      errors.add('@url:$target: invalid URI');
      return null;
    }
    if (!uri.hasScheme || !uri.hasAuthority) {
      errors.add('@url:$target: missing scheme/host');
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      errors.add('@url:$target: only http(s) is allowed');
      return null;
    }
    if (!allowPrivateUrls && _isPrivateHost(uri.host)) {
      errors.add('@url:$target: private/localhost hosts are blocked by the '
          'SSRF guard');
      return null;
    }
    final client = HttpClient();
    client.connectionTimeout = httpTimeout;
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'TikoAgent-ContextExpander');
      final res = await req.close().timeout(httpTimeout);
      if (res.statusCode >= 400) {
        errors.add('@url:$target: HTTP ${res.statusCode}');
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > maxUrlBytes) break;
      }
      final truncated = builder.length > maxUrlBytes;
      final bytes = builder.takeBytes();
      var body = utf8.decode(bytes, allowMalformed: true);
      if (truncated) body += '\n… (truncated at $maxUrlBytes bytes)';
      return _envelope('url', target, body);
    } finally {
      client.close(force: true);
    }
  }

  bool _isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) {
      return true;
    }
    if (h == 'metadata.google.internal' || h == '169.254.169.254') {
      return true;
    }
    try {
      final raw = InternetAddress.tryParse(h);
      if (raw == null) return false; // hostname: let DNS decide, we check IP only
      switch (raw.type) {
        case InternetAddressType.IPv4:
          final parts = h.split('.').map(int.parse).toList();
          if (parts[0] == 10) return true; // 10.0.0.0/8
          if (parts[0] == 192 && parts[1] == 168) return true; // 192.168/16
          if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
          if (parts[0] == 127) return true; // loopback
          if (parts[0] == 169 && parts[1] == 254) return true; // link-local
          if (parts[0] == 0) return true;
          return false;
        case InternetAddressType.IPv6:
          final v6 = raw.address.toLowerCase();
          if (v6.startsWith('::1') || v6 == '::') return true;
          if (v6.startsWith('fe80')) return true; // link-local
          if (v6.startsWith('fc') || v6.startsWith('fd')) return true; // ULA
          return false;
        default:
          return false;
      }
    } catch (_) {
      return true; // unparseable: treat as unsafe
    }
  }

  // ------------------------------------------------------------------
  // Path safety
  // ------------------------------------------------------------------

  String? _resolveInWorkspace(String target, List<String> errors) {
    // Workspace-relative paths (no leading /) resolve against the root.
    final isRelative = !target.startsWith('/') && !target.contains(':\\');
    final absolute = isRelative
        ? _joinPaths(workspaceRoot, target)
        : _normalize(target);
    // Canonicalize the deepest existing ancestor so symlinks cannot smuggle
    // a target outside the workspace.
    var probe = absolute;
    final tail = <String>[];
    while (!File(probe).existsSync() && !Directory(probe).existsSync()) {
      final parent = _parentOf(probe);
      if (parent == probe || parent.isEmpty) {
        errors.add('@$target: cannot resolve (no existing ancestor)');
        return null;
      }
      tail.insert(0, probe.substring(parent.length).replaceAll('/', ''));
      probe = parent;
    }
    try {
      probe = File(probe).existsSync() || Directory(probe).existsSync()
          ? Directory(probe).resolveSymbolicLinksSync()
          : probe;
    } catch (e) {
      errors.add('@$target: $e');
      return null;
    }
    var resolved = probe;
    for (final seg in tail) {
      resolved = '$resolved/$seg';
    }
    final root = _normalize(workspaceRoot);
    if (!resolved.startsWith(root)) {
      errors.add('@$target: escapes the workspace root');
      return null;
    }
    return resolved;
  }

  String _joinPaths(String root, String rel) {
    final cleanRel = rel.replaceAll(RegExp(r'^[./]+'), '');
    final cleanRoot = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    return '$cleanRoot/$cleanRel';
  }

  String _normalize(String p) {
    final path = p.replaceAll('\\', '/');
    final isAbs = path.startsWith('/');
    final out = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(seg);
    }
    return (isAbs ? '/' : '') + out.join('/');
  }

  String _parentOf(String p) {
    final norm = _normalize(p);
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return norm.startsWith('/') ? '/' : '';
    return norm.substring(0, idx);
  }

  String _envelope(String kind, String source, String content) {
    // Neutralize any closing tag inside the content so the envelope cannot
    // be broken out of.
    final safe = content.replaceAll(
      RegExp(r'</\s*expanded_context', caseSensitive: false),
      '<\\/expanded_context',
    );
    return '<expanded_context source="@$kind:$source">\n$safe\n</expanded_context>';
  }
}

class ContextExpansion {
  ContextExpansion({required this.text, required this.errors});
  final String text;
  final List<String> errors;
}
