import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Uint8List _chunk(String type, List<int> data) {
  final out = BytesBuilder();
  final len = ByteData(4)..setUint32(0, data.length);
  out.add(len.buffer.asUint8List());
  out.add(latin1.encode(type));
  out.add(data);
  out.add(Uint8List(4));
  return out.toBytes();
}

Uint8List _pngWithCard({
  String? keyword,
  Map<String, dynamic>? card,
  bool includeCard = true,
}) {
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  if (includeCard && card != null) {
    final payload = base64Encode(utf8.encode(jsonEncode(card)));
    out.add(_chunk('tEXt', [...latin1.encode(keyword!), 0, ...latin1.encode(payload)]));
  }
  out.add(_chunk('IEND', const []));
  return out.toBytes();
}

Map<String, dynamic> _v2Card() => {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': 'Kucing Ninja',
        'description': 'Kucing pembunuh senyap.',
        'personality': 'dingin tapi setia',
        'scenario': 'perang klan kucing',
        'system_prompt': 'Jawab singkat.',
        'first_mes': 'Nyaat, aku Kucing Ninja.',
        'tags': ['kucing'],
      },
    };

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
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
  max_iterations: 4
''');
  return config.path;
}

void main() {
  group('CharacterCardImporter.parse', () {
    test('V2: blok data dipakai, persona terkomposisi', () {
      final card = CharacterCardImporter.parse(_v2Card());
      expect(card.id, 'kucing-ninja');
      expect(card.name, 'Kucing Ninja');
      expect(card.persona, contains('Kucing pembunuh senyap.'));
      expect(card.persona, contains('Kepribadian: dingin tapi setia'));
      expect(card.persona, contains('Skenario: perang klan kucing'));
      expect(card.persona, contains('Instruksi sistem: Jawab singkat.'));
      expect(card.greeting, 'Nyaat, aku Kucing Ninja.');
    });

    test('V3: backward-compatible V2', () {
      final json = _v2Card()
        ..['spec'] = 'chara_card_v3'
        ..['spec_version'] = '3.0';
      final card = CharacterCardImporter.parse(json);
      expect(card.id, 'kucing-ninja');
      expect(card.greeting, isNotEmpty);
    });

    test('V1: field langsung di root tanpa wrapper', () {
      final card = CharacterCardImporter.parse({
        'name': 'Robot Baik',
        'description': 'Sahabat manusia.',
        'first_mes': 'Halo!',
      });
      expect(card.id, 'robot-baik');
      expect(card.persona, contains('Sahabat manusia.'));
      expect(card.greeting, 'Halo!');
    });

    test('V2 tanpa blok data -> FormatException', () {
      expect(
        () => CharacterCardImporter.parse({'spec': 'chara_card_v2'}),
        throwsFormatException,
      );
    });

    test('tanpa nama -> FormatException', () {
      expect(
        () => CharacterCardImporter.parse({'description': 'anonim'}),
        throwsFormatException,
      );
    });
  });

  group('CharacterCardImporter.slugify & uniqueId', () {
    late Directory temp;
    late BotStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tiko_card_slug_');
      store = BotStore(dataDir: p.join(temp.path, 'bots'));
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('spasi dan simbol menjadi tanda hubung', () {
      expect(CharacterCardImporter.slugify('Mega Mew -- Duo!'),
          'mega-mew-duo');
    });

    test('kosong menjadi fallback character', () {
      expect(CharacterCardImporter.slugify('!!!'), 'character');
    });

    test('id lebih dari 64 karakter dipotong', () {
      final slug = CharacterCardImporter.slugify('a' * 100);
      expect(slug.length, lessThanOrEqualTo(64));
      expect(BotProfile.isValidId(slug), isTrue);
    });

    test('uniqueId menambah sufiks -2 saat collision', () async {
      await store.create(id: 'kucing-ninja', name: 'pertama');
      expect(CharacterCardImporter.uniqueId(store, 'kucing-ninja'),
          'kucing-ninja-2');
      expect(CharacterCardImporter.uniqueId(store, 'baru'), 'baru');
    });
  });

  group('CharacterCardImporter.fromFile & PNG', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tiko_card_file_');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('file JSON V2 dibaca dan diparse', () async {
      final file = File(p.join(temp.path, 'card.json'));
      await file.writeAsString(jsonEncode(_v2Card()));
      final card = await CharacterCardImporter.fromFile(
        file.path,
        workspaceRoot: temp.path,
      );
      expect(card.id, 'kucing-ninja');
    });

    test('PNG chunk chara (V2) diekstrak', () async {
      final file = File(p.join(temp.path, 'card.png'));
      await file.writeAsBytes(
          _pngWithCard(keyword: 'chara', card: _v2Card()));
      final card = await CharacterCardImporter.fromFile(
        file.path,
        workspaceRoot: temp.path,
      );
      expect(card.id, 'kucing-ninja');
    });

    test('PNG ccv3 diprioritaskan di atas chara', () async {
      final v3 = _v2Card()
        ..['spec'] = 'chara_card_v3'
        ..['data'] = {
          ...(_v2Card()['data'] as Map<String, dynamic>),
          'name': 'Kucing V3',
        };
      final bytes = BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('tEXt', [
          ...latin1.encode('chara'),
          0,
          ...latin1.encode(base64Encode(utf8.encode(jsonEncode(_v2Card())))),
        ]))
        ..add(_chunk('tEXt', [
          ...latin1.encode('ccv3'),
          0,
          ...latin1.encode(base64Encode(utf8.encode(jsonEncode(v3)))),
        ]))
        ..add(_chunk('IEND', const []));
      final file = File(p.join(temp.path, 'card.png'));
      await file.writeAsBytes(bytes.toBytes());
      final card = await CharacterCardImporter.fromFile(
        file.path,
        workspaceRoot: temp.path,
      );
      expect(card.id, 'kucing-v3');
    });

    test('PNG tanpa chunk card -> FormatException', () {
      expect(
        () => CharacterCardImporter.fromPngBytes(
            _pngWithCard(includeCard: false)),
        throwsFormatException,
      );
    });

    test('signature PNG salah -> FormatException', () {
      expect(
        () => CharacterCardImporter.fromPngBytes(
            Uint8List.fromList(List.filled(32, 1))),
        throwsFormatException,
      );
    });

    test('path escape keluar workspace -> ArgumentError', () async {
      await expectLater(
        CharacterCardImporter.fromFile(
          p.join(temp.path, '..', 'card.json'),
          workspaceRoot: temp.path,
        ),
        throwsArgumentError,
      );
    });
  });

  group('/bot import end-to-end', () {
    late Directory temp;
    late String configPath;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tiko_card_e2e_');
      configPath = await _prepare(temp);
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('impor card, tampil di show, dan fail-closed tanpa allowlist',
        () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      final cardFile = File(p.join(temp.path, 'kucing.json'));
      await cardFile.writeAsString(jsonEncode(_v2Card()));

      final imported = await rt.chat('/bot import kucing.json');
      expect(imported, contains('diimpor'));
      expect(imported, contains('fail-closed'));
      expect(imported, contains('/bot allow kucing-ninja'));

      final shown = await rt.chat('/bot show kucing-ninja');
      expect(shown, contains('Kucing Ninja'));
      expect(shown, contains('Kucing pembunuh senyap.'));

      await rt.chat('/bot use kucing-ninja');
      final denied = await rt.chat('halo lewat bot');
      expect(denied, contains('ditolak fail-closed'));
    });

    test('impor ulang card yang sama membuat id unik', () async {
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      final cardFile = File(p.join(temp.path, 'kucing.json'));
      await cardFile.writeAsString(jsonEncode(_v2Card()));

      await rt.chat('/bot import kucing.json');
      final second = await rt.chat('/bot import kucing.json');
      expect(second, contains('kucing-ninja-2'));
    });
  });
}
