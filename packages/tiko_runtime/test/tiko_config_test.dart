import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('TikoConfig', () {
    test('valid config resolves providers.default_chat', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: local
  chat:
    local:
      type: openai_compat
      base_url: "http://127.0.0.1:11434/v1"
      model: m
''');
      expect(issues, isEmpty);
      expect(cfg.defaultProvider, 'local');
      expect(cfg.providers['local']!.type, 'openai_compat');
    });

    test('features section wires image generation and vision flags', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
features:
  image_generation: true
  vision: true
  fal_api_key: "env:FAL_KEY"
  openai_api_key: "env:OPENAI_API_KEY"
''');
      expect(issues, isEmpty);
      expect(cfg.enableImageGeneration, isTrue);
      expect(cfg.enableVision, isTrue);
      expect(cfg.falApiKeyRef, 'env:FAL_KEY');
      expect(cfg.openaiApiKeyRef, 'env:OPENAI_API_KEY');
    });

    test('features flags default to false and reject raw secrets', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
features:
  fal_api_key: "fal-sk-live-123"
''');
      expect(cfg.enableImageGeneration, isFalse);
      expect(cfg.enableVision, isFalse);
      expect(cfg.falApiKeyRef, isNull);
      expect(issues.any((i) => i.path == 'features.fal_api_key'), isTrue);
    });

    test('duplicate keys are rejected by the real YAML parser', () {
      final (_, issues) = TikoConfig.parse('storage:\n  a: 1\nstorage:\n  b: 2\n');
      expect(issues.any((i) => i.fatal), isTrue);
    });

    test('raw secrets in file are rejected; env SecretRef accepted', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: c
  chat:
    c:
      type: openai_compat
      api_key: "sk-live-123"
''');
      expect(issues.any((i) => i.path.endsWith('api_key')), isTrue);
      expect(cfg.providers.containsKey('c'), isFalse);

      final (ok, issues2) = TikoConfig.parse('''
providers:
  default_chat: c
  chat:
    c:
      type: openai_compat
      api_key: "env:MY_KEY"
''');
      expect(issues2, isEmpty);
      expect(ok.providers['c']!.apiKeyRef, 'env:MY_KEY');
      expect(TikoConfig.resolveSecretRef('env:MY_KEY', env: {'MY_KEY': 'v'}), 'v');
      expect(TikoConfig.resolveSecretRef('env:NOPE', env: {}), isNull);
    });

    test('wrong provider scalar types are validation errors, not parse crashes', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: local
  chat:
    local:
      type: openai_compat
      base_url: 123
      model: false
      enabled: 2
''');
      expect(issues.where((issue) => issue.fatal).length, greaterThanOrEqualTo(3));
      expect(cfg.providers.containsKey('mock'), isTrue);
    });

    test('invalid agent budgets and provider URLs are rejected', () {
      final (_, issues) = TikoConfig.parse('''
agent:
  max_iterations: 0
  max_tokens_per_task: huge
  max_wall_clock_sec: -1
  max_tool_calls: 100000000
providers:
  default_chat: local
  chat:
    local:
      type: openai_compat
      base_url: "file:///etc/passwd"
      model: qwen
''');
      final paths = issues.map((issue) => issue.path).toSet();
      expect(paths, contains('agent.max_iterations'));
      expect(paths, contains('agent.max_tokens_per_task'));
      expect(paths, contains('agent.max_wall_clock_sec'));
      expect(paths, contains('agent.max_tool_calls'));
      expect(paths, contains('providers.chat.local.base_url'));
    });

    test('invalid API port is reported and safely falls back', () {
      final (cfg, issues) = TikoConfig.parse('''
api:
  port: 70000
''');
      expect(issues.any((issue) => issue.path == 'api.port'), isTrue);
      expect(cfg.apiPort, 8787);
    });

    test('unknown provider type and missing default are reported', () {
      final (_, issues) = TikoConfig.parse('''
providers:
  default_chat: missing
  chat:
    x:
      type: quantum
''');
      expect(issues.length, greaterThanOrEqualTo(2));
    });

    test('setup YAML uses canonical mock provider schema', () {
      final (cfg, issues) = TikoConfig.parse(TikoConfig.setupYaml(
        provider: 'mock',
        workspace: '/tmp/tiko workspace',
      ));
      expect(issues, isEmpty);
      expect(cfg.defaultProvider, 'mock');
      expect(cfg.providers['mock']?.enabled, isTrue);
      expect(cfg.providers['ollama_local']?.enabled, isFalse);
      expect(cfg.workspace, '/tmp/tiko workspace');
      expect(cfg.dbPath, 'data/agent.db');
    });

    test('MCP requires unique id, explicit allowlist and minimum risk', () {
      final (_, missingAllow) = TikoConfig.parse('''
mcp:
  servers:
    - id: local
      command: python3
      args: [server.py]
''');
      expect(missingAllow.any((issue) => issue.path.endsWith('.allow')), isTrue);

      final (cfg, validIssues) = TikoConfig.parse('''
mcp:
  servers:
    - id: local
      command: python3
      args: [server.py]
      allow: [read_file, list_directory]
      risk: high
      env:
        API_KEY: env:MCP_API_KEY
''');
      expect(validIssues.where((issue) => issue.fatal), isEmpty);
      expect(cfg.mcpServers, hasLength(1));
      expect(cfg.mcpServers.single.allow, ['read_file', 'list_directory']);
      expect(cfg.mcpServers.single.environmentRefs['API_KEY'], 'env:MCP_API_KEY');
    });

    test('MCP HTTP protocol version has a default and accepts an override', () {
      final (defaults, defaultIssues) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      allow: [ping]
      risk: high
''');
      expect(defaultIssues.where((issue) => issue.fatal), isEmpty);
      expect(defaults.mcpServers.single.protocolVersion, '2025-11-25');
      expect(defaults.mcpServers.single.maxReadRetries, 2);

      final (configured, configuredIssues) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      protocol_version: '2025-06-18'
      max_read_retries: 1
      allow: [ping]
      risk: high
