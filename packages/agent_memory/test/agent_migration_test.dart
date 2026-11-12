import 'dart:convert';
import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  group('parsers', () {
    test('parseClaudeCodeJsonl pairs user and assistant turns', () {
      final jsonl = [
        {'type': 'summary', 'summary': 'x'},
        {
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'jelaskan RRF'},
            ],
          },
          'timestamp': '2026-11-10T08:00:00Z',
        },
        {
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Reciprocal Rank Fusion...'},
            ],
          },
          'timestamp': '2026-11-10T08:00:05Z',
        },
      ].map(jsonEncode).join('\n');

      final exchanges = AgentMigration.parseClaudeCodeJsonl(jsonl);
      expect(exchanges, hasLength(1));
      expect(exchanges.first.userText, 'jelaskan RRF');
      expect(exchanges.first.assistantText, 'Reciprocal Rank Fusion...');
      expect(exchanges.first.timestamp, isNotNull);
    });

    test('parseChatGptExport linearizes mapping by create_time', () {
      final content = jsonEncode([
        {
          'title': 't',
          'mapping': {
            'a': {
              'message': {
                'author': {'role': 'user'},
                'content': {'parts': ['hai']},
                'create_time': 1700000000.0,
              },
            },
            'b': {
              'message': {
                'author': {'role': 'assistant'},
                'content': {'parts': ['halo!', null]},
                'create_time': 1700000001.0,
              },
            },
          },
        },
      ]);
      final exchanges = AgentMigration.parseChatGptExport(content);
      expect(exchanges, hasLength(1));
      expect(exchanges.first.userText, 'hai');
      expect(exchanges.first.assistantText, 'halo!');
    });

    test('parseGenericJson accepts role/content and pair shapes', () {
      final roleShape = jsonEncode([
        {'role': 'user', 'content': 'satu'},
        {'role': 'assistant', 'content': 'dua'},
      ]);
      expect(AgentMigration.parseGenericJson(roleShape), hasLength(1));
      final pairShape = jsonEncode([
        {'user': 'tiga', 'assistant': 'empat'},
      ]);
      final pairs = AgentMigration.parseGenericJson(pairShape);
      expect(pairs, hasLength(1));
      expect(pairs.first.userText, 'tiga');
      expect(pairs.first.assistantText, 'empat');
    });

    test('detectFormat recognizes jsonl, chatgpt and generic', () {
      expect(
        AgentMigration.detectFormat('a.jsonl', '{}'),
        'claude_code',
      );
      expect(
        AgentMigration.detectFormat(
          'x.json',
          jsonEncode([
            {'mapping': {}},
          ]),
        ),
        'chatgpt',
      );
      expect(
        AgentMigration.detectFormat(
          'x.json',
          jsonEncode([
            {'role': 'user', 'content': 'x'},
          ]),
        ),
        'generic',
      );
    });
  });

  group('import', () {
    test('importFile writes searchable facts into the store', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_migrate');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/session.jsonl');
      await file.writeAsString([
        jsonEncode({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': 'preferensi deploy saya pagi hari',
          },
        }),
        jsonEncode({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': 'dicatat.',
          },
        }),
      ].join('\n'));

      final store = InMemoryStore();
      final report = await AgentMigration(store: store)
          .importFile(file.path, ownerKey: 'u1');
      expect(report.imported, 1);
      expect(report.source, 'claude_code');

      final hits = await store.search('deploy', k: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.text, contains('deploy'));
    });

    test('importFile throws on missing file', () async {
      final store = InMemoryStore();
      await expectLater(
        AgentMigration(store: store).importFile('/nonexistent/x.jsonl'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
