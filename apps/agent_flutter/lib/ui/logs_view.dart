import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Log browser (GUI-P1-02): daftar file log + isi, dapat dicari berdasarkan
/// nama file dan isi. Konten ditampilkan sebagai teks polos/selectable —
/// tidak pernah diinterpolasi sebagai HTML (paritas dengan web UI).
class LogsPage extends StatefulWidget {
  const LogsPage({
    super.key,
    required this.logs,
    required this.online,
    required this.loading,
    required this.onRefresh,
    required this.onLoadContent,
    this.error,
    this.initialName,
  });

  final List<LogFileInfo> logs;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<LogFileContent> Function(String name) onLoadContent;

  /// Nama log yang dipilih sebelumnya (mis. saat halaman dipush dari More).
  final String? initialName;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String? selected;
  String filter = '';
  LogFileContent? content;
  bool loadingContent = false;
  String? contentError;

  @override
  void initState() {
    super.initState();
    selected = widget.initialName ??
        (widget.logs.isNotEmpty ? widget.logs.first.name : null);
    if (selected != null) unawaitedLoad(selected!);
  }

  void unawaitedLoad(String name) {
    WidgetsBinding.instance.addPostFrameCallback((_) => load(name));
  }

  Future<void> load(String name) async {
    setState(() {
      loadingContent = true;
      contentError = null;
    });
    try {
      final result = await widget.onLoadContent(name);
      if (!mounted) return;
      setState(() {
        content = result;
        loadingContent = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        content = null;
        contentError = '$e';
        loadingContent = false;
      });
    }
  }

  void select(String name) {
    if (name == selected && content != null) return;
    setState(() => selected = name);
    load(name);
  }

  List<LogFileInfo> get filtered {
    final query = filter.trim().toLowerCase();
    if (query.isEmpty) return widget.logs;
    return widget.logs
        .where((log) => log.name.toLowerCase().contains(query))
        .toList();
  }

  List<String> get filteredLines {
    final query = filter.trim().toLowerCase();
    final text = content?.content ?? '';
    if (query.isEmpty) return text.split('\n');
    return text
        .split('\n')
        .where((line) => line.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final files = filtered;
    final lines = filteredLines;
    return Column(
      children: [
        PageHeader(
          title: 'Logs',
          subtitle: '${widget.logs.length} file log',
          online: widget.online,
          trailing: IconButton(
            onPressed: () async {
              await widget.onRefresh();
              if (mounted && selected != null) load(selected!);
            },
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.error!,
                style: TextStyle(color: context.simpulDanger)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Cari nama file atau isi log…',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SimpulTheme.radiusSmall),
              ),
            ),
            onChanged: (value) => setState(() => filter = value),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, i) {
                    final file = files[i];
                    return ListTile(
                      dense: true,
                      selected: file.name == selected,
                      leading: const Icon(Icons.article_outlined),
                      title: Text(file.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${file.bytes} B',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => select(file.name),
                    );
                  },
                ),
              ),
              VerticalDivider(width: 1, color: context.simpulBorder),
              Expanded(
                child: loadingContent
                    ? const Center(child: CircularProgressIndicator())
                    : contentError != null
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(contentError!,
                                style:
                                    TextStyle(color: context.simpulDanger)),
                          )
                        : content == null
                            ? Center(
                                child: Text('Pilih file log.',
                                    style: TextStyle(
                                        color: context.simpulMuted)))
                            : Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  if (content!.truncated)
                                    Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Text(
                                        '[dipotong, terakhir ${content!.bytes} B]',
                                        style: TextStyle(
                                            color: context.simpulWarn,
                                            fontSize: 12),
                                      ),
                                    ),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      padding: const EdgeInsets.all(12),
                                      scrollDirection: Axis.vertical,
                                      child: SelectionArea(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            for (final line in lines)
                                              Text(
                                                line,
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 12,
                                                  height: 1.35,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
