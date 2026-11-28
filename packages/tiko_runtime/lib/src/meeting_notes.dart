import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;

/// Fase 43 — meeting bot (paritas Grok Bot "meeting bots", versi deterministik
/// Tiko): transkrip rapat (teks atau file di workspace) diubah menjadi notulen
/// terstruktur TANPA LLM — peserta, keputusan, tindak lanjut, pertanyaan
/// terbuka. Deterministik-first: hasil yang sama untuk input yang sama.
///
/// Konvensi repo:
/// - Deterministik: heuristik keyword/pola, tanpa panggilan LLM.
/// - Never-raises: transkrip kosong/file hilang → laporan error jujur.
/// - Path jail: file transkrip wajib di dalam workspace.
class MeetingNotes {
  MeetingNotes({
    required this.title,
    required this.participants,
    required this.decisions,
    required this.actionItems,
    required this.openQuestions,
    required this.turnCount,
  });

  final String title;
  final List<String> participants;
  final List<String> decisions;

  /// Format `owner — item` (owner kosong → `— item`).
  final List<String> actionItems;
  final List<String> openQuestions;
  final int turnCount;

  String get ok => 'ok';

  Map<String, dynamic> toJson() => {
        'title': title,
        'participants': participants,
        'decisions': decisions,
        'action_items': actionItems,
        'open_questions': openQuestions,
        'turn_count': turnCount,
      };

  String toMarkdown() {
    final buf = StringBuffer('# Notulen: $title\n\n');
    buf.writeln('Peserta: '
        '${participants.isEmpty ? '-' : participants.join(', ')}\n');
    buf.writeln('## Keputusan');
    if (decisions.isEmpty) {
      buf.writeln('- (tidak terdeteksi)');
    } else {
      for (final d in decisions) {
        buf.writeln('- $d');
      }
    }
    buf.writeln();
    buf.writeln('## Tindak Lanjut');
    if (actionItems.isEmpty) {
      buf.writeln('- (tidak terdeteksi)');
    } else {
      for (final a in actionItems) {
        buf.writeln('- $a');
      }
    }
    buf.writeln();
    buf.writeln('## Pertanyaan Terbuka');
    if (openQuestions.isEmpty) {
      buf.writeln('- (tidak ada)');
    } else {
      for (final q in openQuestions) {
        buf.writeln('- $q');
      }
    }
    return buf.toString();
  }

  static MeetingNotes? fromJson(Map<String, dynamic> json) {
    final title = json['title'];
    if (title is! String) return null;
    List<String> list(Object? raw) => raw is List
        ? raw.whereType<String>().toList()
        : const <String>[];
    return MeetingNotes(
      title: title,
      participants: list(json['participants']),
      decisions: list(json['decisions']),
      actionItems: list(json['action_items']),
      openQuestions: list(json['open_questions']),
      turnCount: json['turn_count'] is int ? json['turn_count'] as int : 0,
    );
  }
}

class MeetingNotesParser {
  MeetingNotesParser._();

  static final RegExp _speakerLine = RegExp(r'^\s*([^:;\n]{1,40}?)\s*:\s+(.+)$');

  static final RegExp _decision = RegExp(
    r'\b(disetujui|sepakat|keputusan|decided|approved|setuju|diputuskan)\b',
    caseSensitive: false,
  );

  static final RegExp _action = RegExp(
    r'\b(akan|todo|tindak lanjut|follow[ -]?up|menyiapkan|mengirim|'
    r'menghubungi|membuat|mengerjakan)\b',
    caseSensitive: false,
  );

  static const _pronouns = <String>{
    'saya', 'aku', 'kami', 'kita', 'gue', 'gua', 'i', 'we',
  };

  static final RegExp _ownerAction = RegExp(
    r'^([^,;]+?)\s+(?:akan|todo|menyiapkan|mengirim|menghubungi|membuat|'
    r'mengerjakan)\b',
    caseSensitive: false,
  );

  /// Parser transkrip → notulen. Baris tanpa speaker dilanjutkan ke
  /// utterance pembicara sebelumnya (wrap line), lalu tiap utterance
  /// diklasifikasi satu kali — keputusan/tindakan lintas baris tetap cocok.
  static MeetingNotes parse(String transcript, {String title = 'Rapat'}) {
    final utterances = <(String, String)>[];
    var lastSpeaker = '';

    for (final rawLine in transcript.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final m = _speakerLine.firstMatch(line);
      if (m != null && !line.trimLeft().startsWith('-')) {
        lastSpeaker = m.group(1)!.trim();
        utterances.add((lastSpeaker, m.group(2)!.trim()));
      } else if (lastSpeaker.isNotEmpty) {
        final (speaker, text) = utterances.removeLast();
        utterances.add((speaker, '$text ${line.trim()}'));
      }
    }

    final participants = <String>[];
    final decisions = <String>[];
    final actionItems = <String>[];
    final openQuestions = <String>[];
    for (final (speaker, text) in utterances) {
      if (!participants.contains(speaker)) participants.add(speaker);
      _classify(
          speaker, text, decisions, actionItems, openQuestions);
    }

    return MeetingNotes(
      title: title,
      participants: participants,
      decisions: decisions,
      actionItems: actionItems,
      openQuestions: openQuestions,
      turnCount: utterances.length,
    );
  }

