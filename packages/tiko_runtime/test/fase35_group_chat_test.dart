import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ChatRunResult _result(String text) => ChatRunResult(text: text, success: true);

AgentSpec _spec(String id, AgentRole role) => AgentSpec(
      id: id,
      role: role,
      systemPrompt: 'peran $id',
      toolAllowlist: const [],
      maxTurns: 2,
    );

void main() {
  test('GROUPCHAT-1: round-robin + TERMINATE mengakhiri + sintesis', () async {
    final members = [
      _spec('researcher', AgentRole.researcher),
      _spec('coder', AgentRole.coder),
      _spec('summarizer', AgentRole.summarizer),
    ];
    final seen = <String>[];
    final runner = GroupChatRunner(
      members: members,
      config: const GroupChatCfg(enabled: true, maxRounds: 6),
      turn: (agent, prompt) async {
        seen.add(agent.id);
        expect(
          prompt,
          anyOf(contains('Tujuan percakapan'), contains('Rangkum percakapan')),
        );
        if (agent.id == 'coder') {
          return _result('setuju dengan riset.\nTERMINATE — cukup.');
        }
        return _result('analisis awal dari ${agent.id}');
      },
    );
    final result = await runner.run(goal: 'uji terminasi');
    expect(result.terminatedBy, 'agent');
    expect(result.rounds, 2);
    expect(seen.take(2), ['researcher', 'coder']);
    expect(
      result.messages.map((m) => m.agentId).take(2),
      ['researcher', 'coder'],
    );
    expect(result.messages.length, 2, reason: 'pesan TERMINATE ikut tercatat');
    expect(result.synthesis, isNotEmpty);
    expect(result.success, isTrue);
    expect(result.messages.last.content, contains('TERMINATE'));
  });

  test('GROUPCHAT-2: cap max_rounds keras — tidak endless', () async {
    final runner = GroupChatRunner(
      members: [_spec('a', AgentRole.custom), _spec('b', AgentRole.custom)],
      config: const GroupChatCfg(enabled: true, maxRounds: 3),
      turn: (agent, prompt) async =>
          _result('masih diskusi ${agent.id} putaran ini'),
    );
    final result = await runner.run(goal: 'uji cap');
    expect(result.terminatedBy, 'max_rounds');
    expect(result.rounds, 3);
    expect(result.messages.length, 3);
    expect(result.success, isTrue, reason: 'sintesis tetap dihasilkan');
  });

  test('GROUPCHAT-3: speaker auto — pilihan valid dipakai, invalid fallback',
      () async {
    final members = [
      _spec('alpha', AgentRole.researcher),
      _spec('beta', AgentRole.coder),
    ];
    final picked = <String>[];
    final runner = GroupChatRunner(
      members: members,
      config: const GroupChatCfg(
        enabled: true,
        maxRounds: 2,
        speakerSelection: 'auto',
      ),
      speakerTurn: (prompt) async {
        expect(prompt, contains('beta'));
        return _result('beta');
      },
      turn: (agent, prompt) async {
        picked.add(agent.id);
        return _result('bicara ${agent.id}');
      },
    );
    await runner.run(goal: 'uji auto');
    expect(
      picked.take(2),
      ['beta', 'beta'],
      reason: 'auto selalu memilih beta',
    );
    expect(picked.length, 3, reason: '2 putaran + 1 turn sintesis (alpha)');

    final fallback = GroupChatRunner(
      members: members,
      config: const GroupChatCfg(
        enabled: true,
        maxRounds: 2,
        speakerSelection: 'auto',
      ),
      speakerTurn: (prompt) async => _result('id-tak-dikenal'),
      turn: (agent, prompt) async => _result('bicara ${agent.id}'),
    );
    final r2 = await fallback.run(goal: 'uji fallback');
    expect(
      r2.messages.map((m) => m.agentId),
      ['alpha', 'beta'],
      reason: 'invalid id → round-robin fail-open',
    );
  });

  test('GROUPCHAT-4: semua turn gagal → error jujur, never-raises', () async {
    final runner = GroupChatRunner(
      members: [_spec('a', AgentRole.custom)],
      config: const GroupChatCfg(enabled: true, maxRounds: 4),
      turn: (agent, prompt) async => throw StateError('provider mati'),
    );
    final result = await runner.run(goal: 'uji gagal');
    expect(result.terminatedBy, 'error');
    expect(result.messages, isEmpty);
    expect(result.success, isFalse);
    expect(result.rounds, 0);
  });

  test('GROUPCHAT-5: truncation pesan + transcript window', () async {
    final prompts = <String>[];
    final runner = GroupChatRunner(
      members: [_spec('a', AgentRole.custom), _spec('b', AgentRole.custom)],
      config: const GroupChatCfg(
        enabled: true,
        maxRounds: 4,
        maxCharsPerMessage: 200,
        maxTranscriptMessages: 2,
      ),
      turn: (agent, prompt) async {
        prompts.add(prompt);
        return _result('y' * 300);
      },
    );
    final result = await runner.run(goal: 'uji truncation');
    expect(result.messages.first.content.length, lessThanOrEqualTo(212));
    expect(result.messages.first.content, endsWith('[terpotong]'));
    // Putaran 4: window 2 pesan → putaran 2–3 terlihat, putaran 1 tidak.
    expect(prompts[3], contains('[putaran 3]'));
    expect(prompts[3], contains('[putaran 2]'));
    expect(prompts[3], isNot(contains('[putaran 1]')));
  });

  test('GROUPCHAT-6: config parser — fail-open, default off', () {
    final (cfg, issues) = TikoConfig.parse('''
group_chat:
  enabled: true
  max_rounds: 12
  max_chars_per_message: 800
  max_transcript_messages: 5
  speaker_selection: auto
  max_agents: 4
''');
    expect(issues.where((i) => i.fatal), isEmpty);
    expect(cfg.groupChat.enabled, isTrue);
    expect(cfg.groupChat.maxRounds, 12);
    expect(cfg.groupChat.maxCharsPerMessage, 800);
    expect(cfg.groupChat.maxTranscriptMessages, 5);
    expect(cfg.groupChat.speakerSelection, 'auto');
    expect(cfg.groupChat.maxAgents, 4);

    final (badCfg, _) = TikoConfig.parse('''
group_chat:
  enabled: oops
  max_rounds: 999
  speaker_selection: liar
''');
    expect(badCfg.groupChat.enabled, isFalse, reason: 'default off');
    expect(badCfg.groupChat.maxRounds, 8);
    expect(badCfg.groupChat.speakerSelection, 'round_robin');

    final (defCfg, _) = TikoConfig.parse('');
    expect(defCfg.groupChat.enabled, isFalse);
  });

  test('GROUPCHAT-7: runtime wiring — off tanpa tool, on dengan tool',
      () async {
    final temp = await Directory.systemTemp.createTemp('group_chat_cfg_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = Directory(p.join(temp.path, 'cfg'));
    await configDir.create();
    final configPath = p.join(configDir.path, 'agent.yaml');
    final template = '''
profile: default
workspace: ${temp.path}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
mcp:
  servers: []
group_chat:
  enabled: ENABLED
''';
    await File(configPath).writeAsString(
      template.replaceAll('ENABLED', 'false'),
    );
    final offRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(offRt.close);
    expect(offRt.registry.get('group_chat'), isNull);

    await File(configPath).writeAsString(
      template.replaceAll('ENABLED', 'true'),
    );
    final onRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(onRt.close);
    expect(onRt.registry.get('group_chat'), isNotNull);
  });
}
