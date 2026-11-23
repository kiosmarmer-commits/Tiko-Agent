import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('F8.1 — security profile parsing', () {
    test('default: strict, perilaku lama', () {
      final (cfg, issues) = TikoConfig.parse('');
      expect(cfg.securityProfile, 'strict');
      expect(cfg.permissionMode, 'ask');
      expect(
        cfg.shellAllowlist,
        const ['ls', 'cat', 'git status', 'pwd', 'echo'],
      );
      expect(cfg.riskOverrides, isEmpty);
      expect(issues.where((i) => i.fatal), isEmpty);
    });

    test('standard: guided + allowlist toolchain dev + override', () {
      final (cfg, issues) = TikoConfig.parse('security:\n  profile: standard\n');
      expect(cfg.securityProfile, 'standard');
      expect(cfg.permissionMode, 'guided');
      expect(cfg.shellAllowlist, contains('flutter'));
      expect(cfg.shellAllowlist, contains('dart'));
      expect(cfg.riskOverrides['verify_project'], 'medium');
      expect(issues.where((i) => i.fatal), isEmpty);
    });

    test('trusted_workspace: standard tanpa requireConfirm tambahan', () {
      final (cfg, _) =
          TikoConfig.parse('security:\n  profile: trusted_workspace\n');
      expect(cfg.securityProfile, 'trusted_workspace');
      expect(cfg.permissionMode, 'guided');
      expect(cfg.requireConfirm, isEmpty);
      expect(cfg.riskOverrides['verify_project'], 'medium');
    });

    test('nilai eksplisit selalu menang atas preset', () {
      final (cfg, _) = TikoConfig.parse('''
security:
  profile: standard
  mode: ask
  shell_allowlist: ['ls']
  require_confirm: ['write_file']
  risk_overrides: {verify_project: low}
''');
      expect(cfg.permissionMode, 'ask');
      expect(cfg.shellAllowlist, const ['ls']);
      expect(cfg.requireConfirm, const ['write_file']);
      expect(cfg.riskOverrides['verify_project'], 'low');
    });

    test('profil tidak dikenal -> fallback strict + issue non-fatal', () {
      final (cfg, issues) =
          TikoConfig.parse('security:\n  profile: yolo\n');
      expect(cfg.securityProfile, 'strict');
      expect(cfg.permissionMode, 'ask');
      expect(
        issues.any((i) => i.path == 'security.profile' && !i.fatal),
        isTrue,
      );
    });

    test('risk_overrides tanpa profil tetap dibaca', () {
      final (cfg, _) = TikoConfig.parse(
        'security:\n  risk_overrides: {shell: medium}\n',
      );
      expect(cfg.riskOverrides['shell'], 'medium');
    });

    test('risk_overrides label tidak valid -> issue + entri diabaikan', () {
      final (cfg, issues) = TikoConfig.parse(
        'security:\n  risk_overrides: {shell: yolo}\n',
      );
      expect(cfg.riskOverrides, isEmpty);
      expect(
        issues.any((i) => i.path == 'security.risk_overrides.shell'),
        isTrue,
      );
    });
  });
}
