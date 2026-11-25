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
              {'id': 'root', 'component': 'Iframe', 'src': 'x'},
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

    test('Chart kind area|donut diterima, kind asing ditolak', () {
      Map<String, Object> chart(String kind) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-ch',
              'components': [
                {
                  'id': 'root',
                  'component': 'Chart',
                  'kind': kind,
                  'points': [
                    {'label': 'L1', 'value': 10},
                    {'label': 'L2', 'value': 24},
                  ],
                },
              ],
            },
          };
      expect(parseA2uiMessages(chart('area')), isNotEmpty);
      expect(parseA2uiMessages(chart('donut')), isNotEmpty);
      expect(
        () => parseA2uiMessages(chart('waterfall')),
        throwsA(isA<FormatException>()),
      );
    });

    test('Chart katalog lanjutan: pie|scatter|hbar diterima', () {
      Map<String, Object> chart(String kind) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-ch2',
              'components': [
                {
                  'id': 'root',
                  'component': 'Chart',
                  'kind': kind,
                  'points': [
                    {'label': 'L1', 'value': 10},
                    {'label': 'L2', 'value': 24},
                  ],
                },
              ],
            },
          };
      expect(parseA2uiMessages(chart('pie')), isNotEmpty);
      expect(parseA2uiMessages(chart('scatter')), isNotEmpty);
      expect(parseA2uiMessages(chart('hbar')), isNotEmpty);
    });

    test('Video: src http/file + poster diterima, kunci asing ditolak', () {
      Map<String, Object> video(Map<String, Object> props) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-video',
              'components': [
                {
                  'id': 'root',
                  'component': 'Video',
                  ...props,
                },
              ],
            },
          };
      expect(
        parseA2uiMessages(video({
          'src': 'https://example.com/a.mp4',
          'poster': 'file://data/uploads/p.png',
        })),
        isNotEmpty,
      );
      expect(
        () => parseA2uiMessages(video({'src': 'ftp://example.com/a.mp4'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(video({
          'src': 'https://example.com/a.mp4',
          'autoplay': true,
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('AudioPlayer: src + loop boolean', () {
      Map<String, Object> audio(Map<String, Object> props) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-audio',
              'components': [
                {
                  'id': 'root',
                  'component': 'AudioPlayer',
                  ...props,
                },
              ],
            },
          };
      expect(
        parseA2uiMessages(audio({
          'src': 'file://data/uploads/ringtone.mp3',
          'loop': true,
        })),
        isNotEmpty,
      );
      expect(
        () => parseA2uiMessages(audio({'src': 'javascript:alert(1)'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(audio({'src': 'x.mp3', 'loop': 'yes'})),
        throwsA(isA<FormatException>()),
      );
    });

    test('ApprovalSheet: risk/summary/commands valid diterima, tak valid ditolak', () {
      Map<String, Object> sheet(Map<String, Object> props) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-appr',
              'components': [
                {'id': 'root', 'component': 'ApprovalSheet', ...props},
              ],
            },
          };
      expect(
        parseA2uiMessages(sheet({
          'risk': 'high',
          'summary': 'Hapus 3 kontainer produksi',
          'commands': ['docker rm -f a', 'docker rm -f b'],
        })),
        isNotEmpty,
      );
      expect(
        () => parseA2uiMessages(sheet({'risk': 'extreme'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(sheet({
          'risk': 'low',
          'commands': [for (var i = 0; i < 9; i++) 'x'],
        })),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(sheet({
          'risk': 'low',
          'commands': ['cek${String.fromCharCode(1)}null'],
        })),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(sheet({
          'risk': 'low',
          'summary': {'otomatis': true},
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('Image.src hanya https/http atau file://data/uploads', () {
      Map<String, Object> build(String src) => {
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

    test('includeStreaming: fence belum tertutup jadi blok complete:false', () {
      final text = 'teks\n\`\`\`a2ui\n'
          '{"version":"1.0","createSurface":{"surfaceId":"s-stream",'
          '"components":[{"id":"root","component":"Division"}]}}';
      expect(extractA2uiBlocks(text), isEmpty);
      final streaming = extractA2uiBlocks(text, includeStreaming: true);
      expect(streaming, hasLength(1));
      expect(streaming.first.complete, isFalse);
      expect(streaming.first.messages, isEmpty);
      expect(streaming.first.end, text.length);

      final segs = splitA2uiSegments(text, includeStreaming: true);
      expect(segs, hasLength(2));
      expect(segs[1], isA<A2uiBlock>());
    });

    test('fence streaming melebihi 24KiB tetap diabaikan', () {
      final text = '\`\`\`a2ui\n${'x' * 25000}';
      expect(extractA2uiBlocks(text, includeStreaming: true), isEmpty);
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
    expect(prompt, contains('ApprovalSheet'));
    expect(prompt, contains('open_url'));
  });

  test('system prompt addon menyebut konvensi penargetan halaman GUI (Hermes S8)', () {
    final prompt = tikoA2uiSystemPromptAddon();
    expect(prompt, contains('page.<halaman>.'));
    for (final page in ['tasks', 'bots', 'automation', 'runs', 'skills', 'security']) {
      expect(prompt, contains(page));
    }
  });

  group('A2uiOpenUrlPolicy', () {
    test('allowlist kosong menolak semua URL (fail-closed)', () {
      final p = A2uiOpenUrlPolicy();
      expect(p.allows('https://example.com'), isFalse);
      expect(p.allows('https://docs.example.com/api'), isFalse);
    });

    test('hanya skema https dan host yang cocok persis', () {
      final p = A2uiOpenUrlPolicy(allow: ['docs.example.com']);
      expect(p.allows('https://docs.example.com'), isTrue);
      expect(p.allows('https://docs.example.com/a/path?q=1#x'), isTrue);
      expect(p.allows('http://docs.example.com'), isFalse);
      expect(p.allows('ftp://docs.example.com'), isFalse);
      expect(p.allows('https://example.com'), isFalse);
      expect(p.allows('https://docs.example.com.evil.io'), isFalse);
      expect(p.allows('not a url'), isFalse);
    });

    test('entri https://host/path memakai prefix path', () {
      final p = A2uiOpenUrlPolicy(allow: ['https://example.com/docs']);
      expect(p.allows('https://example.com/docs'), isTrue);
      expect(p.allows('https://example.com/docs/guide'), isTrue);
      expect(p.allows('https://example.com/docsrole'), isFalse);
      expect(p.allows('https://example.com/'), isFalse);
    });

    test('entri path kosong atau "/" berarti seluruh host', () {
      final p = A2uiOpenUrlPolicy(allow: ['https://example.com/']);
      expect(p.allows('https://example.com/etc/passwd?x=1#f'), isTrue);
    });

    test('entri wildcard *.host hanya mencocokkan subdomain', () {
      final p = A2uiOpenUrlPolicy(allow: ['*.example.com']);
      expect(p.allows('https://example.com'), isFalse);
      expect(p.allows('https://example.com/etc/passwd'), isFalse);
      expect(p.allows('https://a.example.com'), isTrue);
      expect(p.allows('https://b.c.example.com/stuff'), isTrue);
      expect(p.allows('https://sub.example.com.evil.com'), isFalse);
    });

    test('menolak userinfo dan port selain 443', () {
      final p = A2uiOpenUrlPolicy(allow: ['example.com']);
      expect(p.allows('https://user:pass@example.com'), isFalse);
      expect(p.allows('https://user@example.com'), isFalse);
      expect(p.allows('https://user:pass@example.com'), isFalse);
      expect(p.allows('https://example.com:443'), isTrue);
    });

    test('entri tidak valid diabaikan', () {
      final p = A2uiOpenUrlPolicy(allow: [
        'no-scheme://x',
        'http://a.example.com',
        '*star.example.com',
        'example.com:8443',
        '  ',
      ]);
      expect(p.allows('https://example.com'), isFalse);
    });

    test('port eksplisit 443 pada entri diterima', () {
      final p = A2uiOpenUrlPolicy(allow: ['example.com:443']);
      expect(p.allows('https://example.com'), isTrue);
    });
  });

  group('A2uiSurfaceSet form input (Fase E6)', () {
    final formMessages = () => parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's-form',
            'components': [
              {
                'id': 'root',
                'component': 'Column',
                'children': ['f1', 's1', 'b1'],
              },
              {
                'id': 'f1',
                'component': 'TextField',
                'label': 'Nama',
                'value': {'@path': '/form/name'},
                'action': {'name': 'form_changed'},
              },
              {
                'id': 's1',
                'component': 'Slider',
                'label': 'Rating',
                'action': {'name': 'rating_changed'},
              },
              {
                'id': 'b1',
                'component': 'Button',
                'label': 'Kirim',
                'action': {'name': 'submit_form'},
              },
            ],
          },
        });

    test('aksi input repeatable; aksi tombol sekali pakai', () {
      final set = A2uiSurfaceSet()..apply(formMessages());
      expect(set.consumeAction('s-form', 'form_changed'), isTrue);
      expect(set.consumeAction('s-form', 'form_changed'), isTrue);
      expect(set.consumeAction('s-form', 'rating_changed'), isTrue);
      expect(set.consumeAction('s-form', 'rating_changed'), isTrue);
      expect(set.consumeAction('s-form', 'submit_form'), isTrue);
      expect(set.consumeAction('s-form', 'submit_form'), isFalse);
    });

    test('nama yang dipakai tombol tidak jadi repeatable', () {
      final msgs = parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's-mix',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['f1', 'b1'],
            },
            {
              'id': 'f1',
              'component': 'TextField',
              'label': 'A',
              'action': {'name': 'double_use'},
            },
            {
              'id': 'b1',
              'component': 'Button',
              'label': 'B',
              'action': {'name': 'double_use'},
            },
          ],
        },
      });
      final set = A2uiSurfaceSet()..apply(msgs);
      expect(set.consumeAction('s-mix', 'double_use'), isTrue);
      expect(set.consumeAction('s-mix', 'double_use'), isFalse);
    });

    test('inputTargetOf membaca binding @path + aksi onChanged', () {
      final set = A2uiSurfaceSet()..apply(formMessages());
      final t = set.inputTargetOf('s-form', 'f1');
      expect(t, isNotNull);
      expect(t!.type, 'TextField');
      expect(t.boundPath, '/form/name');
      expect(t.actionName, 'form_changed');
      expect(set.inputTargetOf('s-form', 'b1'), isNull);
      expect(set.inputTargetOf('s-tidak-ada', 'f1'), isNull);
    });

    test('List & Tabs diterima; labels wajib sejumlah children', () {
      final msgs = parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's-tabs',
          'components': [
            {
              'id': 'root',
              'component': 'Tabs',
              'labels': ['Ringkas', 'Detail'],
              'children': ['p1', 'p2'],
            },
            {
              'id': 'p1',
              'component': 'List',
              'children': ['t1', 't2'],
            },
            {'id': 't1', 'component': 'Text', 'text': 'satuuuu1'},
            {'id': 't2', 'component': 'Text', 'text': 'duaaaa'},
            {
              'id': 'p2',
              'component': 'List',
              'axis': 'horizontal',
              'children': ['t1'],
            },
          ],
        },
      });
      final set = A2uiSurfaceSet();
      expect(set.apply(msgs), isNotEmpty);

      expect(
        () => A2uiSurfaceSet().apply(parseA2uiMessages({
              'version': '1.0',
              'createSurface': {
                'surfaceId': 's-bad',
                'components': [
                  {
                    'id': 'root',
                    'component': 'Tabs',
                    'labels': ['satu'],
                    'children': ['p1', 'p2'],
                  },
                  {'id': 'p1', 'component': 'Card'},
                  {'id': 'p2', 'component': 'Card'},
                ],
              },
            })),
        throwsA(isA<FormatException>()),
      );
    });

    test('Tabs labels divalidasi (kosong, non-string, >8 tab)', () {
      Map<String, dynamic> env(List<dynamic> labels) => {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 's-lbl',
              'components': [
                {
                  'id': 'root',
                  'component': 'Tabs',
                  'labels': labels,
                  'children': ['p1'],
                },
                {'id': 'p1', 'component': 'Card'},
              ],
            },
          };
      expect(
        () => parseA2uiMessages(env([])),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(env([1, 2])),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseA2uiMessages(env(List.generate(9, (i) => 't$i'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('Modal diterima; wajib minimal satu children dan properti whitelist', () {
      final msgs = parseA2uiMessages({
        'version': '1.0',
        'createSurface': {
          'surfaceId': 's-modal',
          'components': [
            {
              'id': 'root',
              'component': 'Modal',
              'title': 'Rincian langkah',
              'children': ['t1'],
            },
            {'id': 't1', 'component': 'Text', 'text': 'isi modal'},
          ],
        },
      });
      final set = A2uiSurfaceSet();
      expect(set.apply(msgs), isNotEmpty);

      expect(
        () => A2uiSurfaceSet().apply(parseA2uiMessages({
              'version': '1.0',
              'createSurface': {
                'surfaceId': 's-modal-kosong',
                'components': [
                  {'id': 'root', 'component': 'Modal', 'title': 'kosong'},
                ],
              },
            })),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => A2uiSurfaceSet().apply(parseA2uiMessages({
              'version': '1.0',
              'createSurface': {
                'surfaceId': 's-modal-prop',
                'components': [
                  {
                    'id': 'root',
                    'component': 'Modal',
                    'title': 'x',
                    'open': true,
                    'children': ['t1'],
                  },
                  {'id': 't1', 'component': 'Card'},
                ],
              },
            })),
        throwsA(isA<FormatException>()),
      );
    });

    test('writeInputValue menulis data model via @path', () {
      final set = A2uiSurfaceSet()..apply(formMessages());
      final path = set.writeInputValue('s-form', 'f1', 'Budi');
      expect(path, '/form/name');
      expect(set.surface('s-form')!.dataModel['form']['name'], 'Budi');
    });

    test('writeInputValue tanpa binding @path tetap tervalidasi, tanpa tulis',
        () {
      final set = A2uiSurfaceSet()..apply(formMessages());
      expect(set.writeInputValue('s-form', 's1', 4), isNull);
      expect(
        () => set.writeInputValue('s-form', 's1', 'bukan angka'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => set.writeInputValue('s-form', 'f1', 42),
        throwsA(isA<FormatException>()),
      );
    });

    test('writeInputValue menolak komponen bukan input & nilai berkontrol',
        () {
      final set = A2uiSurfaceSet()..apply(formMessages());
      expect(
        () => set.writeInputValue('s-form', 'b1', 'x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => set.writeInputValue('s-form', 'f1', 'baris\x01'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
