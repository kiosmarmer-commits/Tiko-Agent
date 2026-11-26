/// Renderer streaming output tool untuk TUI (Hermes `stream_tool_output`):
/// aktivitas tool dirender bertahap sebagai baris status — "mulai" saat
/// dipanggil, "selesai/error + durasi" saat kembali — tanpa memblokir
/// streaming teks utama. Host menghubungkan callback `onToolTrace` runtime
/// ke [onCall]/[onResult]; baris terkumpul dirender ulang via [render].
class ToolTraceEvent {
  const ToolTraceEvent({
    required this.tool,
    required this.phase,
    this.argsPreview = '',
    this.isError = false,
    this.durationMs,
  });

  final String tool;
  final String phase; // start | end
  final String argsPreview;
  final bool isError;
  final int? durationMs;
}

class ToolTraceRenderer {
  ToolTraceRenderer({this.maxEvents = 200, this.argsPreviewChars = 60});

  /// Kapasitas riwayat event per turn.
  final int maxEvents;

  /// Panjang pratinjau argumen (char) — nilai panjang dipangkas.
  final int argsPreviewChars;

  final List<ToolTraceEvent> _events = [];
  bool color = true;

  bool get isEmpty => _events.isEmpty;
  int get length => _events.length;

  void clear() => _events.clear();

  void onCall(String tool, Map<String, dynamic> args) {
    _push(ToolTraceEvent(
      tool: tool,
      phase: 'start',
      argsPreview: _preview(args),
    ));
  }

  void onResult(
    String tool, {
    bool isError = false,
    int? durationMs,
    Map<String, dynamic>? args,
  }) {
    _push(ToolTraceEvent(
      tool: tool,
      phase: 'end',
      argsPreview: args == null ? '' : _preview(args),
      isError: isError,
      durationMs: durationMs,
    ));
  }

  void _push(ToolTraceEvent e) {
    _events.add(e);
    while (_events.length > maxEvents) {
      _events.removeAt(0);
    }
  }

  String _preview(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final keys = args.keys.take(3)
        .map((k) => '$k=${_oneLine(args[k])}')
        .join(' ');
    return keys.length > argsPreviewChars
        ? '${keys.substring(0, argsPreviewChars)}…'
        : keys;
  }

  String _oneLine(Object? v) {
    var s = v?.toString() ?? '';
    s = s.replaceAll('\n', ' ');
    return s.length > 30 ? '${s.substring(0, 30)}…' : s;
  }

  /// Baris siap render untuk seluruh event terkumpul. Dipanggil host di
  /// antara tick spinner atau setelah turn selesai.
  List<String> render() {
    final lines = <String>[];
    for (final e in _events) {
      if (e.phase == 'start') {
        final args = e.argsPreview.isEmpty ? '' : ' ${e.argsPreview}';
        lines.add(_paint('  [tool] ${e.tool}$args …', '90'));
      } else {
        final icon = e.isError ? '✗' : '✓';
        final code = e.isError ? '31' : '32';
        final dur = e.durationMs == null ? '' : ' (${e.durationMs}ms)';
        final args = e.argsPreview.isEmpty ? '' : ' ${e.argsPreview}';
        lines.add(_paint('  [$icon tool] ${e.tool}$args$dur', code));
      }
    }
    return lines;
  }

  String _paint(String text, String code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;
}
