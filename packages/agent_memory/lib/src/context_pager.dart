library;

/// Fase 36 — MemGPT-style control-flow paging (audit 2026-11-28 §6 #9:
/// layered/curated memory + compaction ada, "belum sama dengan control-flow
/// paging MemGPT"). BUKAN replikasi penuh MemGPT (tanpa fungsi self-edit
/// `core_memory_append/replace`): yang diadopsi pola paging-nya —
///
/// 1. **Page-out deterministik**: pesan user/assistant yang sudah keluar
///    dari working-memory window (`SessionStore.recent(limit: keepRecent)`)
///    dipaging keluar ke layer episodic [LayeredMemory] per halaman
///    (batch bounded), dengan fingerprint idempotensi agar pesan yang sama
///    tidak dipaging dua kali.
/// 2. **Page-in on-demand**: model memanggil tool `memory_page` action
///    `page_in` — control-flow-nya di tangan agent (MemGPT-style), bukan
///    injeksi otomatis tanpa dasar.
/// 3. **Status**: hitungan halaman per sesi untuk observability.
///
/// Prinsip kontrak: never-raises terhadap caller (kegagalan store → laporan
/// error di report, bukan exception), tanpa dependensi baru (hash FNV-1a
/// internal), data tetap UTUH di session store — paging tidak menghapus,
/// hanya menduplikasi ke memori berlapis.

import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'memory_layers.dart';

/// FNV-1a 32-bit — fingerprint idempotensi tanpa dependensi eksternal.
int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

String _fingerprint(String role, String content) =>
    _fnv1a('$role$content').toRadixString(36);

/// Laporan page-out; serializable dan jujur (paged 0 bukan kegagalan).
class PageOutReport {
  const PageOutReport({
    required this.sessionId,
    required this.pagedMessages,
    required this.pagedPages,
    required this.charsPaged,
    this.error,
  });

  final String sessionId;
  final int pagedMessages;
  final int pagedPages;
  final int charsPaged;

  /// Non-null bila store gagal — caller tetap mendapat laporan.
  final String? error;

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'paged_messages': pagedMessages,
        'paged_pages': pagedPages,
        'chars_paged': charsPaged,
        if (error != null) 'error': error,
      };
}

/// Mesin paging konteks: page-out deterministik + page-in retrieval.
class ContextPager {
  ContextPager({
    required this.store,
    required this.memory,
    required this.statePath,
    this.keepRecent = 12,
    this.scanWindow = 200,
    this.maxCharsPerEntry = 2000,
    this.maxStateEntries = 500,
  })  : assert(keepRecent >= 4),
        assert(scanWindow >= keepRecent),
        assert(maxCharsPerEntry >= 500),
        assert(maxStateEntries >= 10);

  /// Sumber sejarah pesan (tetap utuh — paging hanya menduplikasi).
  final dynamic store; // SessionStore (agent_core) — hindari import siklus.
  final LayeredMemory memory;
  final String statePath;

  /// Jumlah pesan terbaru yang dibiarkan di working memory.
  final int keepRecent;

  /// Jendela scan maksimum ke belakang.
  final int scanWindow;

  /// Batas karakter per halaman (entry episodic).
  final int maxCharsPerEntry;

  /// Cap fingerprint per sesi (evict tertua) supaya state bounded.
  final int maxStateEntries;

  Map<String, List<String>>? _stateCache;

  List<String> _pagedFingerprints(String sessionId) {
    if (_stateCache != null) return _stateCache![sessionId] ?? const [];
    try {
      final raw = File(statePath).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final sessions = decoded['sessions'];
      final out = <String, List<String>>{};
      if (sessions is Map) {
        for (final e in sessions.entries) {
          out['${e.key}'] = [
            if (e.value is List)
              for (final f in e.value as List) '$f',
          ];
        }
      }
      _stateCache = out;
    } catch (_) {
      _stateCache = {};
    }
    return _stateCache![sessionId] ?? const [];
  }

  void _rememberPaged(String sessionId, List<String> fps) {
    _stateCache ??= {};
    final merged = [..._pagedFingerprints(sessionId), ...fps];
    _stateCache![sessionId] =
        merged.length > maxStateEntries
            ? merged.sublist(merged.length - maxStateEntries)
            : merged;
    try {
      Directory(p.dirname(statePath)).createSync(recursive: true);
      File(statePath).writeAsStringSync(
        jsonEncode({
          'sessions': {
            for (final e in _stateCache!.entries) e.key: e.value,
          },
        }),
      );
    } catch (_) {
      // persist state best-effort; idempotensi terbaik tetap berjalan.
    }
  }

