import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('GenUiSpec.parse — tipe valid', () {
    test('semua tipe node diterima dan round-trip toJson', () {
      final spec = GenUiSpec.parse({
        'type': 'section',
        'title': 'Laporan',
        'children': [
          {'type': 'text', 'text': 'Ringkasan', 'style': 'heading'},
          {'type': 'metric', 'label': 'Pendapatan', 'value': 1200, 'delta': 3.5},
          {
            'type': 'chart',
            'chart': 'line',
            'points': [
              {'label': 'Sen', 'value': 1},
              {'label': 'Sel', 'value': 2},
            ],
          },
          {
            'type': 'form',
            'id': 'f1',
            'title': 'Isi data',
            'fields': [
              {'name': 'nama', 'label': 'Nama', 'kind': 'text'},
              {'name': 'usia', 'label': 'Usia', 'kind': 'number', 'initial': 20},
              {
                'name': 'paket',
                'label': 'Paket',
                'kind': 'select',
                'options': ['A', 'B'],
              },
            ],
          },
          {
            'type': 'actions',
            'buttons': [
              {'id': 'ok', 'label': 'Setuju'},
              {'id': 'hapus', 'label': 'Hapus', 'style': 'danger'},
            ],
          },
          {'type': 'divider'},
        ],
      });
      expect(spec.nodeCount, 7);
      expect(spec.root.type, 'section');
      final round = GenUiSpec.parse(spec.toJson());
      expect(round.nodeCount, spec.nodeCount);
    });

    test('parse dari string JSON juga diterima', () {
      final spec = GenUiSpec.parse('{"type":"divider"}');
      expect(spec.root.type, 'divider');
    });

    test('tryParse mengembalikan null untuk tidak valid', () {
      expect(GenUiSpec.tryParse({'type': 'webview'}), isNull);
      expect(GenUiSpec.tryParse('bukan json'), isNull);
    });
  });

  group('GenUiSpec.parse — fail-closed', () {
    test('tipe tidak dikenal ditolak', () {
      expect(() => GenUiSpec.parse({'type': 'webview'}),
          throwsA(isA<FormatException>()));
      expect(() => GenUiSpec.parse({'type': 'iframe', 'src': 'http://x'}),
          throwsA(isA<FormatException>()));
      expect(() => GenUiSpec.parse({}), throwsA(isA<FormatException>()));
    });

    test('kunci tak dikenal ditolak (tidak ada pintu side-channel)', () {
      expect(
        () => GenUiSpec.parse({
          'type': 'text',
          'text': 'halo',
          'onTap': 'eval()',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('identifier tidak aman ditolak', () {
      expect(
        () => GenUiSpec.parse({
          'type': 'form',
          'id': 'bad id; drop table',
          'fields': [
            {'name': 'a', 'label': 'A'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'actions',
          'buttons': [
            {'id': 'a\nb', 'label': 'X'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('karakter kontrol ditolak', () {
      expect(
        () => GenUiSpec.parse({'type': 'text', 'text': 'a\x00b'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('batas depth dan jumlah node', () {
      // Depth: sarang section 9 kali -> ditolak.
      Map<String, dynamic> nested(int n) {
        var node = <String, dynamic>{'type': 'divider'};
        for (var i = 0; i < n; i++) {
          node = {
            'type': 'section',
            'title': 'L$i',
            'children': [node],
          };
        }
        return node;
      }

      expect(() => GenUiSpec.parse(nested(9)), throwsA(isA<FormatException>()));
      expect(() => GenUiSpec.parse(nested(7)), returnsNormally);

      // Node: rantai section, tiap level 19 divider + section berikut
      // (children <= 20). 5 level = 5 section + 95 divider = 100 node -> lulus;
      // 6 level = 120 node -> ditolak.
      Map<String, dynamic> chain(int levels) {
        var node = <String, dynamic>{
          'type': 'section',
          'title': 'L${levels - 1}',
          'children': [
            for (var i = 0; i < 19; i++) {'type': 'divider'},
          ],
        };
        for (var l = levels - 2; l >= 0; l--) {
          node = {
            'type': 'section',
            'title': 'L$l',
            'children': [
              for (var i = 0; i < 19; i++) {'type': 'divider'},
              node,
            ],
          };
        }
        return node;
      }

      expect(() => GenUiSpec.parse(chain(6)),
          throwsA(isA<FormatException>()));
      final exact = GenUiSpec.parse(chain(5));
      expect(exact.nodeCount, 100);
    });

    test('batas panjang string, titik chart, field, opsi, tombol', () {
      expect(
        () => GenUiSpec.parse({'type': 'text', 'text': 'a' * 2001}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'chart',
          'points': [
            for (var i = 0; i < 32; i++)
              {'label': 'p$i', 'value': i},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'form',
          'id': 'f',
          'fields': [
            for (var i = 0; i < 9; i++)
              {'name': 'f$i', 'label': 'F$i'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'form',
          'id': 'f',
          'fields': [
            {
              'name': 's',
              'label': 'S',
              'kind': 'select',
              'options': [for (var i = 0; i < 17; i++) 'o$i'],
            },
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'actions',
          'buttons': [
            for (var i = 0; i < 5; i++)
              {'id': 'b$i', 'label': 'B$i'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('field.name duplikat dan button.id duplikat ditolak', () {
      expect(
        () => GenUiSpec.parse({
          'type': 'form',
          'id': 'f',
          'fields': [
            {'name': 'a', 'label': 'A'},
            {'name': 'a', 'label': 'A2'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'actions',
          'buttons': [
            {'id': 'x', 'label': 'A'},
            {'id': 'x', 'label': 'B'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('select tanpa options dan point.value non-angka ditolak', () {
      expect(
        () => GenUiSpec.parse({
          'type': 'form',
          'id': 'f',
          'fields': [
            {'name': 's', 'label': 'S', 'kind': 'select'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GenUiSpec.parse({
          'type': 'chart',
          'points': [
            {'label': 'a', 'value': 'banyak'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('extractGenUiBlocks / splitGenUiSegments', () {
    test('blok genui diekstrak, blok kode biasa tidak', () {
      final text = 'Ini penjelasan.\n\n```genui\n{"type": "divider"}\n```\n\n'
          '```dart\nvoid main() {}\n```\nSelesai.';
      final blocks = extractGenUiBlocks(text);
      expect(blocks, hasLength(1));
      expect(blocks.first.spec.root.type, 'divider');
      final segments = splitGenUiSegments(text);
      expect(segments.whereType<GenUiSpec>(), hasLength(1));
      expect(segments.whereType<String>().join(), contains('```dart'));
    });

    test('JSON tidak valid di blok genui dibiarkan sebagai teks', () {
      final text = '```genui\n{"type": "tidak_ada"}\n```';
      expect(extractGenUiBlocks(text), isEmpty);
      expect(splitGenUiSegments(text), [text]);
    });

    test('fence tak tertutup dibiarkan sebagai teks (fail-closed)', () {
      final text = '```genui\n{"type": "divider"}';
      expect(extractGenUiBlocks(text), isEmpty);
    });

    test('beberapa blok diekstrak berurutan', () {
      final text = 'A\n```genui\n{"type":"divider"}\n```\nB\n'
          '```genui\n{"type":"text","text":"hi"}\n```\nC';
      final segments = splitGenUiSegments(text);
      expect(segments.whereType<GenUiSpec>(), hasLength(2));
      expect(segments.first, 'A\n');
      expect(segments.last, '\nC');
    });
  });

}
