import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('onboarding-test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('renderConfigYaml', () {
    test('preset provider with api key parses without fatal issues', () {
      final yaml = OnboardingWizard.renderConfigYaml(OnboardingProfile(
        providerType: 'openai',
        workspace: '/tmp/ws',
        model: 'gpt-5.1',
        apiKeyEnvVar: 'OPENAI_API_KEY',
      ));
      final (config, issues) = TikoConfig.parse(yaml);
      expect(issues.where((i) => i.fatal), isEmpty,
          reason: issues.join('\n'));
      expect(config.defaultProvider, 'main');
      final provider = config.providers['main']!;
      expect(provider.type, 'openai');
      expect(provider.apiKeyRef, 'env:OPENAI_API_KEY');
      expect(provider.model, 'gpt-5.1');
      expect(provider.enabled, isTrue);
    });

    test('mock and ollama profiles parse', () {
      final mock = OnboardingWizard.renderConfigYaml(OnboardingProfile(
        providerType: 'mock',
        workspace: '.',
      ));
      final (mockConfig, mockIssues) = TikoConfig.parse(mock);
      expect(mockIssues.where((i) => i.fatal), isEmpty);
      expect(mockConfig.defaultProvider, 'mock');

      final ollama = OnboardingWizard.renderConfigYaml(OnboardingProfile(
        providerType: 'ollama_native',
        workspace: '.',
      ));
      final (ollamaConfig, ollamaIssues) = TikoConfig.parse(ollama);
      expect(ollamaIssues.where((i) => i.fatal), isEmpty);
      expect(ollamaConfig.defaultProvider, 'ollama_local');
    });

    test('unknown provider type is rejected', () {
      expect(
        () => OnboardingWizard.renderConfigYaml(OnboardingProfile(
          providerType: 'tidak_ada',
          workspace: '.',
        )),
        throwsArgumentError,
      );
    });
  });

  group('renderEnvFile', () {
    test('sorted export lines with header', () {
      final body = OnboardingWizard.renderEnvFile(OnboardingProfile(
        providerType: 'openai',
        workspace: '.',
        apiKeyEnvVar: 'OPENAI_API_KEY',
        env: {
          'TG_TOKEN': '123:abc',
          'OPENAI_API_KEY': 'sk-test',
        },
      ));
      final lines = body.trim().split('\n');
      expect(lines.first, startsWith('#'));
      final exports = lines.where((l) => l.startsWith('export ')).toList();
      expect(exports, [
        'export OPENAI_API_KEY=sk-test',
        'export TG_TOKEN=123:abc',
      ]);
    });

    test('rejects newline in values', () {
      expect(
        () => OnboardingWizard.renderEnvFile(OnboardingProfile(
          providerType: 'mock',
          workspace: '.',
          env: {'TG_TOKEN': 'line1\nline2'},
        )),
        throwsArgumentError,
      );
    });
  });

  group('writeAll', () {
    test('writes validated config and 0600 env file', () async {
      final configPath = '${tempDir.path}/config/config.yaml';
      final dataDir = '${tempDir.path}/data';
      final paths = await OnboardingWizard.writeAll(
        configPath: configPath,
        dataDir: dataDir,
        profile: OnboardingProfile(
          providerType: 'openai',
          workspace: '/tmp/ws',
          apiKeyEnvVar: 'OPENAI_API_KEY',
          env: {'OPENAI_API_KEY': 'sk-test-value'},
        ),
      );
      final (config, issues) = TikoConfig.load(paths.configPath);
      expect(issues.where((i) => i.fatal), isEmpty);
      expect(config.providers['main']!.apiKeyRef, 'env:OPENAI_API_KEY');

      final envFile = File(paths.envPath);
      expect(await envFile.exists(), isTrue);
      expect(await envFile.readAsString(), contains('OPENAI_API_KEY=sk-test-value'));
      if (!Platform.isWindows) {
        final stat = await envFile.stat();
        expect(stat.modeString(), 'rw-------');
      }
    });

    test('refuses overwrite without force', () async {
      final configPath = '${tempDir.path}/config.yaml';
      await File(configPath).writeAsString('profile: default\n');
      await expectLater(
        OnboardingWizard.writeAll(
          configPath: configPath,
          dataDir: tempDir.path,
          profile: OnboardingProfile(
            providerType: 'mock',
            workspace: '.',
          ),
        ),
        throwsStateError,
      );
    });

    test('force overwrites an existing config', () async {
      final configPath = '${tempDir.path}/config.yaml';
      await File(configPath).writeAsString('profile: default\n');
      final paths = await OnboardingWizard.writeAll(
        configPath: configPath,
        dataDir: tempDir.path,
        profile: OnboardingProfile(
          providerType: 'mock',
          workspace: '.',
        ),
        force: true,
      );
      final (config, issues) = TikoConfig.load(paths.configPath);
      expect(issues.where((i) => i.fatal), isEmpty);
      expect(config.defaultProvider, 'mock');
    });
  });

  test('defaultApiKeyVar derives a safe env var name', () {
    expect(OnboardingProfile.defaultApiKeyVar('openai'), 'OPENAI_API_KEY');
    expect(OnboardingProfile.defaultApiKeyVar('openai-compat'), 'OPENAI_COMPAT_API_KEY');
    expect(OnboardingProfile.defaultApiKeyVar('zai'), 'ZAI_API_KEY');
  });
}
