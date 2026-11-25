import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('onboarding-assist');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('securityMode pada OnboardingProfile', () {
    test('mode dipilih dirender ke config.yaml', () {
      final yaml = OnboardingWizard.renderConfigYaml(
        OnboardingProfile(
          providerType: 'mock',
          workspace: '.',
          securityMode: 'guided',
        ),
      );
      expect(yaml, contains('mode: guided'));
      final (_, issues) = TikoConfig.parse(yaml);
      expect(issues.where((i) => i.fatal), isEmpty, reason: issues.join('\n'));
    });

    test('mode bawaan ask tetap berlaku', () {
      final yaml = OnboardingWizard.renderConfigYaml(
        OnboardingProfile(providerType: 'mock', workspace: '.'),
      );
      expect(yaml, contains('mode: ask'));
    });

    test('mode di luar nilai valid ditolak', () {
      expect(
        () => OnboardingProfile(
          providerType: 'mock',
          workspace: '.',
          securityMode: 'yolo',
        ),
        throwsA(
          isA<Error>().having(
            (e) => '$e',
            'pesan',
            contains('securityMode harus auto|guided|ask|deny'),
          ),
        ),
      );
    });
  });

  group('OnboardingAssist.checkDependencies', () {
    test('tool ada dan tidak ada dilaporkan berurutan', () async {
      final reports = await OnboardingAssist.checkDependencies(
        ['git', 'tool-yang-tentu-tidak-ada'],
        locate: (command) async =>
            command == 'git' ? (found: true, detail: '/usr/bin/git') : null,
      );
      expect(reports, hasLength(2));
      expect(reports[0].command, 'git');
      expect(reports[0].found, isTrue);
      expect(reports[0].detail, '/usr/bin/git');
      expect(reports[1].found, isFalse);
      expect(reports[1].detail, isNull);
    });
  });

  group('OnboardingRecovery.verifyAndRecover', () {
    String configPath() => '${tempDir.path}/config.yaml';
    String revisionsDir() => '${tempDir.path}/data/config_revisions';

    test('config valid → tidak ada rollback', () async {
      final report = await OnboardingRecovery.verifyAndRecover(
        configPath: configPath(),
        revisionsDir: revisionsDir(),
      );
      expect(report.ok, isTrue);
      expect(report.rolledBackTo, isNull);
    });

    test('config korup → rollback ke revisi valid terakhir', () async {
      final goodYaml = OnboardingWizard.renderConfigYaml(
        OnboardingProfile(providerType: 'mock', workspace: '.'),
      );
      final store = ConfigStore(
        configPath: configPath(),
        revisionsDir: revisionsDir(),
      );
      await store.ensure();
      final written = await store.writeFull(goodYaml, note: 'setup');
      expect(written.issues.where((i) => i.fatal), isEmpty);

      await File(configPath()).writeAsString('{ bukan: [yaml');

      final report = await OnboardingRecovery.verifyAndRecover(
        configPath: configPath(),
        revisionsDir: revisionsDir(),
      );
      expect(report.ok, isTrue, reason: report.detail);
      expect(report.rolledBackTo, written.revision);
      final (recovered, issues) = TikoConfig.load(configPath());
      expect(issues.where((i) => i.fatal), isEmpty, reason: issues.join('\n'));
      expect(recovered.defaultProvider, 'mock');
      expect(recovered.workspace, '.');
    });

    test('tanpa revisi valid → laporan gagal tanpa melempar', () async {
      final config = File(configPath());
      await config.parent.create(recursive: true);
      await config.writeAsString('[1, 2, 3]\n');
      final report = await OnboardingRecovery.verifyAndRecover(
        configPath: configPath(),
        revisionsDir: revisionsDir(),
      );
      expect(report.ok, isFalse);
      expect(report.detail, contains('tidak ada revisi valid'));
    });
  });
}
