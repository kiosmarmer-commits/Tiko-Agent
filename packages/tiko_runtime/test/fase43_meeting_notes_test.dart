import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-meet', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

const _transcript = '''
Andi: Selamat pagi, mari mulai rapat sprint.
Budi: Solusi caching disetujui untuk rilis berikutnya.
Andi: Oke, dicatat sebagai keputusan.
Budi: Saya akan menyiapkan implementasi cache minggu ini.
Citra: Apakah hasil benchmark perlu dilampirkan di PR?
Budi: Ya, lampirkan.
Andi: Tim QA akan menguji regresi setelah merge.
''';

void main() {
  late String workspace;

  setUp(() async {
    workspace =
        await Directory.systemTemp.createTemp('meeting_test').then((d) => d.path);
  });

  tearDown(() async {
    await Directory(workspace).delete(recursive: true);
  });

  test('MEETING-1: parser — peserta, keputusan, tindak lanjut, pertanyaan',
      () {
    final notes = MeetingNotesParser.parse(_transcript, title: 'Sprint Review');
    expect(notes.participants, ['Andi', 'Budi', 'Citra']);
    expect(notes.turnCount, 7);
    expect(notes.decisions, hasLength(2));
    expect(notes.decisions.first, startsWith('Budi:'));
    expect(notes.decisions.first, contains('disetujui'));
    expect(notes.decisions.last, startsWith('Andi:'));
    expect(notes.decisions.last, contains('keputusan'));
    expect(notes.actionItems, hasLength(2));
    expect(notes.actionItems.first, startsWith('Budi —'));
    expect(notes.actionItems.last, startsWith('Tim QA —'));
    expect(notes.openQuestions, hasLength(1));
    expect(notes.openQuestions.single, contains('Citra'));
  });

  test('MEETING-2: baris wrap tanpa speaker mengikuti pembicara sebelumnya',
      () {
    final notes = MeetingNotesParser.parse('''
Budi: Saya akan mengirim laporan
besok pagi setelah benchmark selesai.
''');
    expect(notes.actionItems, hasLength(1));
    expect(notes.actionItems.single, contains('besok pagi'));
  });

  test('MEETING-3: markdown output terstruktur', () {
    final notes = MeetingNotesParser.parse(_transcript, title: 'Sprint');
    final md = notes.toMarkdown();
    expect(md, startsWith('# Notulen: Sprint'));
    expect(md, contains('## Keputusan'));
    expect(md, contains('## Tindak Lanjut'));
    expect(md, contains('## Pertanyaan Terbuka'));
  });

  test('MEETING-4: tool — inline transcript', () async {
    final tool = MeetingNotesTool();
    final result = await tool.run({
      'transcript': _transcript,
      'title': 'Sprint Review',
    }, _ctx(workspace));
    expect(result.isError, isFalse);
    expect(result.content, contains('Budi'));
    expect(result.content, contains('## Tindak Lanjut'));
  });

  test('MEETING-5: tool — path file di workspace + path jail + save',
      () async {
    final file = File('$workspace/transkrip.txt');
    await file.writeAsString(_transcript);
    final tool = MeetingNotesTool();

    final ok = await tool.run({
      'path': 'transkrip.txt',
      'title': 'Sprint',
      'save': true,
    }, _ctx(workspace));
    expect(ok.isError, isFalse);
    expect(ok.content, contains('Tersimpan: meetings'));
    expect(Directory('$workspace/meetings').existsSync(), isTrue);

    final escape = await tool.run({
      'path': '../outside.txt',
    }, _ctx(workspace));
    expect(escape.isError, isTrue);
    expect(escape.content, contains('di dalam workspace'));

    final missing = await tool.run({'path': 'hilang.txt'}, _ctx(workspace));
    expect(missing.isError, isTrue);

    final noSource = await tool.run({}, _ctx(workspace));
    expect(noSource.isError, isTrue);
  });

  test('MEETING-6: json roundtrip notulen', () {
    final notes = MeetingNotesParser.parse(_transcript, title: 'X');
    final parsed = MeetingNotes.fromJson(notes.toJson())!;
    expect(parsed.title, 'X');
    expect(parsed.participants, notes.participants);
    expect(parsed.decisions, notes.decisions);
    expect(parsed.actionItems, notes.actionItems);
    expect(parsed.openQuestions, notes.openQuestions);
    expect(parsed.turnCount, notes.turnCount);
  });
}