  static void _classify(
    String speaker,
    String text,
    List<String> decisions,
    List<String> actionItems,
    List<String> openQuestions,
  ) {
    final cleaned = text.endsWith('?') || text.contains('?')
        ? text
        : text;
    if (cleaned.trimRight().endsWith('?')) {
      openQuestions.add(
          speaker.isEmpty ? cleaned.trim() : '$speaker — ${cleaned.trim()}');
      return;
    }
    if (_decision.hasMatch(text)) {
      decisions.add(
          speaker.isEmpty ? text.trim() : '$speaker: ${text.trim()}');
      return;
    }
    if (_action.hasMatch(text)) {
      final ownerMatch = _ownerAction.firstMatch(text);
      var owner = ownerMatch != null ? ownerMatch.group(1)!.trim() : '';
      if (owner.isEmpty || _pronouns.contains(owner.toLowerCase())) {
        owner = speaker;
      }
      if (owner.isEmpty) {
        actionItems.add(text.trim());
      } else {
        actionItems.add('$owner — ${text.trim()}');
      }
    }
  }
}

/// Tool `meeting_notes` — notulen rapat deterministik dari transkrip
/// (inline atau file di workspace). Output Markdown terstruktur.
class MeetingNotesTool implements Tool {
  MeetingNotesTool();

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'meeting_notes',
        description:
            'Ubah transkrip rapat menjadi notulen terstruktur deterministik '
            '(peserta, keputusan, tindak lanjut, pertanyaan terbuka) tanpa '
            'LLM. Sumber: teks inline atau path file di workspace.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'transcript': {
              'type': 'string',
              'description': 'Transkrip rapat (baris format "Nama: teks").',
            },
            'path': {
              'type': 'string',
              'description':
                  'Path file transkrip di dalam workspace (alternatif).',
            },
            'title': {
              'type': 'string',
              'description': 'Judul rapat (default "Rapat").',
            },
            'save': {
              'type': 'boolean',
              'description':
                  'Simpan notulen ke meetings/<slug>.md di workspace.',
            },
          },
        },
        risk: 'low',
        timeoutSec: 30,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final title = (args['title'] as String?)?.trim() ?? '';
      var transcript = (args['transcript'] as String?) ?? '';
      final path = (args['path'] as String?)?.trim() ?? '';
      if (transcript.trim().isEmpty) {
        if (path.isEmpty) {
          return const ToolResult(
            callId: '',
            content:
                'Sumber wajib: transcript (inline) atau path file transkrip.',
            isError: true,
          );
        }
        final resolved = PathSafety.resolveInRoot(ctx.workspacePath, path);
        if (resolved == null) {
          return const ToolResult(
            callId: '',
            content: 'path transkrip harus di dalam workspace.',
            isError: true,
          );
        }
        final file = File(resolved);
        if (!await file.exists()) {
          return ToolResult(
            callId: '',
            content: 'File transkrip tidak ditemukan: $path',
            isError: true,
          );
        }
        transcript = await file.readAsString();
      }
      final notes = MeetingNotesParser.parse(
        transcript,
        title: title.isEmpty ? 'Rapat' : title,
      );
      var output = notes.toMarkdown();
      if (args['save'] is bool && args['save'] as bool) {
        final slug = _slugify(notes.title);
        final dir = Directory(p.join(ctx.workspacePath, 'meetings'));
        if (!await dir.exists()) await dir.create(recursive: true);
        final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
        final target = File(p.join(dir.path, '$slug-$stamp.md'));
        await target.writeAsString(output);
        output = '$output\n\nTersimpan: ${p.relative(target.path, from: ctx.workspacePath)}';
      }
      return ToolResult(callId: '', content: output);
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'meeting_notes gagal: $e',
        isError: true,
      );
    }
  }

  static String _slugify(String name) {
    var slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.length > 48) slug = slug.substring(0, 48);
    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'rapat' : slug;
  }
}

/// Encoder helper untuk test roundtrip JSON notulen.
const JsonEncoder meetingNotesEncoder = JsonEncoder.withIndent('  ');
