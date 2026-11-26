import 'dart:convert';
import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String storePath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_rescue_test');
    storePath = '${tmp.path}/sessions.json';
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('persist gagal → snapshot dituangkan ke rescue JSONL', () async {
    // Target persist adalah directory → rename atomic pasti gagal.
    final blocked = Directory(storePath);
    blocked.createSync(recursive: true);

    final store = FileSessionStore(path: storePath);
    final s = await store.getOrCreate(
      'sess-1',
      channel: 'cli',
      userKey: 'u1',
    );
    await store.appendTurn(
      'sess-1',
      user: 'halo',
      assistant: 'ini jawaban penting yang tidak boleh hilang',
    );
    expect(s.id, 'sess-1');

    final rescue = File('$storePath.rescue.jsonl');
    expect(rescue.existsSync(), isTrue);
    final lines = rescue.readAsLinesSync().where((l) => l.trim().isNotEmpty);
    expect(lines, isNotEmpty);
    expect(lines.last, contains('ini jawaban penting'));
  });

  test('store utama hilang → sesi dipulihkan dari rescue file', () async {
    final blocked = Directory(storePath);
    blocked.createSync(recursive: true);
    final store = FileSessionStore(path: storePath);
    await store.getOrCreate('sess-rescue', channel: 'cli', userKey: 'u1');
    await store.appendTurn(
      'sess-rescue',
      user: 'pertanyaan',
      assistant: 'jawaban terselamatkan',
    );
    expect(
      File('$storePath.rescue.jsonl').existsSync(),
      isTrue,
    );

    // Hapus "penyebab" kegagalan dan buka store baru di path yang sama.
    blocked.deleteSync();
    final recovered = FileSessionStore(path: storePath);
    final info = await recovered.get('sess-rescue');
    expect(info, isNotNull);
    final recent = await recovered.recent('sess-rescue');
    expect(recent.map((m) => m.content), contains('jawaban terselamatkan'));
  });

  test('sesi yang sudah ada di store utama tidak ditimpa rescue', () async {
    // Store utama valid berisi sess-main; rescue berisi sess-main versi lama
    // + sess-lain yang hilang.
    final main = File(storePath);
    main.writeAsStringSync(
      '{"version":1,"sessions":{"sess-main":{"channel":"cli","user":"u1",'
      '"title":"utama","summary":null,"pinned":false,"archived":false,'
      '"last_failed":false,"created_at":"2026-11-26T00:00:00.000Z",'
      '"updated_at":"2026-11-26T01:00:00.000Z","turns":2,"messages":'
      '[{"role":"user","content":"baru"}]}}}',
    );
    File('$storePath.rescue.jsonl').writeAsStringSync(
      '{"at":"2026-11-26T00:30:00.000Z","pid":1,"snapshot":"${'{"version":1,'
      '"sessions":{"sess-main":{"channel":"cli","user":"u1","title":"lama",'
      '"summary":null,"pinned":false,"archived":false,"last_failed":false,'
      '"created_at":"2026-11-26T00:00:00.000Z","updated_at":'
      '"2026-11-26T00:30:00.000Z","turns":1,"messages":[]},'
      '"sess-lain":{"channel":"cli","user":"u1","title":null,"summary":null,'
      '"pinned":false,"archived":false,"last_failed":false,"created_at":'
      '"2026-11-26T00:00:00.000Z","updated_at":"2026-11-26T00:30:00.000Z",'
      '"turns":1,"messages":[{"role":"assistant","content":"pulihkan saya"}]}}}'
      .replaceAll('"', r'\"')}"}\n',
    );

    final store = FileSessionStore(path: storePath);
    final mainInfo = await store.get('sess-main');
    expect(mainInfo!.turns, 2);
    final recovered = await store.get('sess-lain');
    expect(recovered, isNotNull);
    final msgs = await store.recent('sess-lain');
    expect(msgs.single.content, 'pulihkan saya');
  });

  test('rescue file dibersihkan setelah persist sukses', () async {
    final store = FileSessionStore(path: storePath);
    await store.getOrCreate('sess-clean', channel: 'cli', userKey: 'u1');
    await store.appendTurn(
      'sess-clean',
      user: 'a',
      assistant: 'b',
    );
    // Simulasi rescue lama tertinggal; persist berikutnya harus membersihkan.
    File('$storePath.rescue.jsonl').writeAsStringSync('{"at":"x"}\n');
    await store.appendTurn(
      'sess-clean',
      user: 'c',
      assistant: 'd',
    );
    expect(File('$storePath.rescue.jsonl').existsSync(), isFalse);
  });

  test('baris rescue korup dilewati tanpa menggagalkan pemulihan lain',
      () async {
    final rescue = File('$storePath.rescue.jsonl');
    final snapshot = jsonEncode({
      'version': 1,
      'sessions': {
        'sess-ok': {
          'channel': 'cli',
          'user': 'u1',
          'title': null,
          'summary': null,
          'pinned': false,
          'archived': false,
          'last_failed': false,
          'created_at': '2026-11-26T00:00:00.000Z',
          'updated_at': '2026-11-26T00:00:00.000Z',
          'turns': 1,
          'messages': [
            {'role': 'assistant', 'content': 'masih ada'},
          ],
        },
      },
    });
    rescue.writeAsStringSync([
      'ini baris korup {{{',
      jsonEncode({
        'at': '2026-11-26T00:00:00.000Z',
        'pid': 1,
        'snapshot': snapshot,
      }),
      '',
    ].join('\n'));

    final store = FileSessionStore(path: storePath);
    final info = await store.get('sess-ok');
    expect(info, isNotNull);
    expect((await store.recent('sess-ok')).single.content, 'masih ada');
  });
}
