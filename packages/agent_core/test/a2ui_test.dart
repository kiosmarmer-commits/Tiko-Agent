import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

const validEnvelope = {
  'version': '1.0',
  'createSurface': {
    'surfaceId': 's-test-1',
    'components': [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['m1', 'b1'],
      },
      {
        'id': 'm1',
        'component': 'Metric',
        'label': 'CPU',
        'value': '87%',
        'delta': 3,
      },
      {
        'id': 'b1',
        'component': 'Button',
        'label': 'Jalankan pemeriksaan',
        'action': {'name': 'run_diag', 'payload': {'target': 'cpu'}},
      },
    ],
  },
};

void main() {
  group('parseA2uiMessages', () {
    test('menerima envelope tunggal (objek)', () {
      final msgs = parseA2uiMessages(validEnvelope);
      expect(msgs, hasLength(1));
      expect(msgs.single, isA<A2uiCreateSurface>());
    });

    test('menerima JSON array', () {
      final msgs = parseA2uiMessages([validEnvelope]);
      expect(msgs.single, isA<A2uiCreateSurface>());
    });

    test('menerima JSONL multi-baris', () {
      final jsonl = [
        jsonEncode(validEnvelope),
        jsonEncode({
          'version': '1.0',
          'updateDataModel': {
            'surfaceId': 's-test-1',
            'path': '/cpu',
            'value': 91,
          },
        }),
        jsonEncode({
          'version': '1.0',
          'deleteSurface': {'surfaceId': 's-test-1'},
        }),
      ].join('\n');
      final msgs = parseA2uiMessages(jsonl);
      expect(msgs, hasLength(3));
      expect(msgs[0], isA<A2uiCreateSurface>());
      expect(msgs[1], isA<A2uiUpdateDataModel>());
      expect(msgs[2], isA<A2uiDeleteSurface>());
    });

    test('menolak versi selain 1.0', () {
      expect(
        () => parseA2uiMessages({
          'version': '0.9',
          'deleteSurface': {'surfaceId': 'x'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak pesan RPC fungsi dua arah (belum didukung)', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'callRendererFunction': {
            'functionCallId': 'c1',
            'callFunction': {
              '@call': 'openUrl',
              'catalogId': 'tiko.basic.v1',
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak kunci pesan tidak dikenal', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'surfaceUpdate': {'surfaceId': 'x'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak envelope tanpa kunci pesan', () {
      expect(
        () => parseA2uiMessages({'version': '1.0'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak kunci body belum didukung (sendDataModel)', () {
      expect(
        () => parseA2uiMessages({
              'version': '1.0',
              'createSurface': {
                'surfaceId': 's1',
                'sendDataModel': true,
                'components': [
                  {'id': 'root', 'component': 'Divider'},
                ],
              },
            }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak tipe komponen di luar whitelist', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {'id': 'root', 'component': 'Video', 'src': 'x'},
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('createSurface wajib punya root', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {'id': 'c1', 'component': 'Divider'},
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak component.id duplikat dalam pesan', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {'id': 'root', 'component': 'Divider'},
              {'id': 'root', 'component': 'Divider'},
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak action.name di luar regex', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {
                'id': 'root',
                'component': 'Button',
                'label': 'Go',
                'action': {'name': 'Bad Action'},
              },
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak kunci properti tak dikenal', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {
                'id': 'root',
                'component': 'Text',
                'text': 'hi',
                'onclick': 'javascript:alert(1)',
              },
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak teks melebihi batas karakter', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {'id': 'root', 'component': 'Text', 'text': 'a' * 4001},
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('Image.src hanya https/http atau file://data/uploads', () {
      const build = (String src) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's1',
              'components': [
                {'id': 'root', 'component': 'Image', 'src': src},
              ],
            },
          };
      expect(() => parseA2uiMessages(build('data/secret.txt')),
          throwsA(isA<FormatException>()));
      expect(() => parseA2uiMessages(build('file:///etc/passwd')),
          throwsA(isA<FormatException>()));
      expect(parseA2uiMessages(build('file://data/uploads/pic.png')),
          isNotEmpty);
      expect(parseA2uiMessages(build('https://a.co/p.png')), isNotEmpty);
    });

    test('menolak jumlah pesan melebihi limit per panggilan', () {
      final many = [
        for (var i = 0; i < 25; i++)
          {
            'version': '1.0',
            'deleteSurface': {'surfaceId': 's$i'},
          },
      ];
      expect(
        () => parseA2uiMessages(many),
        throwsA(isA<FormatException>()),
      );
    });

    test('katalog tak dikenal ditolak', () {
      expect(
        () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'catalogId': 'random.catalog',
            'components': [
              {'id': 'root', 'component': 'Divider'},
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('A2uiSurfaceSet', () {
    test('urutan create->update->data->delete valid', () {
      final set = A2uiSurfaceSet();
      final changes = set.apply(parseA2uiMessages([
        validEnvelope,
        {
          'version': '1.0',
          'updateDataModel': {
            'surfaceId': 's-test-1',
            'path': '/cpu/load',
            'value': 91,
          },
        },
      ]));
      expect(
        changes.map((c) => c.event),
        everyElement(anyOf('surface.created', 'surface.updated')),
      );
      final surface = set.surface('s-test-1')!;
      expect(surface.dataModel['cpu'], {'load': 91});
      expect(surface.components, hasLength(3));
      expect(
        surface.components['b1']!.action!.name,
        'run_diag',
      );
    });

    test('menolak create ganda pada surfaceId sama', () {
      final set = A2uiSurfaceSet();
      set.apply(parseA2uiMessages(validEnvelope));
      expect(
        () => set.apply(parseA2uiMessages(validEnvelope)),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak update/delete pada surface yang belum dibuat', () {
      final set = A2uiSurfaceSet();
      expect(
        () => set.apply(parseA2uiMessages({
          'version': '1.0',
          'deleteSurface': {'surfaceId': 'nope'},
        })),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => set.apply(parseA2uiMessages({
          'version': '1.0',
          'updateComponents': {
            'surfaceId': 'nope',
            'components': [
              {'id': 'root', 'component': 'Divider'},
            ],
          },
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak children yang merujuk id tidak ada', () {
      final set = A2uiSurfaceSet();
      expect(
        () => set.apply(parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': [
              {
                'id': 'root',
                'component': 'Column',
                'children': ['ghost'],
              },
            ],
          },
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak siklus children', () {
      final set = A2uiSurfaceSet();
      final raw = {
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's1',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['a'],
            },
            {
              'id': 'a',
              'component': 'Column',
              'children': ['root'],
            },
          ],
        },
      };
      expect(
        () => set.apply(parseA2uiMessages(raw)),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak kedalaman melebihi 8 saat apply', () {
      final components = [
        for (var i = 0; i < 8; i++)
          {
            'id': 'root',
            'component': 'Column',
            'children': [
              'c1',
              for (var j = 1; j < 10; j++) 'c$j',
            ],
          },
      ];
      // rantai linear sedalam 9 level lewat parsing, ditolak saat apply.
      final chain = [
        for (var i = 0; i < 8; i++)
          {
            'id': i == 0 ? 'root' : 'c$i',
            'component': 'Column',
            'child': i == 7 ? 'leaf' : 'c${i + 1}',
          },
        {'id': 'leaf', 'component': 'Divider'},
      ];
      final set = A2uiSurfaceSet();
      expect(
        () => set.apply(parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's1',
            'components': chain,
          },
        })),
        throwsA(isA<FormatException>()),
      );
      expect(components, isNotEmpty);
    });

    test('menolak surface melebihi maksimum per sesi', () {
      final set = A2uiSurfaceSet(maxSurfaces: 2);
      set.apply(parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's1',
          'components': [
            {'id': 'root', 'component': 'Divider'},
          ],
        },
      }));
      set.apply(parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's2',
          'components': [
            {'id': 'root', 'component': 'Divider'},
          ],
        },
      }));
      expect(
        () => set.apply(parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's3',
            'components': [
              {'id': 'root', 'component': 'Divider'},
            ],
          },
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('consumeAction anti-replay: satu pakai, lalu ditolak', () {
      final set = A2uiSurfaceSet();
      set.apply(parseA2uiMessages(validEnvelope));
      expect(set.consumeAction('s-test-1', 'run_diag'), isTrue);
      expect(set.consumeAction('s-test-1', 'run_diag'), isFalse);
      expect(set.consumeAction('s-test-1', 'lain'), isFalse);
      set.apply(parseA2uiMessages({
        'version': '1.0',
        'updateComponents': {
          'surfaceId': 's-test-1',
          'components': [
            {
              'id': 'b1',
              'component': 'Button',
              'label': 'Jalankan pemeriksaan',
              'action': {'name': 'run_diag'},
            },
          ],
        },
      }));
      expect(set.consumeAction('s-test-1', 'run_diag'), isTrue);
    });

    test('setelah delete, surface hilang dan create boleh lagi', () {
      final set = A2uiSurfaceSet();
      set.apply(parseA2uiMessages(validEnvelope));
      set.apply(parseA2uiMessages({
        'version': '1.0',
        'deleteSurface': {'surfaceId': 's-test-1'},
      }));
      expect(set.surface('s-test-1'), isNull);
      expect(() => set.apply(parseA2uiMessages(validEnvelope)), returnsNormally);
    });
  });

  group('extractA2uiBlocks', () {
    test('mengekstrak blok a2ui dari teks campuran', () {
      final text = 'Status sistem:\n\`\`\`a2ui\n'
          '${jsonEncode(validEnvelope)}\n'
          '```\nSelesai.';
      final blocks = extractA2uiBlocks(text);
      expect(blocks, hasLength(1));
      expect(blocks.first.messages, hasLength(1));
    });

    test('menerima info string a2ui v1', () {
      final text = '\`\`\`a2ui v1\n'
          '${jsonEncode(validEnvelope)}\n```';
      expect(extractA2uiBlocks(text), hasLength(1));
    });

    test('blok tidak valid dibiarkan sebagai teks', () {
      final text = '\`\`\`a2ui\nbukan json\n```';
      expect(extractA2uiBlocks(text), isEmpty);
    });

    test('blok melebihi 24KiB diabaikan', () {
      final big = {
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's1',
          'components': [
            {'id': 'root', 'component': 'Text', 'text': 'x' * 25000},
          ],
        },
      };
      final text = '\`\`\`a2ui\n${jsonEncode(big)}\n```';
      expect(extractA2uiBlocks(text), isEmpty);
    });

    test('splitA2uiSegments memisahkan teks dan pesan', () {
      final text = 'sebelum\n\`\`\`a2ui\n'
          '${jsonEncode(validEnvelope)}\n```\nsesudah';
      final segs = splitA2uiSegments(text);
      expect(segs, hasLength(3));
      expect(segs[0], isA<String>());
      expect(segs[1], isA<List<A2uiMessage>>());
      expect(segs[2], isA<String>());
    });
  });

  test('toJson roundtrip mempertahankan pesan', () {
    final msgs = parseA2uiMessages(validEnvelope);
    final json = jsonEncode(msgs.map((m) => m.toJson()).toList());
    final reparsed = parseA2uiMessages(json);
    expect(reparsed.single, isA<A2uiCreateSurface>());
    final create = reparsed.single as A2uiCreateSurface;
    expect(create.components.map((c) => c.id), containsAll(['root', 'm1', 'b1']));
  });

  test('system prompt addon menyebut protokol dan whitelist', () {
    final prompt = tikoA2uiSystemPromptAddon();
    expect(prompt, contains('render_a2ui'));
    expect(prompt, contains('createSurface'));
    expect(prompt, contains('Metric'));
  });
}
