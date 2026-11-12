import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

LlmProvider _buildWithEnv(String yaml, Map<String, String> env, String id) {
  final (cfg, issues) = TikoConfig.parse(yaml);
  expect(issues, isEmpty, reason: 'config harus valid: $issues');
  final c = cfg.providers[id];
  expect(c, isNotNull);
  return ProviderFactory(env: env).build(c!);
}

void main() {
  group('ProviderConfig parity fields (parse)', () {
    test('field Hermes-parity ter-parse dari YAML', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: pool
  chat:
    pool:
      type: openai_compat
      base_url: "https://api.example.com/v1"
      model: m1
      api_key: "env:KEY_1"
      api_keys:
        - "env:KEY_2"
        - "env:KEY_3"
      request_timeout_sec: 45
      model_timeouts:
        big-model: 120
        small-model: 15
      context_length: 131072
      discover_models: true
''');
      expect(issues, isEmpty);
      final c = cfg.providers['pool']!;
      expect(c.apiKeyRefs, ['env:KEY_2', 'env:KEY_3']);
      expect(c.requestTimeoutSec, 45);
      expect(c.modelTimeouts, {'big-model': 120, 'small-model': 15});
      expect(c.contextLength, 131072);
      expect(c.discoverModels, isTrue);
    });

    test('field Bedrock + OAuth ter-parse dari YAML', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: aws
  chat:
    aws:
      type: bedrock
      region: us-west-2
      model: anthropic.claude-sonnet-4-20250514-v1:0
      access_key_id: "env:AWS_ACCESS_KEY_ID"
      secret_access_key: "env:AWS_SECRET_ACCESS_KEY"
      session_token: "env:AWS_SESSION_TOKEN"
      request_timeout_sec: 60
''');
      expect(issues, isEmpty);
      final c = cfg.providers['aws']!;
      expect(c.region, 'us-west-2');
      expect(c.accessKeyRef, 'env:AWS_ACCESS_KEY_ID');
      expect(c.secretKeyRef, 'env:AWS_SECRET_ACCESS_KEY');
      expect(c.sessionTokenRef, 'env:AWS_SESSION_TOKEN');
    });

    test('oauth fields ter-parse dan validasi type preset diterima', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: deepseek
  chat:
    deepseek:
      type: deepseek
      api_key: "env:DEEPSEEK_API_KEY"
    oauthprov:
      type: openai_compat
      base_url: "https://api.example.com/v1"
      oauth_device_url: "https://auth.example.com/device/code"
      oauth_token_url: "https://auth.example.com/oauth/token"
      oauth_client_id: "client-123"
      oauth_scopes:
        - read
        - write
      oauth_token_cache: "/tmp/token-cache.json"
''');
      expect(issues, isEmpty, reason: 'type: deepseek adalah preset valid');
      final ds = cfg.providers['deepseek']!;
      expect(ds.type, 'deepseek');
      final oc = cfg.providers['oauthprov']!;
      expect(oc.oauthDeviceUrl, 'https://auth.example.com/device/code');
      expect(oc.oauthTokenUrl, 'https://auth.example.com/oauth/token');
      expect(oc.oauthClientId, 'client-123');
      expect(oc.oauthScopes, ['read', 'write']);
      expect(oc.oauthTokenCache, '/tmp/token-cache.json');
    });

    test('api_keys non-daftar ditolak dan secret mentah di api_key ditandai', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: raw
  chat:
    raw:
      type: openai_compat
      api_key: "sk-raw-secret"
    list:
      type: openai_compat
      api_keys: "not-a-list"
''');
      expect(issues.any((i) => i.path == 'providers.chat.raw.api_key'), isTrue);
      expect(issues.any((i) => i.path == 'providers.chat.list.api_keys'), isTrue);
      expect(cfg.providers.containsKey('raw'), isFalse);
    });
  });

  group('ProviderFactory parity', () {
    test('preset deepseek -> OpenAiCompatProvider dengan baseUrl preset', () {
      final p = _buildWithEnv('''
providers:
  default_chat: ds
  chat:
    ds:
      type: deepseek
      api_key: "env:DEEPSEEK_API_KEY"
''', {'DEEPSEEK_API_KEY': 'sk-test'}, 'ds');
      expect(p, isA<OpenAiCompatProvider>());
      expect(p.id, 'ds');
      final compat = p as OpenAiCompatProvider;
      expect(compat.baseUrl, 'https://api.deepseek.com/v1');
      expect(compat.model, 'deepseek-chat');
      expect(compat.credentialPool, isNull);
    });

    test('pool >= 2 key -> CredentialPool terpasang; 1 key -> null', () {
      final yaml = '''
providers:
  default_chat: pool
  chat:
    pool:
      type: openai_compat
      base_url: "https://api.example.com/v1"
      api_key: "env:KEY_1"
      api_keys:
        - "env:KEY_2"
''';
      final withPool = _buildWithEnv(
        yaml,
        {'KEY_1': 'k1', 'KEY_2': 'k2'},
        'pool',
      ) as OpenAiCompatProvider;
      expect(withPool.credentialPool, isNotNull);
      expect(withPool.credentialPool!.current, 'k1');

      final single = _buildWithEnv(
        yaml,
        {'KEY_1': 'k1'},
        'pool',
      ) as OpenAiCompatProvider;
      expect(single.credentialPool, isNull);
    });

    test('oauth fields -> tokenProvider terpasang', () {
      final p = _buildWithEnv('''
providers:
  default_chat: oc
  chat:
    oc:
      type: openai_compat
      base_url: "https://api.example.com/v1"
      oauth_device_url: "https://auth.example.com/device/code"
      oauth_token_url: "https://auth.example.com/oauth/token"
      oauth_client_id: "client-123"
''', const {}, 'oc') as OpenAiCompatProvider;
      expect(p.tokenProvider, isNotNull);
    });

    test('azure_openai -> AzureOpenAIProvider dengan apiVersion', () {
      final p = _buildWithEnv('''
providers:
  default_chat: az
  chat:
    az:
      type: azure_openai
      base_url: "https://my-res.openai.azure.com"
      model: gpt-4o-deploy
      api_key: "env:AZURE_KEY"
      api_version: "2024-10-21"
''', {'AZURE_KEY': 'az-key'}, 'az');
      expect(p, isA<AzureOpenAIProvider>());
    });

    test('openai_responses -> OpenAiResponsesProvider', () {
      final p = _buildWithEnv('''
providers:
  default_chat: rs
  chat:
    rs:
      type: openai_responses
      base_url: "https://api.openai.com/v1"
      model: gpt-5-codex
      api_key: "env:OPENAI_API_KEY"
''', {'OPENAI_API_KEY': 'sk-test'}, 'rs');
      expect(p, isA<OpenAiResponsesProvider>());
    });

    test('bedrock dengan env keys -> BedrockProvider', () {
      final p = _buildWithEnv('''
providers:
  default_chat: aws
  chat:
    aws:
      type: bedrock
      region: us-east-1
      access_key_id: "env:AWS_ACCESS_KEY_ID"
      secret_access_key: "env:AWS_SECRET_ACCESS_KEY"
''', {
        'AWS_ACCESS_KEY_ID': 'AKID',
        'AWS_SECRET_ACCESS_KEY': 'SECRET',
      }, 'aws');
      expect(p, isA<BedrockProvider>());
      expect(p.capabilities.streaming, isFalse);
    });

    test('bedrock tanpa keys -> ArgumentError', () {
      final (cfg, issues) = TikoConfig.parse('''
providers:
  default_chat: aws
  chat:
    aws:
      type: bedrock
      region: us-east-1
''');
      expect(issues, isEmpty);
      expect(
        () => ProviderFactory(env: const {}).build(cfg.providers['aws']!),
        throwsArgumentError,
      );
    });

    test('context_length config override maxContext preset', () {
      final p = _buildWithEnv('''
providers:
  default_chat: ds
  chat:
    ds:
      type: deepseek
      api_key: "env:DEEPSEEK_API_KEY"
      context_length: 64000
''', {'DEEPSEEK_API_KEY': 'sk-test'}, 'ds');
      expect(p.capabilities.maxContext, 64000);
    });

    test('sandbox.container_persistent ter-parse', () {
      final (on, i1) = TikoConfig.parse('''
sandbox:
  container_persistent: true
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
      expect(i1, isEmpty);
      expect(on.sandboxDockerPersistent, isTrue);
      final (off, i2) = TikoConfig.parse('''
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
      expect(i2, isEmpty);
      expect(off.sandboxDockerPersistent, isFalse);
    });

    test('memory.external_providers kind supermemory/hindsight ter-parse', () {
      final (cfg, issues) = TikoConfig.parse('''
memory:
  external_providers:
    - kind: supermemory
      name: user-1
      api_key: "env:SUPERMEMORY_API_KEY"
    - kind: hindsight
      base_url: "http://127.0.0.1:8000"
      name: user-2
      api_key: "env:HINDSIGHT_API_KEY"
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
      expect(issues, isEmpty);
      expect(cfg.memoryProviders, hasLength(2));
      expect(cfg.memoryProviders[0].kind, 'supermemory');
      expect(cfg.memoryProviders[0].baseUrl, isEmpty);
      expect(cfg.memoryProviders[0].apiKeyRef, 'env:SUPERMEMORY_API_KEY');
      expect(cfg.memoryProviders[1].kind, 'hindsight');
      expect(cfg.memoryProviders[1].baseUrl, 'http://127.0.0.1:8000');
    });

    test('request_timeout_sec -> requestTimeout Duration', () {
      final p = _buildWithEnv('''
providers:
  default_chat: ds
  chat:
    ds:
      type: deepseek
      api_key: "env:DEEPSEEK_API_KEY"
      request_timeout_sec: 90
''', {'DEEPSEEK_API_KEY': 'sk-test'}, 'ds') as OpenAiCompatProvider;
      expect(p.requestTimeout, const Duration(seconds: 90));
      expect(p.modelTimeouts, isEmpty);
    });
  });
}
