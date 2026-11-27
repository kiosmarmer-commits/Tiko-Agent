/// Fase 35 — inter-agent messaging umum bergaya AutoGen (audit 2026-11-28
/// §6 #14: "`BotTeamRunner` ... perlu mode inter-agent messaging yang lebih
/// umum"). BUKAN replikasi penuh framework AutoGen: tanpa code-execution
/// sandbox antar-agent, tanpa nested chats — yang diadopsi adalah pola
/// *group chat* intinya:
///
/// 1. Percakapan multi-agen bernomor putaran (round) dengan log pesan
///    bersama yang terlihat semua anggota.
/// 2. *Speaker selection* per putaran: `round_robin` (deterministik, tanpa
///    LLM) atau `auto` (pemilihan via LLM dengan fail-open ke round-robin).
/// 3. Kondisi terminasi konvensi AutoGen: balasan yang memuat marker
///    `TERMINATE` mengakhiri percakapan; cap `max_rounds` keras.
/// 4. Sintesis akhir oleh anggota summarizer (atau anggota pertama) tanpa
///    tool, sehingga hasil selalu satu jawaban koheren.
///
/// Prinsip kontrak runtime: never-raises terhadap caller, budget keras,
/// event telemetry bebas-konten (id anggota + putaran + panjang char, tanpa
/// isi pesan), dan jalur chat default tidak berubah — dieksekusi lewat tool
/// `group_chat` yang hanya terdaftar bila config enabled.

import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'tiko_config.dart';
import 'tiko_runtime.dart';

/// Satu pesan dalam percakapan grup; serializable untuk laporan JSON.
class GroupChatMessage {
  const GroupChatMessage({
    required this.agentId,
    required this.content,
    required this.round,
    required this.tsMs,
  });

  final String agentId;
  final String content;
  final int round;
  final int tsMs;

  Map<String, dynamic> toJson() => {
        'agent_id': agentId,
        'content': content,
        'round': round,
        'ts_ms': tsMs,
      };

  factory GroupChatMessage.fromJson(Map<String, dynamic> json) =>
      GroupChatMessage(
        agentId: json['agent_id'] as String? ?? '',
        content: json['content'] as String? ?? '',
        round: json['round'] is int ? json['round'] as int : 0,
        tsMs: json['ts_ms'] is int ? json['ts_ms'] as int : 0,
      );
}

/// Cara memilih pembicara tiap putaran.
enum GroupChatSpeakerMode {
  /// Deterministik — bergiliran urutan anggota, tanpa panggilan LLM.
  roundRobin,

  /// LLM memilih anggota berikutnya dari roster; gagal parse / id tak
  /// dikenal → fallback round-robin (fail-open).
  auto,
}

/// Hasil run group chat; selalu serializable dan tidak pernah throw.
class GroupChatResult {
  const GroupChatResult({
    required this.goal,
    required this.success,
    required this.terminatedBy,
    required this.rounds,
    required this.messages,
    required this.synthesis,
    this.tokensUsed = 0,
    this.toolCallCount = 0,
  });

  final String goal;

  /// True bila percakapan menghasilkan minimal satu pesan anggota DAN
  /// sintesis akhir non-kosong.
  final bool success;

  /// 'agent' (marker TERMINATE), 'max_rounds' (cap budget), atau 'error'
  /// (semua turn gagal — jujur, bukan proklamasi sukses).
  final String terminatedBy;
  final int rounds;
  final List<GroupChatMessage> messages;
  final String synthesis;
  final int tokensUsed;
  final int toolCallCount;

  Map<String, dynamic> toJson() => {
        'goal': goal,
        'success': success,
        'terminated_by': terminatedBy,
        'rounds': rounds,
        'messages': [for (final m in messages) m.toJson()],
        'synthesis': synthesis,
        'tokens_used': tokensUsed,
        'tool_call_count': toolCallCount,
      };
}

/// Marker terminasi konvensi AutoGen: balasan yang memuat baris/kata
/// `TERMINATE` di awal dianggap sinyal berhenti.
final RegExp _terminatePattern = RegExp(r'^\s*TERMINATE\b', multiLine: true);

/// Runner group chat murni (callback injected) → deterministik di test,
/// tanpa mengenal detail router/registry host.
class GroupChatRunner {
  GroupChatRunner({
    required this.members,
    required this.turn,
    this.speakerTurn,
    this.config = const GroupChatCfg(),
    this.emitEvent,
  }) {
    if (members.isEmpty) {
      throw ArgumentError('Butuh minimal satu anggota group chat');
    }
  }

