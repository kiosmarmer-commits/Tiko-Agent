import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepareRuntime(Directory temp) async {
  final configDir = Directory(p.join(temp.path, 'config'))..createSync();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 2
''');
  return config.path;
}

void main() {
  group('expandContextRefs', () {
    late Directory temp;
    late String ws;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tiko_refs_');
      ws = temp.path;
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('@file diekspansi ke blok context', () async {
      File(p.join(ws, 'catatan.txt')).writeAsStringSync('isi catatan penting');
      final r = await expandContextRefs(
        'Tolong ringkas: @file:catatan.txt',
        workspace: ws,
      );
      expect(r.text, contains('isi catatan penting'));
      expect(r.text, contains('[context: file catatan.txt'));
      expect(r.refs, hasLength(1));
      expect(r.refs.first['status'], 'ok');
      expect(r.refs.first['kind'], 'file');
    });

    test('@file: path keluar workspace/absolut/tidak ada gagal fail-closed',
        () async {
      final r1 = await expandContextRefs(
        'lihat @file:../ralat/escape.txt',
        workspace: ws,
      );
      expect(r1.text, contains('gagal: path tidak boleh keluar workspace'));
      expect(r1.text, isNot(contains('[context: file')));
      expect(r1.refs.first['status'], 'error');

      final r2 = await expandContextRefs(
        'lihat @file:/etc/passwd',
        workspace: ws,
      );
      expect(r2.text, contains('gagal: path absolut tidak diizinkan'));

      final r3 = await expandContextRefs(
        'lihat @file:hilang.txt',
        workspace: ws,
      );
      expect(r3.text, contains('gagal: file tidak ditemukan'));
      expect(r3.text, contains('@file:hilang.txt gagal'));
    });

    test('@file: file biner dan file raksasa ditolak', () async {
      File(p.join(ws, 'biner.bin')).writeAsBytesSync(
        [0x89, 0x50, 0x4e, 0x47, 0x00, 0x01],
      );
      final r1 = await expandContextRefs(
        'baca @file:biner.bin',
        workspace: ws,
      );
      expect(r1.text, contains('gagal: file biner'));

      File(p.join(ws, 'besar.txt')).writeAsStringSync('x' * (64 * 1024 + 1));
      final r2 = await expandContextRefs(
        'baca @file:besar.txt',
        workspace: ws,
      );
      expect(r2.text, contains('gagal: melebihi'));
    });

    test('@folder: listing bounded', () async {
      Directory(p.join(ws, 'mods', 'sub')).createSync(recursive: true);
      File(p.join(ws, 'mods', 'a.dart')).writeAsStringSync('a');
      File(p.join(ws, 'mods', 'sub', 'b.dart')).writeAsStringSync('bb');
      final r = await expandContextRefs('struktur: @folder:mods', workspace: ws);
      expect(r.text, contains('mods/'));
      expect(r.text, contains('a.dart (1 byte)'));
      expect(r.text, contains('sub/b.dart (2 byte)'));
      expect(r.refs.first['status'], 'ok');
    });

    test('@folder: folder tidak ada gagal', () async {
      final r = await expandContextRefs(
        'struktur: @folder:hilang',
        workspace: ws,
      );
      expect(r.text, contains('gagal: folder tidak ditemukan'));
    });

    test('@url: GET teks lokal diekspansi; 404 gagal', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri!.path == '/ok') {
          req.response.headers.contentType = ContentType.text;
          req.response.write('konten dari web');
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      try {
        final r1 = await expandContextRefs(
          'ringkas @url:http://127.0.0.1:${server.port}/ok',
          workspace: ws,
        );
        expect(r1.text, contains('konten dari web'));
        expect(r1.text, contains('[context: url'));
        expect(r1.refs.first['status'], 'ok');

        final r2 = await expandContextRefs(
          'ringkas @url:http://127.0.0.1:${server.port}/nope',
          workspace: ws,
        );
        expect(r2.text, contains('gagal: HTTP 404'));
      } finally {
        await server.close(force: true);
      }
    });

    test('@git-diff: bukan repo git -> marker error eksplisit', () async {
      final r = await expandContextRefs('perubahan: @git-diff', workspace: ws);
      expect(r.text, contains('gagal: bukan repo git atau git gagal'));
      expect(r.refs.first['status'], 'error');
      expect(r.refs.first['kind'], 'git-diff');
    });

    test('@git-diff: repo dengan perubahan diekspansi', () async {
      final wsEnv = <String, String>{
        'GIT_AUTHOR_NAME': 'tiko-test',
        'GIT_AUTHOR_EMAIL': 'tiko@test.invalid',
        'GIT_COMMITTER_NAME': 'tiko-test',
        'GIT_COMMITTER_EMAIL': 'tiko@test.invalid',
        'HOME': ws,
        'PATH': Platform.environment['PATH'] ?? '',
      };
      Future<ProcessResult> git(List<String> args) => Process.run(
            'git',
            args,
            workingDirectory: ws,
            environment: wsEnv,
          );
      await git(['init']);
      File(p.join(ws, 'a.txt')).writeAsStringSync('v1\n');
      await git(['add', '.']);
      await git(['commit', '-m', 'init']);
      File(p.join(ws, 'a.txt')).writeAsStringSync('v2 berubah\n');
      final r = await expandContextRefs('perubahan: @git-diff', workspace: ws);
      expect(r.text, contains('diff --git'));
      expect(r.text, contains('+v2 berubah'));
      expect(r.refs.first['status'], 'ok');
    });

    test('maksimum 8 referensi per pesan', () async {
      for (var i = 0; i < 10; i++) {
        File(p.join(ws, 'f$i.txt')).writeAsStringSync('n$i');
      }
      final r = await expandContextRefs(
        List.generate(10, (i) => '@file:f$i.txt').join(' '),
        workspace: ws,
      );
      final ok = r.refs.where((r) => r['status'] == 'ok');
      final bad = r.refs.where((r) => r['status'] == 'error');
      expect(ok, hasLength(8));
      expect(bad, hasLength(2));
      expect(bad.first['error'], contains('maks 8'));
    });

    test('referensi di dalam code fence tidak diekspansi', () async {
      final r = await expandContextRefs(
        'contoh:\n```\n@file:catatan.txt\n```\n',
        workspace: ws,
      );
      expect(r.refs, isEmpty);
      expect(r.text, contains('@file:catatan.txt'));
      expect(r.text, isNot(contains('[context:')));
    });

    test('pesan tanpa ref @ tidak berubah', () async {
      final r = await expandContextRefs(
        'haloo tiko, apa kabar? email admin@x.com\n',
        workspace: ws,
      );
      expect(r.refs, isEmpty);
      expect(r.text, 'haloo tiko, apa kabar? email admin@x.com\n');
    });
  });

  group('runtime wiring context refs', () {
    test('chat dengan @file memancarkan event context.expanded', () async {
      final temp = Directory.systemTemp.createTempSync('tiko_refs_rt_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final configPath = await _prepareRuntime(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      File(p.join(temp.path, 'notes.txt')).writeAsStringSync('retensi 6 emas');
      final events = <String>[];
      final sub = rt.events.stream.listen((e) => events.add(e.type));

      await rt.chat('tolong bantu cek @file:notes.txt');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, contains('context.expanded'));
      await sub.cancel();
    });

    test('perintah internal (/) tidak mengekspansi refs', () async {
      final temp = Directory.systemTemp.createTempSync('tiko_refs_rt2_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final configPath = await _prepareRuntime(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      final expanded = <int>[];
      final sub = rt.events.stream.listen((e) {
        if (e.type == 'context.expanded') expanded.add(1);
      });

      await rt.chat('/model');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(expanded, isEmpty);
      await sub.cancel();
    });
  });
}