''');
      expect(configuredIssues.where((issue) => issue.fatal), isEmpty);
      expect(configured.mcpServers.single.protocolVersion, '2025-06-18');
      expect(configured.mcpServers.single.maxReadRetries, 1);
    });

    test('MCP HTTP URL rejects embedded credentials and fragments', () {
      final (_, credentials) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://user:password@mcp.example.test/mcp
      allow: [ping]
      risk: high
''');
      expect(credentials.any((issue) => issue.path.endsWith('.url')), isTrue);

      final (_, fragment) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp#token
      allow: [ping]
      risk: high
''');
      expect(fragment.any((issue) => issue.path.endsWith('.url')), isTrue);
    });

    test('MCP protocol version rejects malformed version and stdio use', () {
      final (_, invalidHttp) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      protocol_version: latest
      allow: [ping]
      risk: high
''');
      expect(invalidHttp.any((issue) => issue.path.endsWith('.protocol_version')),
          isTrue);

      final (_, invalidStdio) = TikoConfig.parse('''
mcp:
  servers:
    - id: local
      type: stdio
      command: python3
      protocol_version: '2025-06-18'
      max_read_retries: 1
      allow: [ping]
      risk: high
''');
      expect(invalidStdio.any((issue) => issue.path.endsWith('.protocol_version')),
          isTrue);
    });

    test('MCP HTTP read-only retry count is bounded and typed', () {
      final (_, tooMany) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      max_read_retries: 4
      allow: [ping]
      risk: high
''');
      expect(tooMany.any((issue) => issue.path.endsWith('.max_read_retries')), isTrue);

      final (_, wrongType) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      max_read_retries: many
      allow: [ping]
      risk: high
''');
      expect(wrongType.any((issue) => issue.path.endsWith('.max_read_retries')), isTrue);
    });

    test('MCP config rejects reserved protocol headers', () {
      final (_, issues) = TikoConfig.parse('''
mcp:
  servers:
    - id: remote
      type: http
      url: https://mcp.example.test/mcp
      allow: [ping]
      risk: high
      headers:
        Accept: env:MCP_ACCEPT
''');
      expect(issues.any((issue) => issue.path.endsWith('.headers')), isTrue);
    });

    test('MCP config rejects raw secrets, low risk and duplicate server ids', () {
      final (_, issues) = TikoConfig.parse('''
mcp:
  servers:
    - id: local
      command: python3
      allow: [ping]
      risk: low
      env:
        API_KEY: "super-secret"
    - id: local
      command: python3
      allow: [ping]
      risk: high
''');
      final paths = issues.where((issue) => issue.fatal).map((issue) => issue.path).toSet();
      expect(paths, contains('mcp.servers[0].risk'));
      expect(paths, contains('mcp.servers[0].env'));
      expect(paths, contains('mcp.servers[1].id'));
    });

    test('setup YAML quotes workspace paths containing YAML punctuation', () {
      const workspace = r'C:\Users\agent\work #1 "project"';
      final (cfg, issues) = TikoConfig.parse(
        TikoConfig.setupYaml(provider: 'mock', workspace: workspace),
      );
      expect(issues.where((issue) => issue.fatal), isEmpty);
      expect(cfg.workspace, workspace);
    });

    test('setup rejects an empty workspace path', () {
      expect(
        () => TikoConfig.setupYaml(workspace: '  '),
        throwsArgumentError,
      );
    });

    test('setup YAML selects Ollama native provider', () {
      final (cfg, issues) = TikoConfig.parse(
        TikoConfig.setupYaml(provider: 'ollama'),
      );
      expect(issues, isEmpty);
      expect(cfg.defaultProvider, 'ollama_local');
      expect(cfg.providers['ollama_local']?.type, 'ollama_native');
      expect(cfg.providers['ollama_local']?.enabled, isTrue);
      expect(cfg.providers['mock']?.enabled, isFalse);
    });

    test('setup rejects unsupported provider choices', () {
      expect(
        () => TikoConfig.setupYaml(provider: 'unknown'),
        throwsArgumentError,
      );
    });

    test('missing config file falls back to a runnable mock provider', () async {
      final temp = await Directory.systemTemp.createTemp('tiko_missing_config_');
      addTearDown(() => temp.delete(recursive: true));
      final (cfg, issues) = TikoConfig.load('${temp.path}/missing.yaml');
      expect(issues.every((issue) => !issue.fatal), isTrue);
      expect(cfg.defaultProvider, 'mock');
      expect(cfg.providers['mock']?.enabled, isTrue);
    });

    test('empty config falls back to mock', () {
      final (cfg, _) = TikoConfig.parse('');
      expect(cfg.defaultProvider, 'mock');
    });

    test('providers.tiers memetakan tier ke provider dan divalidasi', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: kecil
  tiers:
    1: kecil
    3: besar
  chat:
    kecil:
      type: mock
    besar:
      type: mock
''');
      expect(issues, isEmpty);
      expect(cfg.tierProviders[1], 'kecil');
      expect(cfg.tierProviders[3], 'besar');
      expect(cfg.tierProviders.containsKey(2), isFalse);

      final (_, badIssues) = TikoConfig.parse('''
providers:
  default_chat: kecil
  tiers:
    0: kecil
    2: hantu
  chat:
    kecil:
      type: mock
''');
      final paths = badIssues.map((issue) => issue.path).toSet();
      expect(paths, contains('providers.tiers.0'));
      expect(paths, contains('providers.tiers.2'));

      final (_, scalarIssues) = TikoConfig.parse('''
providers:
  default_chat: kecil
  tiers: oops
  chat:
    kecil:
      type: mock
''');
      expect(
        scalarIssues.any((issue) => issue.path == 'providers.tiers'),
        isTrue,
      );
    });

    test('shipped config/agent.yaml is valid', () {
      final f = File('../../config/agent.yaml');
      if (!f.existsSync()) return; // run from another cwd
      final (_, issues) = TikoConfig.parse(f.readAsStringSync());
      expect(issues.where((i) => i.fatal), isEmpty);
    });
  });

  test('ConfigStore round-trips quoted and Windows-style path values', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_config_quote_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = '${temp.path}/agent.yaml';
    await File(configPath).writeAsString(TikoConfig.setupYaml());
    final store = ConfigStore(
      configPath: configPath,
      revisionsDir: '${temp.path}/revisions',
    );
    const value = r'C:\workspace\a "quoted" # project';
    final result = await store.setPath('workspace', value);
    expect(result.issues.where((issue) => issue.fatal), isEmpty);
    final (cfg, issues) = TikoConfig.load(configPath);
    expect(issues.where((issue) => issue.fatal), isEmpty);
    expect(cfg.workspace, value);
  });

  test('DaemonManager generates a cryptographically random token shape', () {
    final manager = DaemonManager(dataDir: 'data', apiPort: 8787);
    final tokenA = manager.envToken();
    final tokenB = manager.envToken();
    expect(tokenA, hasLength(64));
    expect(tokenA, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(tokenB, hasLength(64));
    expect(tokenB, isNot(tokenA));
  });

  test('ApiTokenStore persists and reads token without exposing it in config', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_api_token_');
    addTearDown(() => temp.delete(recursive: true));
    const token = '0123456789abcdef0123456789abcdef';
    await ApiTokenStore.write(temp.path, token);
    expect(await ApiTokenStore.read(temp.path, environment: {}), token);
    expect(await ApiTokenStore.read(temp.path, environment: {'API_TOKEN': 'env-token'}), 'env-token');
    expect(await File(ApiTokenStore.pathFor(temp.path)).exists(), isTrue);
  });

  test('DaemonManager stops only through authenticated daemon shutdown API', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_daemon_stop_');
    addTearDown(() => temp.delete(recursive: true));
    const token = '0123456789abcdef0123456789abcdef';
    await ApiTokenStore.write(temp.path, token);

    final lock = RuntimeLock('${temp.path}/tiko.lock');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/v1/shutdown' &&
          request.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $token') {
        request.response.statusCode = 200;
        request.response.write('{"ok":true}');
        await request.response.close();
        await lock.release();
      } else if (request.uri.path == '/health') {
        request.response.write('{"ok":true}');
        await request.response.close();
      } else {
        request.response.statusCode = 401;
        await request.response.close();
      }
    });
    addTearDown(server.close);
    await lock.acquire(profile: 'test', version: '1', port: server.port);

    final manager = DaemonManager(dataDir: temp.path, apiPort: server.port);
    final result = await manager.stop();
    expect(result['stopped'], isTrue);
    expect(result['pid'], pid);
    expect(await lock.read(), isNull);
  }, skip: Platform.isWindows);



  group('RuntimeLock', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tiko_lock_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('acquire, read, release', () async {
      final l = RuntimeLock('${tmp.path}/tiko.lock');
      await l.acquire(profile: 'p', version: '1', port: 8787);
      expect((await l.read())!.port, 8787);
      await l.release();
      expect(await l.read(), isNull);
    });

    test('stale lock (dead pid) is reclaimed', () async {
      File('${tmp.path}/tiko.lock').writeAsStringSync(
        '{"pid": 2147483646, "port": 1, "profile": "p", "version": "0", '
        '"started_at": "2026-01-01T00:00:00Z"}',
      );
      final l = RuntimeLock('${tmp.path}/tiko.lock');
      await l.acquire(profile: 'p', version: '1');
      expect((await l.read())!.pid, pid);
    }, skip: Platform.isWindows);

    test('live foreign lock is respected and never killed', () async {
      final other = await Process.start('sleep', ['30']);
      addTearDown(() => other.kill());
      File('${tmp.path}/tiko.lock').writeAsStringSync(
        '{"pid": ${other.pid}, "port": 8787, "profile": "p", "version": "0", '
        '"started_at": "2026-01-01T00:00:00Z"}',
      );
      final l = RuntimeLock('${tmp.path}/tiko.lock');
      await expectLater(
        l.acquire(profile: 'p', version: '1'),
        throwsA(isA<LockHeldException>()),
      );
      expect(RuntimeLock.isAlive(other.pid), isTrue);
    }, skip: Platform.isWindows);
  });
}
