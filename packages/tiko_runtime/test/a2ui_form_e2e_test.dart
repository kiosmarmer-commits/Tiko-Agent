import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// E2E alur form A2UI (Fase E6): input user di renderer → kontrak host
/// `POST /v1/ui/actions` (`a2ui_input`) → tulis-balik data model → aksi
/// `onChanged` diteruskan sebagai turn percakapan ke agen.
///
/// Kontrak host (agentd `uiActionHandler`) dipanggil langsung di sini:
/// `runtime.a2ui.applyInput(...)` + teks `'/surface <sid> <aksi> <json>'`
/// via `chatWithStatus` — jalur yang sama tanpa HTTP socket agar test
/// deterministik (pola `approval_e2e_test.dart`).
void main() {
  late Directory temp;
  late TikoRuntime runtime;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_a2ui_form_e2e_');
    final config = File('${temp.path}/agent.yaml');
    await config.writeAsString('''
providers:
  chat:
    mock:
      type: mock
      scenario: assisted
''');
    runtime = await TikoRuntime.create(configPath: config.path);
  });

  tearDown(() async {
    await runtime.events.close();
    await temp.delete(recursive: true);
  });

  const sessionKey = 'e2e:form';

  Future<void> seedFormSurface() async {
    runtime.a2ui.ingest(
      sessionKey,
      parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's-form',
          'components': [
            {
              'id': 'root',
              'component': 'Tabs',
              'labels': ['Ringkas', 'Detail'],
              'children': ['p1', 'p2'],
            },
            {
              'id': 'p1',
              'component': 'Column',
              'children': ['f1', 's1', 'b1'],
            },
            {
              'id': 'f1',
              'component': 'TextField',
              'label': 'Nama',
              'value': {'@path': '/form/nama'},
              'action': {'name': 'form_changed'},
            },
            {
              'id': 's1',
              'component': 'Slider',
              'label': 'Rating',
              'min': 0,
              'max': 10,
              'value': {'@path': '/form/rating'},
              'action': {'name': 'rating_changed'},
            },
            {
              'id': 'b1',
              'component': 'Button',
              'label': 'Kirim',
              'action': {'name': 'submit_form'},
            },
            {
              'id': 'p2',
              'component': 'Card',
              'children': ['m1'],
            },
            {
              'id': 'm1',
              'component': 'Metric',
              'label': 'Rating',
              'value': {'@path': '/form/rating'},
              'delta': 0,
            },
          ],
          'dataModel': {
            'form': {'nama': '', 'rating': 0},
          },
        },
      }),
    );
  }

  test('input → write-back model → aksi onChanged sampai ke turn agen', () async {
    await seedFormSurface();

    expect(
      runtime.a2ui.get('s-form')!['dataModel']['form']['nama'],
      '',
    );

    final result =
        runtime.a2ui.applyInput(sessionKey, 's-form', 'f1', 'Budi');
    expect(result.action, 'form_changed');
    expect(result.path, '/form/nama');
    expect(
      runtime.a2ui.get('s-form')!['dataModel']['form']['nama'],
      'Budi',
    );

    final eval = runtime.a2ui.applyInput(sessionKey, 's-form', 's1', 9);
    expect(eval.action, 'rating_changed');
    expect(eval.path, '/form/rating');
    expect(
      runtime.a2ui.get('s-form')!['dataModel']['form']['rating'],
      9,
    );

    // Aksi tombol tetap sekali pakai; aksi input repeatable.
    expect(runtime.a2ui.consumeAction(sessionKey, 's-form', 'submit_form'),
        isTrue);
    expect(runtime.a2ui.consumeAction(sessionKey, 's-form', 'submit_form'),
        isFalse);
    expect(runtime.a2ui.consumeAction(sessionKey, 's-form', 'form_changed'),
        isTrue);
    expect(runtime.a2ui.consumeAction(sessionKey, 's-form', 'rating_changed'),
        isTrue);

    // Kontrak agentd: teks aksi diteruskan sebagai turn percakapan biasa
    // (mock `assisted` meng-echo teks user → nilai terbukti sampai model).
    final run = await runtime.chatWithStatus(
      '/surface s-form form_changed {"value":"Budi"}',
      sessionId: sessionKey,
      channel: 'http',
      userKey: 'ui-action',
    );
    expect(run.text, contains('form_changed'));
    expect(run.text, contains('"value":"Budi"'));
  });

  test('input pada surface sesi lain / komponen asing ditolak (isolasi)',
      () async {
    await seedFormSurface();
    expect(
      () => runtime.a2ui.applyInput('e2e:lain', 's-form', 'f1', 'X'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => runtime.a2ui.applyInput(sessionKey, 's-form', 'tidak-ada', 'X'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => runtime.a2ui.applyInput(sessionKey, 's-form', 'b1', 'X'),
      throwsA(isA<FormatException>()),
    );
    expect(
      runtime.a2ui.get('s-form')!['dataModel']['form']['nama'],
      '',
    );
  });
}
