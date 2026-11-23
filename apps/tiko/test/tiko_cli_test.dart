import 'package:tiko/tiko_cli.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('parseTikoArgs', () {
    test('default tanpa argumen', () {
      final a = parseTikoArgs([]);
      expect(a.configPath, 'config/agent.yaml');
      expect(a.jsonOut, isFalse);
      expect(a.safe, isTrue);
      expect(a.probe, isFalse);
      expect(a.mode, 'auto');
      expect(a.help, isFalse);
      expect(a.rest, isEmpty);
    });

    test('semua opsi global terbaca', () {
      final a = parseTikoArgs([
        '--config',
        '/tmp/agent.yaml',
        '--json',
        '--no-safe',
        '--probe',
        '--mode',
        'embedded',
        'status',
      ]);
      expect(a.configPath, '/tmp/agent.yaml');
      expect(a.jsonOut, isTrue);
      expect(a.safe, isFalse);
      expect(a.probe, isTrue);
      expect(a.mode, 'embedded');
      expect(a.rest, ['status']);
    });

    test('-h/--help menandai help tanpa memasukkan ke rest', () {
      expect(parseTikoArgs(['-h']).help, isTrue);
      expect(parseTikoArgs(['--help']).help, isTrue);
      expect(parseTikoArgs(['-h']).rest, isEmpty);
    });

    test('--mode tanpa nilai jatuh ke rest (perilaku lama dipertahankan)', () {
      final a = parseTikoArgs(['--mode']);
      expect(a.mode, 'auto');
      expect(a.rest, ['--mode']);
    });

    test('urutan posisi argumen dipertahankan', () {
      final a = parseTikoArgs(['config', 'set', 'api.port', '9000']);
      expect(a.rest, ['config', 'set', 'api.port', '9000']);
    });
  });

  group('parseSetupArgs', () {
    test('default', () {
      final s = parseSetupArgs([]);
      expect(s, isNotNull);
      expect(s!.provider, 'mock');
      expect(s.workspace, '.');
      expect(s.force, isFalse);
      expect(s.interactive, isFalse);
    });

    test('semua opsi setup terbaca', () {
      final s = parseSetupArgs([
        '--provider',
        'ollama',
        '--workspace',
        '/tmp/ws',
        '--force',
        '--interactive',
      ]);
      expect(s!.provider, 'ollama');
      expect(s.workspace, '/tmp/ws');
      expect(s.force, isTrue);
      expect(s.interactive, isTrue);
    });

    test('smoke default false dan --smoke mengaktifkan (F1)', () {
      expect(parseSetupArgs([])!.smoke, isFalse);
      final s = parseSetupArgs(['--smoke']);
      expect(s, isNotNull);
      expect(s!.smoke, isTrue);
    });

    test('opsi tak dikenal menghasilkan null + pesan', () {
      final messages = <String>[];
      final s = parseSetupArgs(['--ngasal'], onUnknown: messages.add);
      expect(s, isNull);
      expect(messages.single, contains('--ngasal'));
    });

    test('--provider tanpa nilai dianggap opsi tak dikenal', () {
      final s = parseSetupArgs(['--provider']);
      expect(s, isNull);
    });
  });

  group('getCfg', () {
    late TikoConfig config;

    setUp(() {
      final (parsed, issues) = TikoConfig.parse(
        TikoConfig.setupYaml(provider: 'mock', workspace: '/tmp/ws'),
      );
      expect(issues.where((i) => i.fatal), isEmpty);
      config = parsed;
    });

    test('path yang didukung', () {
      expect(getCfg(config, 'default_provider'), 'mock');
      expect(getCfg(config, 'providers.default'), 'mock');
      expect(getCfg(config, 'workspace'), '/tmp/ws');
      expect(getCfg(config, 'api.port'), '${config.apiPort}');
      expect(getCfg(config, 'data_dir'), config.dataDir);
    });

    test('path tidak dikenal memberi petunjuk', () {
      expect(getCfg(config, 'ngasal'), contains('config show'));
    });
  });

  group('chatCompleter', () {
    test('melengkapi berdasarkan prefiks token', () {
      expect(chatCompleter('/', '/'), chatCommands);
      expect(chatCompleter('/q', '/q'), ['/quit']);
      expect(chatCompleter('/e', '/e'), ['/exit']);
      expect(chatCompleter('/s', '/s'), ['/status', '/settings']);
    });

    test('token tanpa kecocokan kosong', () {
      expect(chatCompleter('/x', '/x'), isEmpty);
    });
  });
}
