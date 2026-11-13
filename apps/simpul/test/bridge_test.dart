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
}
