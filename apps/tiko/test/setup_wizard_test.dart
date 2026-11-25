import 'dart:io';

import 'package:agent_providers/agent_providers.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tiko/setup_wizard.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:tiko_tui/tiko_tui.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('setup-wizard-test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String configPath() => path.join(tempDir.path, 'config.yaml');
  String dataDir() => path.join(tempDir.path, 'data');
  String envBody() =>
      File(path.join(dataDir(), 'gateway.env')).readAsStringSync();

  PromptRunner scripted(List<String> lines, StringBuffer out) =>
      PromptRunner(scriptedLines: lines, out: out);

  SetupWizardDeps fakeDeps() {
    return SetupWizardDeps(
      probe: ({required providerType, baseUrl, apiKey}) async =>
          const ProbeOutcome(ok: true, detail: 'ok', probed: false),
      probeOllama: () async => null,
      checkDependencies: (commands) async => [
        for (final command in commands)
          DependencyReport(command: command, found: command == 'git'),
      ],
    );
  }

  group('Hermes S10 — wizard onboarding terpandu', () {
    test('jalur mock: ringkasan + simpan ber-revisi, security auto', () async {
      final out = StringBuffer();
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(['', '', '', '', '', '', '', '', 'y'], out),
        environment: const {},
        deps: fakeDeps(),
        out: out,
      );
      expect(code, 0, reason: out.toString());
      final config = File(configPath()).readAsStringSync();
      expect(config, contains('type: "mock"'));
      expect(config, contains('mode: "auto"'));
      expect(out.toString(), contains('Mock (tanpa jaringan)'));
      expect(out.toString(), contains('dependency lokal'));
      expect(File(path.join(dataDir(), 'gateway.env')).existsSync(), isTrue);
    });

    test('env OPENAI_API_KEY terdeteksi: pakai dari environment, model live',
        () async {
      final out = StringBuffer();
      String? probedKey;
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(
          ['', '', 'y', '', '', '', '', '', '', '', 'y'],
          out,
        ),
        environment: const {'OPENAI_API_KEY': 'sk-top-secret'},
        deps: SetupWizardDeps(
          probe: ({required providerType, baseUrl, apiKey}) async {
            probedKey = apiKey;
            return const ProbeOutcome(
              ok: true,
              detail: 'endpoint merespons — 2 model',
              models: ['m-alpha', 'm-beta'],
            );
          },
          probeOllama: () async => null,
          checkDependencies: (commands) async =>
              [for (final c in commands) DependencyReport(command: c, found: true)],
        ),
        out: out,
      );
      expect(code, 0, reason: out.toString());
      expect(probedKey, 'sk-top-secret');
      final config = File(configPath()).readAsStringSync();
      expect(config, contains('type: "openai"'));
      expect(config, contains('api_key: "env:OPENAI_API_KEY"'));
      expect(config, contains('model: "m-alpha"'));
      expect(config, contains('mode: "guided"'));
      expect(envBody(), isNot(contains('sk-top-secret')));
      expect(
        out.toString(),
        contains('API key terdeteksi di env OPENAI_API_KEY'),
      );
    });

    test('probe gagal → isi model manual & lewati test (recovery langkah 2)',
        () async {
      final out = StringBuffer();
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(
          ['', '', 'n', 'sk-typed', '2', '', '', '', '', '', '', '', 'y'],
          out,
        ),
        environment: const {'OPENAI_API_KEY': 'sk-luar'},
        deps: SetupWizardDeps(
          probe: ({required providerType, baseUrl, apiKey}) async =>
              const ProbeOutcome(
                ok: false,
                detail: 'HTTP 401 — periksa API key provider ini',
              ),
          probeOllama: () async => null,
          checkDependencies: (commands) async =>
              [for (final c in commands) DependencyReport(command: c, found: false)],
        ),
        out: out,
      );
      expect(code, 0, reason: out.toString());
      final config = File(configPath()).readAsStringSync();
      expect(config, contains('type: "openai"'));
      expect(config, contains('env:OPENAI_API_KEY'));
      expect(envBody(), contains('OPENAI_API_KEY=sk-typed'));
      expect(out.toString(), contains('HTTP 401'));
      expect(out.toString(), contains('tidak ditemukan'));
    });

    test('probe gagal → pilih batal → tidak ada config baru', () async {
      final out = StringBuffer();
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(['', '', 'y', '4'], out),
        environment: const {'OPENAI_API_KEY': 'sk-x'},
        deps: SetupWizardDeps(
          probe: ({required providerType, baseUrl, apiKey}) async =>
              const ProbeOutcome(
                ok: false,
                detail: 'timeout menghubungi OpenAI',
              ),
          probeOllama: () async => null,
          checkDependencies: (commands) async =>
              [for (final c in commands) DependencyReport(command: c, found: true)],
        ),
        out: out,
      );
      expect(code, 1, reason: out.toString());
      expect(File(configPath()).existsSync(), isFalse);
    });

    test('config invalid di awal → recovery revisi terakhir', () async {
      final config = File(configPath());
      await config.parent.create(recursive: true);
      final goodYaml = OnboardingWizard.renderConfigYaml(
        OnboardingProfile(providerType: 'mock', workspace: '.'),
      );
      final store = ConfigStore(
        configPath: configPath(),
        revisionsDir: path.join(dataDir(), 'config_revisions'),
      );
      await store.ensure();
      await store.writeFull(goodYaml, note: 'setup awal');
      await config.writeAsString('[1, 2, 3]\n');

      final out = StringBuffer();
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(['1'], out),
        environment: const {},
        deps: fakeDeps(),
        out: out,
      );
      expect(code, 1, reason: 'wizard selesai di jalur pemulihan');
      final (recovered, issues) = TikoConfig.load(configPath());
      expect(issues.where((i) => i.fatal), isEmpty, reason: issues.join('\n'));
      expect(recovered.defaultProvider, 'mock');
      expect(out.toString(), contains('Pulihkan dari revisi terakhir'));
      expect(out.toString(), contains('config pulih dari revisi'));
    });

    test('workspace baru dibuat otomatis saat direktori belum ada', () async {
      final workDir = path.join(tempDir.path, 'ws-baru');
      final out = StringBuffer();
      final code = await runSetupWizard(
        configPath: configPath(),
        force: false,
        prompts: scripted(
          ['', '', '', workDir, 'y', '', '', '', '', 'y'],
          out,
        ),
        environment: const {},
        deps: fakeDeps(),
        out: out,
      );
      expect(code, 0, reason: out.toString());
      expect(
        Directory(workDir).existsSync(),
        isTrue,
        reason: 'workspace harus dibuat wizard',
      );
      expect(out.toString(), contains('direktori dibuat'));
    });
  });
}
