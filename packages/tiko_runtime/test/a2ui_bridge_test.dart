import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final events = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko-a2ui-test');
    events.clear();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  final messages = () => parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's-ui-1',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['m1'],
            },
            {'id': 'm1', 'component': 'Metric', 'label': 'CPU', 'value': '87%'},
          ],
        },
      });

  test('ingest menyimpan snapshot + memancarkan event surface.created',
      () async {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    final changes = bridge.ingest('web:abc', messages());
    expect(changes.single.event, 'surface.created');
    expect(
      events.single,
      'surface.created',
    );
    final file = File(
        '${tmp.path}${Platform.pathSeparator}surfaces${Platform.pathSeparator}'
        'web_abc${Platform.pathSeparator}s-ui-1.json');
    expect(file.existsSync(), isTrue);
    final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(body['surfaceId'], 's-ui-1');
    expect((body['components'] as List), hasLength(2));
  });

  test('list & get membaca snapshot tersimpan', () async {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    bridge.ingest('web:abc', messages());
    expect(bridge.list(), hasLength(1));
    expect(bridge.list('web:abc'), hasLength(1));
    expect(bridge.list('web:other'), isEmpty);
    final got = bridge.get('s-ui-1');
    expect(got, isNotNull);
    expect(got!['sessionKey'], 'web:abc');
    expect(got['dataModel'], isA<Map>());
  });

  test('update memperbarui snapshot + event surface.updated', () {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    bridge.ingest('web:abc', messages());
    bridge.ingest('web:abc', parseA2uiMessages({
      'version': '1.0',
      'updateDataModel': {
        'surfaceId': 's-ui-1',
        'path': '/cpu/load',
        'value': 91,
      },
    }));
    expect(
      [events[0], events[1]],
      ['surface.created', 'surface.updated'],
    );
    expect(bridge.get('s-ui-1')!['dataModel']['cpu'], {'load': 91});
  });

  test('urutan tidak valid → surface.rejected dan tidak mengunci turn', () {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    expect(
      () => bridge.ingest('web:abc', parseA2uiMessages({
        'version': '1.0',
        'deleteSurface': {'surfaceId': 'ghost'},
      })),
      throwsA(isA<FormatException>()),
    );
    expect(events.single['reason'], isNotEmpty);
    expect(bridge.get('ghost'), isNull);
  });

  test('delete menghapus file + event surface.deleted', () async {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    bridge.ingest('web:abc', messages());
    expect(await bridge.delete('s-ui-1'), isTrue);
    expect(await bridge.delete('s-ui-1'), isFalse);
    expect(bridge.list(), isEmpty);
    expect(events.last, 'surface.deleted');
  });

  test('aksi: register lewat ingest lalu consumeAction anti-replay', () {
    final bridge = A2uiToolBridge(dataDir: tmp.path, onEvent: events.add);
    bridge.ingest('web:abc', parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-btn',
        'components': [
          {
            'id': 'root',
            'component': 'Button',
            'label': 'Jalankan',
            'action': {'name': 'run_diag'},
          },
        ],
      },
    }));
    expect(bridge.consumeAction('web:abc', 's-btn', 'run_diag'), isTrue);
    expect(bridge.consumeAction('web:abc', 's-btn', 'run_diag'), isFalse);
  });

  test('TTL: snapshot kadaluarsa dihapus saat prune', () {
    final bridge = A2uiToolBridge(
      dataDir: tmp.path,
      onEvent: events.add,
      ttl: const Duration(microseconds: 1),
    );
    bridge.ingest('web:abc', messages());
    // Prune berjalan pada list berikutnya.
    sleep(const Duration(milliseconds: 5));
    expect(bridge.list(), isEmpty);
  });

  test('LRU: snapshot lebih dari maksimum terbuang (tertua dulu)', () {
    final bridge = A2uiToolBridge(
      dataDir: tmp.path,
      onEvent: events.add,
      maxStored: 2,
    );
    for (var i = 0; i < 3; i++) {
      bridge.ingest('web:abc', parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's$i',
          'components': [
            {'id': 'root', 'component': 'Divider'},
          ],
        },
      }));
    }
    final ids = bridge.list().map((e) => e['surfaceId']).toSet();
    expect(ids, {'s1', 's2'});
  });
}
