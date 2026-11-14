import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simpul_core/simpul_core.dart';

import 'command_palette.dart';
import 'theme.dart';

/// Opens the note editor page for [path] inside [vault].
void openNoteEditor(BuildContext context, String vault, String path) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SimpulNoteEditorPage(vault: vault, initialPath: path),
  ));
}

/// Note editor page (FR-10, FR-12, FR-16, FR-17, FR-20, FR-21): edit/preview
/// modes, undo/redo, atomic save, `[[` autocomplete and a backlinks panel.
class SimpulNoteEditorPage extends StatefulWidget {
  const SimpulNoteEditorPage({
    super.key,
    required this.vault,
    this.initialPath = '',
    this.initialEditor,
  });

  final String vault;
  final String initialPath;

  /// Preloaded editor (tests); skips the vault scan + load when given.
  final NoteEditor? initialEditor;

  @override
  State<SimpulNoteEditorPage> createState() => _SimpulNoteEditorPageState();
}

class _SimpulNoteEditorPageState extends State<SimpulNoteEditorPage> {
  late final TextEditingController vaultField;
  final TextEditingController pathField = TextEditingController();
  final TextEditingController textField = TextEditingController();
  final FocusNode editorFocus = FocusNode();

  NoteEditor? editor;
  VaultLinkResolver? resolver;
  bool preview = false;
  String? error;
  bool dirty = false;
  List<({String path, String label})> completions = const [];
  int completionOffset = -1;

  @override
  void initState() {
    super.initState();
    vaultField = TextEditingController(text: widget.vault);
    pathField.text = widget.initialPath;
    textField.addListener(_onTextChanged);
    final preloaded = widget.initialEditor;
    if (preloaded != null) {
      editor = preloaded;
      resolver = preloaded.resolver;
      textField.text = preloaded.text;
    } else if (widget.vault.isNotEmpty && widget.initialPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void dispose() {
    vaultField.dispose();
    pathField.dispose();
    textField.removeListener(_onTextChanged);
    textField.dispose();
    editorFocus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final vault = vaultField.text.trim();
    final path = pathField.text.trim();
    if (vault.isEmpty || path.isEmpty) return;
    try {
      final notes = await VaultScanner.scan(vault);
      final linkResolver = VaultLinkResolver(notes);
      final noteEditor = NoteEditor(
        vaultDir: vault,
        resolver: linkResolver,
      );
      await noteEditor.load(path);
      setState(() {
        resolver = linkResolver;
        editor = noteEditor;
        textField.text = noteEditor.text;
        dirty = false;
        error = null;
        preview = false;
      });
    } catch (e) {
      setState(() => error = 'Gagal membuka catatan: $e');
    }
  }

  void _onTextChanged() {
    final noteEditor = editor;
    if (noteEditor == null) return;
    if (textField.text != noteEditor.text) {
      noteEditor.text = textField.text;
    }
    final next = _computeCompletions();
    setState(() {
      dirty = noteEditor.dirty;
      completions = next;
      if (next.isEmpty) {
        completionOffset = -1;
      }
    });
  }

  List<({String path, String label})> _computeCompletions() {
    final noteEditor = editor;
    if (noteEditor == null || preview) return const [];
    final selection = textField.selection;
    if (!selection.isValid || !selection.isCollapsed) return const [];
    final offset = selection.baseOffset;
    final text = textField.text;
    if (offset < 0 || offset > text.length) return const [];
    final before = text.substring(0, offset);
    final bracket = before.lastIndexOf('[[');
    if (bracket < 0 || before.indexOf(']]', bracket) >= 0) return const [];
    final token = before.substring(bracket + 2);
    if (token.contains('\n') ||
        token.contains('|') ||
        token.contains('#') ||
        token.contains('[')) {
      return const [];
    }
    completionOffset = bracket + 2;
    return resolver?.completions(token) ?? const [];
  }

  void _applyCompletion(({String path, String label}) candidate) {
    final noteEditor = editor;
    if (noteEditor == null || completionOffset < 0) return;
    final text = textField.text;
    final cursor = textField.selection.baseOffset.clamp(0, text.length);
    final link = '[[${candidate.path}]]';
    final newText = text.substring(0, completionOffset) +
        link +
        text.substring(cursor);
    noteEditor.text = newText;
    textField.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: completionOffset + link.length),
    );
    setState(() {
      completions = const [];
      dirty = noteEditor.dirty;
    });
    editorFocus.requestFocus();
  }

