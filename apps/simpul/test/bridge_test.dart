import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simpul/simpul.dart';
import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-bridge-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/catatan').create(recursive: true);
    await File('$vault/catatan/satu.md').writeAsString(
      '---\ntitle: Satu\n---\n# Satu\n\nisi tentang jaringan saraf tiruan\n',
    );
    await File('$vault/catatan/dua.md').writeAsString(
      '---\ntitle: Dua\n---\nlihat [[satu]]\n',
    );
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<Map<String, Object?>> request(
    SimpulBridge bridge,
    String method, [
    Map<String, Object?>? params,
    Object? id = 1,
  ]) async {
    final response = await bridge.handleLine(
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params}),
    );
    expect(response, isNotEmpty);
    return jsonDecode(response) as Map<String, Object?>;
  }

  test('initialize handshake and tools/list', () async {
    final bridge = SimpulBridge(vaultDir: vault);
    final init = await request(bridge, 'initialize', {
      'protocolVersion': '2024-11-05',
      'clientInfo': {'name': 'test', 'version': '0'},
    });
    final result = init['result'] as Map<String, Object?>;
    expect((result['serverInfo'] as Map)['name'], 'simpul-bridge');

    final tools = await request(bridge, 'tools/list');
    final names = [
      for (final t in (tools['result'] as Map)['tools'] as List) (t as Map)['name'],
    ];
    expect(
      names,
      containsAll(['search', 'semsearch', 'health', 'backlinks', 'read_note', 'clusters', 'suggest_links']),
    );
  });

  test('search, backlinks, and health over tools/call', () async {
    final bridge = SimpulBridge(vaultDir: vault);

    final search = await request(bridge, 'tools/call', {
      'name': 'search',
      'arguments': {'query': 'saraf'},
    });
    final searchText = jsonDecode(
      ((search['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect((searchText['hits'] as List).single['path'], 'catatan/satu.md');

    final backlinks = await request(bridge, 'tools/call', {
      'name': 'backlinks',
      'arguments': {'path': 'catatan/satu.md'},
    });
    final backlinksText = jsonDecode(
      ((backlinks['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(backlinksText['backlinks'], ['catatan/dua.md']);

    final health = await request(bridge, 'tools/call', {'name': 'health'});
    final healthText = jsonDecode(
      ((health['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(healthText['note_count'], 2);
  });

  test('read_note rejects path traversal and serves in-vault files', () async {
    final bridge = SimpulBridge(vaultDir: vault);

    final escape = await request(bridge, 'tools/call', {
      'name': 'read_note',
      'arguments': {'path': '../../etc/passwd'},
    });
    expect((escape['result'] as Map)['isError'], isTrue);

    final ok = await request(bridge, 'tools/call', {
      'name': 'read_note',
      'arguments': {'path': 'catatan/satu.md'},
    });
    final text = jsonDecode(
      ((ok['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['content'], contains('jaringan saraf'));
  });

  test('unknown tool and unknown method fail cleanly', () async {
    final bridge = SimpulBridge(vaultDir: vault);
    final badTool = await request(bridge, 'tools/call', {'name': 'nope'});
    expect((badTool['result'] as Map)['isError'], isTrue);

    final badMethod = await request(bridge, 'no/such/method');
    expect((badMethod['error'] as Map)['code'], -32601);
  });

  test('token is enforced fail-closed when configured', () async {
    final bridge = SimpulBridge(vaultDir: vault, token: 's3cret');
    final denied = await request(bridge, 'tools/list');
    expect((denied['error'] as Map)['code'], -32001);

    final allowed = await request(bridge, 'tools/list', {
      '_meta': {'token': 's3cret'},
    });
    expect(allowed.containsKey('result'), isTrue);
  });

  test('notifications and invalid json produce no fatal error', () async {
    final bridge = SimpulBridge(vaultDir: vault);
    expect(
      await bridge.handleLine(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      ),
      '',
    );
    final bad = await bridge.handleLine('bukan json');
    expect((jsonDecode(bad) as Map)['id'], isNull);
  });

  test('serve process speaks MCP over stdio', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/simpul.dart', 'serve', vault],
      workingDirectory: Directory.current.path,
    );
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final reader = StreamIterator(lines);
    try {
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
      }));
      expect(await reader.moveNext(), isTrue);
      final init = jsonDecode(reader.current) as Map<String, Object?>;
      expect(((init['result'] as Map)['serverInfo'] as Map)['name'], 'simpul-bridge');

      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'search',
          'arguments': {'query': 'saraf'},
        },
      }));
      expect(await reader.moveNext(), isTrue);
      final search = jsonDecode(reader.current) as Map<String, Object?>;
      final text = jsonDecode(
        ((search['result'] as Map)['content'] as List).first['text'] as String,
      ) as Map<String, Object?>;
      expect((text['hits'] as List).single['path'], 'catatan/satu.md');
    } finally {
      process.kill();
    }
  });

  test('folder deny rule filters search hits and reports filtered count', () async {
    await Directory('$vault/rahasia').create(recursive: true);
    await File('$vault/rahasia/kunci.md').writeAsString(
      '---\ntitle: Kunci\n---\nkunci rahasia bank\n',
    );
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync(
      jsonEncode({
        'folders': {'rahasia': 'tolak'},
      }),
    );
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'search',
      'arguments': {'query': 'kunci'},
    });
    final text = jsonDecode(
      ((response['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['hits'], isEmpty);
    expect(text['filtered'], greaterThanOrEqualTo(1));
  });

  test('read_note refuses denied notes and writes an audit line', () async {
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync(
      jsonEncode({
        'notes': {'catatan/satu.md': 'tolak'},
      }),
    );
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'read_note',
      'arguments': {'path': 'catatan/satu.md'},
    });
    final result = response['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect(
      (result['content'] as List).first['text'],
      contains('akses ditolak kebijakan AI'),
    );
    final entries = [
      for (final line in File('$vault/.simpul/ai-audit.jsonl').readAsLinesSync())
        jsonDecode(line) as Map<String, Object?>,
    ];
    expect(
      entries.any((e) => e['tool'] == 'read_note' && e['decision'] == 'deny'),
      isTrue,
    );
  });

  test('ask status is refused in headless tooling', () async {
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync(
      jsonEncode({
        'notes': {'catatan/satu.md': 'tanya'},
      }),
    );
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'read_note',
      'arguments': {'path': 'catatan/satu.md'},
    });
    final result = response['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect(
      (result['content'] as List).first['text'],
      contains('persetujuan manusia'),
    );
    final entries = [
      for (final line in File('$vault/.simpul/ai-audit.jsonl').readAsLinesSync())
        jsonDecode(line) as Map<String, Object?>,
    ];
    expect(entries.any((e) => e['decision'] == 'ask'), isTrue);
  });

  test('tag deny rules filter search hits through index tagsOf', () async {
    await File('$vault/catatan/tiga.md').writeAsString(
      '---\ntitle: Tiga\ntags: [pribadi]\n---\ncatatan pribadi keluarga\n',
    );
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync(
      jsonEncode({
        'tags': {'pribadi': 'tolak'},
      }),
    );
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'search',
      'arguments': {'query': 'pribadi'},
    });
    final text = jsonDecode(
      ((response['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['hits'], isEmpty);
    expect(text['filtered'], 1);
  });

  test('corrupt permission config fails closed to deny-all', () async {
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync('{bukan json');
    final bridge = SimpulBridge(vaultDir: vault);

    final read = await request(bridge, 'tools/call', {
      'name': 'read_note',
      'arguments': {'path': 'catatan/satu.md'},
    });
    expect((read['result'] as Map)['isError'], isTrue);

    final search = await request(bridge, 'tools/call', {
      'name': 'search',
      'arguments': {'query': 'saraf'},
    });
    final text = jsonDecode(
      ((search['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['hits'], isEmpty);
    expect(text['filtered'], 1);
  });

  test('ask_vault answers extractively with citations from the vault', () async {
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'ask_vault',
      'arguments': {'query': 'saraf'},
    });
    final text = jsonDecode(
      ((response['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['mode'], 'extractive');
    final citations = text['citations'] as List;
    expect(citations, isNotEmpty);
    expect((citations.first as Map)['path'], 'catatan/satu.md');
  });

  test('ask_vault answers not_found when every citation is denied', () async {
    File('$vault/.simpul/ai-permissions.json').writeAsStringSync(
      jsonEncode({
        'notes': {'catatan/satu.md': 'tolak'},
      }),
    );
    final bridge = SimpulBridge(vaultDir: vault);
    final response = await request(bridge, 'tools/call', {
      'name': 'ask_vault',
      'arguments': {'query': 'saraf'},
    });
    final text = jsonDecode(
      ((response['result'] as Map)['content'] as List).first['text'] as String,
    ) as Map<String, Object?>;
    expect(text['mode'], 'not_found');
    expect(text['citations'], isEmpty);
    expect(text['filtered'], 1);
  });
}