  /// Anggota percakapan (urutan = urutan giliran round-robin).
  final List<AgentSpec> members;

  /// Satu turn anggota: host menyuntikkan ke `chatWithStatus` dengan
  /// persona + allowlist + budget anggota.
  final Future<ChatRunResult> Function(AgentSpec agent, String prompt) turn;

  /// Turn pemilihan pembicara mode `auto` (opsional; null → round-robin).
  final Future<ChatRunResult> Function(String prompt)? speakerTurn;

  final GroupChatCfg config;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;

  int _cursor = 0;

  void _emit(String type, Map<String, dynamic> data) =>
      emitEvent?.call(type, data);

  String _transcript(int upToRound) {
    final recent = messages.length > config.maxTranscriptMessages
        ? messages.sublist(messages.length - config.maxTranscriptMessages)
        : messages;
    final buf = StringBuffer();
    for (final m in recent) {
      buf.writeln('[putaran ${m.round}] ${m.agentId}:');
      buf.writeln(_clip(m.content, config.maxCharsPerMessage));
    }
    return buf.toString().trim();
  }

  static String _clip(String s, int max) {
    final t = s.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…[terpotong]';
  }

  static String _oneLine(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length <= 80 ? t : '${t.substring(0, 80)}…';
  }

  /// Prompt per putaran: tujuan + transkrip + instruksi peran anggota.
  String _turnPrompt(String goal, AgentSpec agent, int round) {
    final transcript = messages.isEmpty
        ? '(belum ada pesan — kamu pembicara pertama)'
        : _transcript(round);
    return '''
Ini percakapan tim multi-agen bergiliran. Tanggapi perspektif peranmu,
bangun ATAU kritisikan jawaban anggota lain, jangan mengulang tanpa nilai
tambah. Bila tujuan SUDAH tercapai dan tidak ada kontribusi lagi, balas
persis dengan kata TERMINATE (boleh disertai satu kalimat alasan).

Tujuan percakapan:
$goal

Riwayat percakapan:
$transcript

Peranmu: ${agent.id} — ${_oneLine(agent.systemPrompt)}''';
  }

  AgentSpec _nextSpeakerRoundRobin() {
    final agent = members[_cursor % members.length];
    _cursor++;
    return agent;
  }

  /// Mode `auto`: LLM memilih id anggota berikutnya; fail-open ke
  /// round-robin bila balasan tidak valid.
  Future<AgentSpec> _nextSpeakerAuto(int round, String goal) async {
    final speakerFn = speakerTurn;
    if (speakerFn == null) return _nextSpeakerRoundRobin();
    final rosterList = [
      for (final a in members) '- ${a.id} (${a.role.name}): ${_oneLine(a.systemPrompt)}',
    ].join('\n');
    try {
      final r = await speakerFn('''
Pilih SATU anggota berikutnya yang paling perlu bicara sekarang untuk tujuan
percakapan ini. Balas HANYA id anggota (tanpa penjelasan).

Anggota:
$rosterList

Tujuan: $goal
Putaran berikutnya: $round''');
      final id = r.text.trim().split('\n').first.trim();
      for (final a in members) {
        if (a.id == id) return a;
      }
    } catch (_) {
      // fall through ke round-robin.
    }
    return _nextSpeakerRoundRobin();
  }

  Future<AgentSpec> _nextSpeaker(String mode, int round, String goal) =>
      mode == 'auto'
          ? _nextSpeakerAuto(round, goal)
          : Future.value(_nextSpeakerRoundRobin());

  List<GroupChatMessage> messages = [];

