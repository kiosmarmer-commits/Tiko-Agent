import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

GenUiSpec _spec(Map<String, dynamic> json) => GenUiSpec.parse(json);

Map<String, dynamic> _actionsSpec(String buttonId) => {
      'type': 'section',
      'title': 'Panel',
      'children': [
        {
          'type': 'actions',
          'buttons': [
            {'id': buttonId, 'label': 'Jalankan'},
          ],
        },
      ],
    };

Map<String, dynamic> _formSpec(String formId) => {
      'type': 'form',
      'id': formId,
      'title': 'Formulir',
      'fields': [
        {'name': 'kota', 'label': 'Kota', 'kind': 'text'},
        {'name': 'jumlah', 'label': 'Jumlah', 'kind': 'number'},
        {
          'name': 'mode',
          'label': 'Mode',
          'kind': 'select',
          'options': ['cepat', 'lambat'],
        },
      ],
    };

void main() {
  test('aksi tombol tervalidasi dan single-use', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_actionsSpec('refresh')));

    final spec = r.validateAndConsume('s1', 'refresh', const {});
    expect(spec.kind, 'button');

    expect(
      () => r.validateAndConsume('s1', 'refresh', const {}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('ownership: aksi sesi lain ditolak', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_actionsSpec('refresh')));

    expect(
      () => r.validateAndConsume('s2', 'refresh', const {}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('expiry: aksi kedaluwarsa ditolak', () {
    final r = GenUiActionRegistry(ttl: const Duration(minutes: 15));
    final rendered = DateTime.now().subtract(const Duration(minutes: 16));
    r.register('s1', _spec(_actionsSpec('refresh')), now: rendered);

    expect(
      () => r.validateAndConsume('s1', 'refresh', const {}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('render ulang action id sama mengaktifkan ulang (latest wins)', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_actionsSpec('refresh')));
    r.validateAndConsume('s1', 'refresh', const {});
    r.register('s1', _spec(_actionsSpec('refresh')));

    expect(r.validateAndConsume('s1', 'refresh', const {}).kind, 'button');
  });

  test('form: nilai valid diterima, field tak dikenal ditolak', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_formSpec('setup')));

    final spec = r.validateAndConsume('s1', 'setup', {
      'kota': 'Bandung',
      'jumlah': '12',
      'mode': 'cepat',
    });
    expect(spec.kind, 'form');
    expect(spec.fields, hasLength(3));

    r.register('s1', _spec(_formSpec('setup')));
    expect(
      () => r.validateAndConsume('s1', 'setup', {'hacker': 'x'}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('form: number non-numerik dan select di luar opsi ditolak', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_formSpec('setup')));

    expect(
      () => r.validateAndConsume('s1', 'setup', {'jumlah': 'bukan angka'}),
      throwsA(isA<GenUiActionRejected>()),
    );

    r.register('s1', _spec(_formSpec('setup')));
    expect(
      () => r.validateAndConsume('s1', 'setup', {'mode': 'ditipu'}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('tombol polos menolak nilai form', () {
    final r = GenUiActionRegistry();
    r.register('s1', _spec(_actionsSpec('refresh')));

    expect(
      () => r.validateAndConsume('s1', 'refresh', {'x': 'y'}),
      throwsA(isA<GenUiActionRejected>()),
    );
  });

  test('aksi dari blok genui dalam teks chat terdaftar', () {
    final r = GenUiActionRegistry();
    final text = 'Berikut panelnya:\n\n```genui\n'
        '{"type":"actions","buttons":[{"id":"go","label":"Go"}]}\n'
        '```\n';
    for (final block in extractGenUiBlocks(text)) {
      r.register('s1', block.spec);
    }

    expect(r.validateAndConsume('s1', 'go', const {}).kind, 'button');
  });
}
