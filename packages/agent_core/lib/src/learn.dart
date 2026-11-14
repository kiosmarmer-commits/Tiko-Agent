/// `/learn` — authoring skill dari direktori/URL/catatan/percakapan
/// (paritas Hermes, adaptasi arsitektur Tiko AGD-06).
library;

/// Satu sumber materi untuk /learn.
class LearnSource {
  LearnSource({required this.type, required this.value});

  /// 'dir' | 'file' | 'url' | 'notes' | 'conversation'
  final String type;
  final String value;
}

/// Hasil parse perintah /learn.
class LearnRequest {
  LearnRequest({required this.sources, this.focus = ''});

  final List<LearnSource> sources;
  final String focus;

  bool get fromConversation =>
      sources.any((s) => s.type == 'conversation');
}

class LearnCommand {
  static final _url = RegExp(r'^https?://', caseSensitive: false);

  static final _command = RegExp(r'^/learn(?:\s|$)', caseSensitive: false);
  static final _hasExtension = RegExp(r'\.[a-zA-Z0-9]{1,8}$');

  /// Parse input chat. Return null bila bukan perintah /learn.
  static LearnRequest? parse(String input) {
    final trimmed = input.trim();
    final m = _command.firstMatch(trimmed);
    if (m == null) return null;
    var rest = trimmed.substring(m.end).trim();

    var focus = '';
    final focusIdx = rest.indexOf('--focus');
    if (focusIdx >= 0) {
      focus = rest.substring(focusIdx + '--focus'.length).trim();
      rest = rest.substring(0, focusIdx).trim();
    }
    if (focus.startsWith('=')) focus = focus.substring(1).trim();

    final sources = <LearnSource>[];
    if (rest.isEmpty) {
      sources.add(LearnSource(type: 'conversation', value: ''));
      return LearnRequest(sources: sources, focus: focus);
    }

    // `notes:` atau `--notes` membawa teks tempel bebas (bisa multi-kata).
    final notesMatch =
        RegExp(r'^(?:notes:|--notes)\s*(.+)$', dotAll: true).firstMatch(rest);
    if (notesMatch != null) {
      sources.add(LearnSource(type: 'notes', value: notesMatch.group(1)!.trim()));
      return LearnRequest(sources: sources, focus: focus);
    }

    for (final token in rest.split(RegExp(r'\s+'))) {
      if (token.toLowerCase() == 'conversation') {
        sources.add(LearnSource(type: 'conversation', value: ''));
      } else if (_url.hasMatch(token)) {
        sources.add(LearnSource(type: 'url', value: token));
      } else {
        final base = token.split('/').last;
        sources.add(LearnSource(
          type: _hasExtension.hasMatch(base) ? 'file' : 'dir',
          value: token,
        ));
      }
    }
    return LearnRequest(sources: sources, focus: focus);
  }
}

/// Menyusun kontrak authoring SKILL.md standar house (deskripsi ≤60 char,
/// urutan seksi baku, hanya tool nyata, output satu blok fence).
class LearnPrompt {
  static const String systemContract = '''
Anda sedang men-authoring skill baru untuk Tiko-Agent. Patuhi standar house:
1. Frontmatter YAML: name, description (MAKSIMAL 60 karakter), triggers, tools, version: 1, status: draft.
2. Urutan seksi baku: "## Langkah" (langkah bernomor), lalu "## Kegagalan umum" (bullet) bila ada.
3. Hanya boleh menyebut tool yang benar-benar ada di daftar tool yang diberikan. Jangan mengarang perintah/tool.
4. Isi skill ringkas dan dapat diverifikasi; maksimal 4KB.
5. Keluarkan SKILL.md final dalam SATU blok kode berpenanda skill-markdown, tanpa teks lain setelahnya.''';

  static String userPrompt(LearnRequest request) {
    final buf = StringBuffer();
    buf.writeln('Buat SKILL.md baru dari materi berikut.');
    for (final source in request.sources) {
      switch (source.type) {
        case 'dir':
          buf.writeln('- Direktori materi: ${source.value} (baca dengan '
              'list_dir/read_file; pilih hanya yang relevan).');
        case 'file':
          buf.writeln('- File materi: ${source.value} (baca dengan read_file).');
        case 'url':
          buf.writeln('- URL materi: ${source.value} (ambil dengan web_fetch).');
        case 'notes':
          buf.writeln('- Catatan pengguna:\n<<<NOTES\n${source.value}\nNOTES');
        case 'conversation':
          buf.writeln('- Percakapan sesi ini: distil prosedur yang berhasil '
              'menjadi langkah yang dapat diulang.');
      }
    }
    if (request.focus.isNotEmpty) {
      buf.writeln('Fokus skill: ${request.focus}');
    }
    buf.writeln();
    buf.writeln(systemContract);
    return buf.toString().trim();
  }
}

/// Ekstraksi SKILL.md dari balasan model.
class LearnOutput {
  static final _skillFence =
      RegExp(r'```skill-markdown\s*\n(.*?)\n?```', dotAll: true);
  static final _anyFence = RegExp(r'```\w*\s*\n(.*?)\n?```', dotAll: true);

  /// Ambil markdown SKILL.md dari balasan; null bila tidak ada blok yang
  /// dimulai dengan frontmatter '---'.
  static String? extractSkillMarkdown(String reply) {
    for (final pattern in [_skillFence, _anyFence]) {
      for (final match in pattern.allMatches(reply)) {
        final body = match.group(1)!.trim();
        if (body.startsWith('---')) return body;
      }
    }
    final trimmed = reply.trim();
    if (trimmed.startsWith('---') && trimmed.contains('\n---')) return trimmed;
    return null;
  }
}
