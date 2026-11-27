// Hermes fase-12: file safety (`agent/file_safety.py`) — guard tulis/baca/
// cari untuk file kredensial, env rahasia, dan state runtime `.tiko/`.
// Defense-in-depth: denial jelas + jejak audit, bukan security boundary.
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final session = Session(id: 's', channel: 'cli', userKey: 'u1');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko_filesafety_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  ToolContext ctx() => ToolContext(session: session, workspacePath: tmp.path);

  group('Aturan basename (Hermes is_project_env_basename + kredensial)', () {
    test('env rahasia diblokir exact-set, case-insensitive', () {
      expect(isProjectEnvBasename('.env'), isTrue);
      expect(isProjectEnvBasename('.env.local'), isTrue);
      expect(isProjectEnvBasename('.ENV.Production'), isTrue);
      expect(isProjectEnvBasename('.envrc'), isTrue);
    });

    test('.env.example adalah substitusi ber-dokumentasi — TIDAK diblokir', () {
      expect(isProjectEnvBasename('.env.example'), isFalse);
      expect(readBlockError('config/.env.example'), isNull);
      expect(writeDenial('config/.env.example'), isNull);
    });

    test('material kunci & store kredensial sensitif; .pub tidak', () {
      expect(isSensitiveBasename('server.pem'), isTrue);
      expect(isSensitiveBasename('id_rsa'), isTrue);
      expect(isSensitiveBasename('id_ed25519.pub'), isFalse);
      expect(isSensitiveBasename('auth.json'), isTrue);
      expect(isSensitiveBasename('token_cache.json'), isTrue);
      expect(isSensitiveBasename('gateway.env'), isTrue);
      expect(isSensitiveBasename('README.md'), isFalse);
      expect(isSensitiveBasename('main.dart'), isFalse);
    });

    test('writeDenial/readBlockError: pesan jelas berisi path', () {
      expect(writeDenial('config/.env'), contains('Write denied'));
      expect(writeDenial('config/.env'), contains('config/.env'));
      expect(readBlockError('secrets/auth.json'), contains('Read denied'));
      expect(writeDenial('.tiko/usage_anchor/x.json'), contains('.tiko'));
      expect(writeDenial('src/app.dart'), isNull);
      expect(readBlockError('src/app.dart'), isNull);
    });
  });

  group('Wiring tool', () {
    test('write_file menolak .env dan path .tiko/ (denial, bukan tulis)',
        () async {
      final tool = WriteFileTool(workspaceRoot: tmp.path);
      final r1 = await tool.run(
        {'path': '.env', 'content': 'API_KEY=x'},
        ctx(),
      );
      expect(r1.isError, isTrue);
      expect(r1.content, contains('Write denied'));
      expect(File('${tmp.path}/.env').existsSync(), isFalse);

      final r2 = await tool.run(
        {'path': '.tiko/usage_anchor/x.json', 'content': '{}'},
        ctx(),
      );
      expect(r2.isError, isTrue);
      expect(r2.content, contains('.tiko'));

      final r3 = await tool.run(
        {'path': 'src/app.dart', 'content': 'void main() {}'},
        ctx(),
      );
      expect(r3.isError, isFalse);
    });

    test('patch_file menolak file sensitif', () async {
      File('${tmp.path}/gateway.env').writeAsStringSync('A=1');
      final tool = PatchFileTool(workspaceRoot: tmp.path);
      final r = await tool.run(
        {'path': 'gateway.env', 'old': 'A=1', 'new': 'A=2'},
        ctx(),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('Write denied'));
      expect(File('${tmp.path}/gateway.env').readAsStringSync(), 'A=1');
    });

    test('read_file memblokir env rahasia & kredensial; .env.example lolos',
        () async {
      File('${tmp.path}/.env').writeAsStringSync('SECRET=1');
      File('${tmp.path}/.env.example').writeAsStringSync('SECRET=\n');
      final tool = ReadFileTool(workspaceRoot: tmp.path);
      final r1 = await tool.run({'path': '.env'}, ctx());
      expect(r1.isError, isTrue);
      expect(r1.content, contains('Read denied'));
      final r2 = await tool.run({'path': 'config/auth.json'}, ctx());
      expect(r2.isError, isTrue);
      final r3 = await tool.run({'path': '.env.example'}, ctx());
      expect(r3.isError, isFalse);
    });

    test('grep tidak pernah memindai file sensitif', () async {
      File('${tmp.path}/.env').writeAsStringSync('SECRET_TOKEN=s3cr3t\n');
      File('${tmp.path}/kunci.pem').writeAsStringSync('PRIVATE s3cr3t\n');
      File('${tmp.path}/app.dart').writeAsStringSync('var token = "publik";\n');
      final tool = GrepTool(workspaceRoot: tmp.path);
      final r = await tool.run({'pattern': 's3cr3t|token'}, ctx());
      expect(r.isError, isFalse);
      expect(r.content, isNot(contains('.env')));
      expect(r.content, isNot(contains('kunci.pem')));
      expect(r.content, contains('app.dart'));
    });
  });
}