  /// Jalankan percakapan penuh. Tidak pernah throw — kegagalan turn
  /// dicatat jujur di `terminatedBy: 'error'` bila semua gagal.
  Future<GroupChatResult> run({required String goal}) async {
    final goalTrim = goal.trim();
    assert(goalTrim.isNotEmpty, 'goal wajib');
    messages = [];
    _cursor = 0;
    var tokens = 0;
    var toolCalls = 0;
    var terminatedBy = 'max_rounds';
    var rounds = 0;

    for (var round = 1; round <= config.maxRounds; round++) {
      final speaker =
          await _nextSpeaker(config.speakerSelection, round, goalTrim);
      ChatRunResult turnResult;
      try {
        turnResult = await turn(speaker, _turnPrompt(goalTrim, speaker, round));
      } catch (e) {
        _emit('group_chat.turn_error', {
          'agent': speaker.id,
          'round': round,
        });
        terminatedBy = 'error';
        break;
      }
      tokens += turnResult.tokensUsed;
      toolCalls += turnResult.toolCallCount;
      final content = _clip(turnResult.text, config.maxCharsPerMessage);
      _emit('group_chat.turn', {
        'agent': speaker.id,
        'round': round,
        'chars': content.length,
      });
      messages.add(GroupChatMessage(
        agentId: speaker.id,
        content: content,
        round: round,
        tsMs: DateTime.now().millisecondsSinceEpoch,
      ));
      rounds = round;
      if (_terminatePattern.hasMatch(turnResult.text)) {
        terminatedBy = 'agent';
        break;
      }
    }

    // Sintesis akhir: anggota summarizer (atau anggota pertama), tanpa
    // dependensi pada tool — cukup merangkum transkrip menjadi satu jawaban.
    final synthesizer = members.firstWhere(
      (a) => a.role == AgentRole.summarizer,
      orElse: () => members.first,
    );
    var synthesis = '';
    try {
      final synthTurn = await turn(
        synthesizer,
        'Rangkum percakapan tim berikut menjadi SATU jawaban final yang '
            'koheren untuk tujuan di bawah. Jangan menambah klaim baru.\n\n'
            'Tujuan:\n$goalTrim\n\nRiwayat percakapan:\n'
            '${messages.isEmpty ? '(kosong)' : _transcript(config.maxRounds)}',
      );
      tokens += synthTurn.tokensUsed;
      toolCalls += synthTurn.toolCallCount;
      synthesis = _clip(synthTurn.text, config.maxCharsPerMessage);
    } catch (_) {
      synthesis = '';
    }

    final success = messages.isNotEmpty && synthesis.trim().isNotEmpty;
    _emit('group_chat.done', {
      'rounds': rounds,
      'success': success,
      'terminated_by': terminatedBy,
      'messages': messages.length,
    });
    return GroupChatResult(
      goal: goalTrim,
      success: success,
      terminatedBy: terminatedBy,
      rounds: rounds,
      messages: List.unmodifiable(messages),
      synthesis: synthesis,
      tokensUsed: tokens,
      toolCallCount: toolCalls,
    );
  }
}

/// Fase 35 — starter dipakai [GroupChatTool] menjalankan group chat penuh;
/// host menyuntikkan ke `runGroupChat` (extension `GroupChatWiring`).
typedef GroupChatStarter = Future<Map<String, dynamic>> Function({
  required String goal,
  String? teamId,
  int? maxRounds,
});

/// Tool `group_chat` — percakapan multi-agen bergiliran (AutoGen-style):
/// goal → pembicara bergantian (round-robin / LLM auto) hingga marker
/// TERMINATE atau cap putaran → sintesis akhir. Hanya terdaftar bila
/// config `group_chat.enabled` (panggilan LLM berbiaya per putaran).
class GroupChatTool implements Tool {
  GroupChatTool({required this.starter});

  final GroupChatStarter starter;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'group_chat',
        description:
            'Percakapan tim multi-agen bergiliran pada satu tujuan: '
            'anggota bicara bergantian melihat transkrip bersama hingga '
            'satu anggota menyatakan TERMINATE atau cap putaran, lalu '
            'disintesis menjadi jawaban final. Input: goal wajib; '
            'team_id tim tersimpan (opsional).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'goal': {'type': 'string'},
            'team_id': {
              'type': 'string',
              'description': 'Id tim tersimpan; kosong = tim bawaan.',
            },
            'max_rounds': {'type': 'integer'},
          },
          'required': ['goal'],
        },
        risk: 'medium',
        timeoutSec: 1200,
        maxOutputChars: 60000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final goal = (args['goal'] as String?)?.trim() ?? '';
    if (goal.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'goal wajib: tujuan utama percakapan tim.',
        isError: true,
      );
    }
    final maxRoundsRaw = args['max_rounds'];
    final maxRounds = maxRoundsRaw is int ? maxRoundsRaw : null;
    try {
      final result = await starter(
        goal: goal,
        teamId: (args['team_id'] as String?)?.trim(),
        maxRounds: maxRounds,
      );
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ').convert(result),
        isError: result['success'] != true,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'group chat gagal dijalankan: $e',
        isError: true,
      );
    }
  }
}