  Future<void> _save() async {
    final noteEditor = editor;
    if (noteEditor == null) return;
    try {
      noteEditor.text = textField.text;
      await noteEditor.save();
      setState(() => dirty = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tersimpan.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan: $e')),
        );
      }
    }
  }

  void _undo() {
    final noteEditor = editor;
    if (noteEditor == null) return;
    noteEditor.text = textField.text;
    if (noteEditor.undo()) {
      setState(() {
        textField.value = TextEditingValue(
          text: noteEditor.text,
          selection: TextSelection.collapsed(offset: noteEditor.text.length),
        );
        dirty = noteEditor.dirty;
      });
    }
  }

  void _redo() {
    final noteEditor = editor;
    if (noteEditor == null) return;
    noteEditor.text = textField.text;
    if (noteEditor.redo()) {
      setState(() {
        textField.value = TextEditingValue(
          text: noteEditor.text,
          selection: TextSelection.collapsed(offset: noteEditor.text.length),
        );
        dirty = noteEditor.dirty;
      });
    }
  }

  Future<void> _openPalette() async {
    final vault = vaultField.text.trim();
    final actions = <PaletteAction>[
      PaletteAction('Toggle pratinjau', () => setState(() {
            preview = !preview;
            completions = const [];
          })),
      if (editor != null)
        PaletteAction('Simpan catatan', _save),
      if (editor != null)
        PaletteAction('Tampilkan panel tautan (FR-20/21)', () {
          setState(() => preview = false);
        }),
    ];
    if (vault.isNotEmpty) {
      try {
        final notes = await VaultScanner.scan(vault);
        for (final note in notes) {
          actions.add(PaletteAction(
            'Buka: ${note.path}',
            () => _openPath(note.path),
            hint: note.parsed.title,
          ));
        }
      } catch (_) {
        // Vault scan failure must not block fixed actions.
      }
    }
    if (!mounted) return;
    await showCommandPalette(context, actions);
  }

  Future<void> _newNoteFromTemplate() async {
    final vault = vaultField.text.trim();
    if (vault.isEmpty) return;
    try {
      final templates = await TemplateStore.listTemplates(Directory(vault));
      if (templates.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Belum ada template (.simpul/templates/*.md).'),
          ));
        }
        return;
      }
      if (!mounted) return;
      final selected = await showDialog<TemplateFile>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Pilih template (FR-43)'),
          children: [
            for (final t in templates)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(t),
                child: Text(t.name),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final title = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          final controller = TextEditingController();
          return AlertDialog(
            title: Text('Judul catatan (${selected.name})'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text),
                child: const Text('Buat'),
              ),
            ],
          );
        },
      );
      if (title == null || title.trim().isEmpty || !mounted) return;
      final cleanTitle = title.trim();
      final fileName =
          '${NoteTemplate.sanitizeFileName(cleanTitle)}.md';
      final target = File(
          '${Directory(vault).path}${Platform.pathSeparator}$fileName');
      if (await target.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Catatan sudah ada: $fileName'),
          ));
        }
        return;
      }
      final body = await selected.file.readAsString();
      final rendered = NoteTemplate.render(
        body,
        title: cleanTitle,
        path: fileName.replaceAll(RegExp(r'\.md$'), ''),
      );
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(rendered);
      await tmp.rename(target.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Catatan dibuat: $fileName'),
      ));
      _openPath(fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal membuat catatan: $e')),
        );
      }
    }
  }

  Future<void> _exportNoteHtml() async {
    final noteEditor = editor;
    if (noteEditor == null) return;
    try {
      final html = VaultExporter.noteToHtml(textField.text,
          title: noteEditor.path);
      final outPath = '${noteEditor.path}.html';
      final target = File(
          '${noteEditor.vaultDir}${Platform.pathSeparator}$outPath');
      await target.parent.create(recursive: true);
      await target.writeAsString(html);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('HTML tersimpan: $outPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengekspor: $e')),
        );
      }
    }
  }

  void _openPath(String path) {
    final noteEditor = editor;
    if (noteEditor != null && noteEditor.dirty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Simpan dulu sebelum pindah catatan.')),
      );
      return;
    }
    pathField.text = path;
    _open();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaletteShortcut(
      onPalette: _openPalette,
      child: Scaffold(
      backgroundColor: context.simpulBg,
      appBar: AppBar(
        title: Text(
          (editor?.path.isNotEmpty ?? false) ? editor!.path : 'Editor Catatan',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: 'Command palette (Ctrl+K, FR-44)',
            icon: const Icon(Icons.search),
            onPressed: _openPalette,
          ),
          IconButton(
            tooltip: 'Catatan baru dari template (FR-43)',
            icon: const Icon(Icons.note_add),
            onPressed: _newNoteFromTemplate,
          ),
          IconButton(
            tooltip: 'Ekspor HTML (FR-71)',
            icon: const Icon(Icons.html),
            onPressed: editor == null ? null : _exportNoteHtml,
          ),
          IconButton(
            tooltip: 'Undo (FR-16)',
            icon: const Icon(Icons.undo),
            onPressed: editor == null ? null : _undo,
          ),
          IconButton(
            tooltip: 'Redo (FR-16)',
            icon: const Icon(Icons.redo),
            onPressed: editor == null ? null : _redo,
          ),
          IconButton(
            tooltip: preview ? 'Mode edit (FR-10)' : 'Pratinjau (FR-10)',
            icon: Icon(preview ? Icons.edit : Icons.visibility),
            isSelected: preview,
            onPressed: editor == null
                ? null
                : () => setState(() {
                      preview = !preview;
                      completions = const [];
                    }),
          ),
          Stack(
            children: [
              IconButton(
                tooltip: 'Simpan atomik (FR-17)',
                icon: const Icon(Icons.save_outlined),
                onPressed: editor == null ? null : _save,
              ),
              if (dirty)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: CircleAvatar(
                    radius: 4,
                    backgroundColor: Colors.orangeAccent,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: vaultField,
                    decoration: const InputDecoration(
                      hintText: 'Path vault lokal (mis. ~/vault)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _open(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: pathField,
                    decoration: const InputDecoration(
                      hintText: 'path/catatan.md',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _open(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _open, child: const Text('Buka')),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (completions.isNotEmpty) _completionList(),
          if (preview && editor != null)
            Expanded(
              child: MarkdownPreview(text: textField.text),
            )
          else if (editor != null)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: textField,
                  focusNode: editorFocus,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    height: 1.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Tulis markdown di sini\u2026',
                  ),
                ),
              ),
            )
          else
            const Expanded(
              child: Center(child: Text('Buka catatan untuk mulai mengedit.')),
            ),
          if (editor != null) _linksPanel(),
        ],
      ),
      ),
    );
  }

  Widget _completionList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(bottom: BorderSide(color: context.simpulBorder)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final candidate in completions)
            ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(candidate.label, style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                candidate.path,
                style: TextStyle(fontSize: 11, color: context.simpulMuted),
              ),
              onTap: () => _applyCompletion(candidate),
            ),
        ],
      ),
    );
  }

  Widget _linksPanel() {
    final noteEditor = editor!;
    final links = noteEditor.links();
    final outgoing = links.where((l) => l.link.target.isNotEmpty).toList();
    final broken = outgoing.where((l) => !l.resolved).toList();
    final backlinks = noteEditor.backlinks();
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        'Tautan (FR-20/21): ${backlinks.length} backlink, '
        '${outgoing.length} keluar, ${broken.length} rusak',
        style: const TextStyle(fontSize: 13),
      ),
      children: [
        if (backlinks.isNotEmpty)
          ListTile(
            dense: true,
            title: Text(
              'Backlink',
              style: TextStyle(fontSize: 12, color: context.simpulMuted),
            ),
          ),
        for (final source in backlinks)
          ListTile(
            dense: true,
            leading: const Icon(Icons.link, size: 16),
            title: Text(source, style: const TextStyle(fontSize: 12)),
            onTap: () => _openPath(source),
          ),
        if (outgoing.isNotEmpty)
          ListTile(
            dense: true,
            title: Text(
              'Tautan keluar',
              style: TextStyle(fontSize: 12, color: context.simpulMuted),
            ),
          ),
        for (final link in outgoing)
          ListTile(
            dense: true,
            leading: Icon(
              link.resolved ? Icons.link : Icons.link_off,
              size: 16,
              color: link.resolved ? null : context.simpulDanger,
            ),
            title: Text(
              link.link.alias.isNotEmpty
                  ? '${link.link.alias} \u2192 ${link.resolvedPath ?? link.link.target}'
                  : (link.resolvedPath ?? link.link.target),
              style: TextStyle(
                fontSize: 12,
                color: link.resolved ? null : context.simpulDanger,
              ),
            ),
            subtitle: link.link.anchor.isEmpty
                ? null
                : Text(
                    '#${link.link.anchor}',
                    style: TextStyle(fontSize: 11, color: context.simpulMuted),
                  ),
            onTap: link.resolved ? () => _openPath(link.resolvedPath!) : null,
          ),
      ],
    );
  }
}

/// Minimal live-preview renderer (FR-10/FR-11): headings, lists, code fences,
/// quotes, bold/italic/inline-code and wikilinks. No external dependency.
class MarkdownPreview extends StatelessWidget {
  const MarkdownPreview({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(text);
    final blocks = <Widget>[];
    var inCode = false;
    var codeBuffer = <String>[];
    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          blocks.add(_codeBlock(codeBuffer.join('\n'), context));
          codeBuffer = [];
        }
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        codeBuffer.add(line);
        continue;
      }
      final trimmed = line.trimLeft();
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            heading.group(2)!,
            style: TextStyle(
              fontSize: 20.0 - (level - 1) * 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ));
        continue;
      }
      if (trimmed.startsWith('>')) {
        blocks.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: context.simpulAccent, width: 3)),
            color: context.simpulPanel,
          ),
          child: _inline(trimmed.substring(1).trim(), context),
        ));
        continue;
      }
      if (RegExp(r'^[-*]\s+\[[ xX]\]\s+').hasMatch(trimmed)) {
        final checked = trimmed.contains('[x]') || trimmed.contains('[X]');
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _inline(
                  trimmed.replaceFirst(RegExp(r'^[-*]\s+\[[ xX]\]\s+'), ''),
                  context,
                ),
              ),
            ],
          ),
        ));
        continue;
      }
      if (RegExp(r'^[-*+]\s+').hasMatch(trimmed) ||
          RegExp(r'^\d+\.\s+').hasMatch(trimmed)) {
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('\u2022  '),
              Expanded(
                child: _inline(
                  trimmed.replaceFirst(RegExp(r'^([-*+]|\d+\.)\s+'), ''),
                  context,
                ),
              ),
            ],
          ),
        ));
        continue;
      }
      if (trimmed.isEmpty) continue;
      blocks.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _inline(trimmed, context),
      ));
    }
    if (inCode && codeBuffer.isNotEmpty) {
      blocks.add(_codeBlock(codeBuffer.join('\n'), context));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: blocks,
      ),
    );
  }

  Widget _codeBlock(String code, BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border.all(color: context.simpulBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    );
  }

  static final RegExp _tokenPattern = RegExp(
    r'(\[\[[^\]]+\]\])|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(`[^`]+`)|(\[[^\]]+\]\([^)]+\))',
  );

  Widget _inline(String text, BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _tokenPattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('[[')) {
        final inner = token.substring(2, token.length - 2);
        final label = inner.split('|').last.split('#').first;
        spans.add(TextSpan(
          text: label,
          style: TextStyle(color: context.simpulAccent),
        ));
      } else if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else if (token.startsWith('`')) {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: context.simpulPanel,
          ),
        ));
      } else if (token.startsWith('[')) {
        final md = RegExp(r'\[([^\]]+)\]\(([^)]+)\)').firstMatch(token);
        spans.add(TextSpan(
          text: md?.group(1) ?? token,
          style: TextStyle(color: context.simpulAccent),
        ));
      } else {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(TextSpan(children: spans));
  }
}