  String _clip(String s, int max) {
    final t = s.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  /// Page-out: pesan di luar working window → halaman episodic. Idempoten
  /// via fingerprint; tidak pernah throw.
  Future<PageOutReport> pageOut({
    required String sessionId,
    required String userKey,
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    try {
      final msgs = await (store as dynamic).recent(
        sessionId,
        limit: scanWindow,
      ) as List<dynamic>;
      final excess =
          msgs.length > keepRecent ? msgs.sublist(0, msgs.length - keepRecent) : const <dynamic>[];
      if (excess.isEmpty) {
        return PageOutReport(
          sessionId: sessionId,
          pagedMessages: 0,
          pagedPages: 0,
          charsPaged: 0,
        );
      }
      final seen = _pagedFingerprints(sessionId).toSet();
      final newFps = <String>[];
      final buf = StringBuffer();
      var pageMessages = 0;
      var pageChars = 0;
      var pages = 0;
      var totalChars = 0;
      var totalMessages = 0;

      void flush() {
        if (buf.isEmpty || pageMessages == 0) return;
        memory.add(
          MemoryLayerType.episodic,
          '[paged session $sessionId]\n${buf.toString().trim()}',
          importance: 0.4,
          tags: ['paged', 'session:$sessionId'],
          ownerKey: userKey,
          sourceSession: sessionId,
          now: at,
        );
        pages++;
        totalMessages += pageMessages;
        totalChars += pageChars;
        buf.clear();
        pageMessages = 0;
        pageChars = 0;
      }

      for (final m in excess) {
        final role = '${(m as dynamic).role}';
        final content = '${(m as dynamic).content}';
        final fp = _fingerprint(role, content);
        if (seen.contains(fp)) continue;
        newFps.add(fp);
        final line = '[$role] ${_clip(content, 500)}';
        if (pageChars + line.length > maxCharsPerEntry && pageMessages > 0) {
          flush();
        }
        buf.writeln(line);
        pageMessages++;
        pageChars += line.length;
      }
      flush();
      if (newFps.isNotEmpty) _rememberPaged(sessionId, newFps);
      return PageOutReport(
        sessionId: sessionId,
        pagedMessages: totalMessages,
        pagedPages: pages,
        charsPaged: totalChars,
      );
    } catch (e) {
      return PageOutReport(
        sessionId: sessionId,
        pagedMessages: 0,
        pagedPages: 0,
        charsPaged: 0,
        error: '$e',
      );
    }
  }

  /// Page-in: retrieval hanya atas halaman hasil paging (tag `paged`),
  /// opsional terikat satu sesi, dan wajib ada overlap lexical dengan
  /// query (skor 0 ditolak — jangan kembalikan halaman tak relevan).
  List<MemoryEntry> pageIn({
    required String query,
    String? sessionId,
    String? userKey,
    int k = 8,
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    final queryTokens = _contentTokens(query);
    final hits = memory.retrieve(
      query,
      k: k * 4,
      ownerKey: userKey,
      now: at,
    );
    final out = <MemoryEntry>[];
    for (final e in hits) {
      if (!e.tags.contains('paged')) continue;
      if (sessionId != null && !e.tags.contains('session:$sessionId')) {
        continue;
      }
      if (queryTokens.isNotEmpty &&
          !_contentTokens(e.text).any(queryTokens.contains)) {
        continue;
      }
      out.add(e);
      if (out.length >= k) break;
    }
    return out;
  }

  static final RegExp _tokenPattern = RegExp(r'[a-z0-9]+');

  static Set<String> _contentTokens(String s) => _tokenPattern
      .allMatches(s.toLowerCase())
      .map((m) => m.group(0)!)
      .toSet();

  /// Status paging: jumlah entry paged per sesi (observability).
  Map<String, dynamic> status({String? sessionId}) {
    final counts = <String, int>{};
    var total = 0;
    for (final e in memory.all) {
      if (!e.tags.contains('paged')) continue;
      total++;
      final sid = e.sourceSession ?? '?';
      counts[sid] = (counts[sid] ?? 0) + 1;
    }
    return {
      'paged_total': total,
      if (sessionId != null)
        'paged_session': counts[sessionId] ?? 0
      else
        'sessions': counts,
    };
  }
}

/// Fase 36 — tool `memory_page`: control-flow paging MemGPT-style di tangan
/// model — `page_out` (sejarah luar window → episodic), `page_in` (ambil
/// kembali halaman relevan), `status`.
class MemoryPageTool implements Tool {
  MemoryPageTool(this._pager);

  final ContextPager _pager;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'memory_page',
        description:
            'Paging memori MemGPT-style: page_out memindahkan sejarah '
            'percakapan yang sudah keluar dari window kerja ke memori '
            'episodic; page_in mengambil kembali halaman yang relevan; '
            'status menampilkan hitungan. Gunakan page_in saat butuh '
            'konteks lama yang sudah tak ada di riwayat terlihat.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['page_out', 'page_in', 'status'],
            },
            'query': {'type': 'string'},
            'k': {'type': 'integer'},
          },
          'required': ['action'],
        },
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = '${args['action'] ?? ''}';
    switch (action) {
      case 'page_out':
        final r = await _pager.pageOut(
          sessionId: ctx.session.id,
          userKey: ctx.session.userKey,
        );
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert(r.toJson()),
        );
      case 'page_in':
        final query = (args['query'] as String?)?.trim() ?? '';
        if (query.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'query wajib untuk aksi page_in',
            isError: true,
          );
        }
        final hits = _pager.pageIn(
          query: query,
          sessionId: ctx.session.id,
          userKey: ctx.session.userKey,
          k: (args['k'] as num?)?.toInt() ?? 8,
        );
        if (hits.isEmpty) {
          return const ToolResult(
            callId: '',
            content: '(tidak ada halaman relevan)',
          );
        }
        return ToolResult(
          callId: '',
          content: hits
              .map((e) => '- [paged ${e.sourceSession ?? '?'}] ${e.text}')
              .join('\n'),
        );
      case 'status':
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ')
              .convert(_pager.status(sessionId: ctx.session.id)),
        );
      default:
        return const ToolResult(
          callId: '',
          content: 'aksi tidak dikenal; gunakan page_out|page_in|status',
          isError: true,
        );
    }
  }
}
