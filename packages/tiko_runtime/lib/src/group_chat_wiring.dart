part of 'tiko_runtime.dart';

/// Fase 35 — wiring host: eksekusi group chat lewat `chatWithStatus` dengan
/// persona + allowlist + budget per anggota (pola identik `runBotTeam`).
extension GroupChatWiring on TikoRuntime {
  /// Percakapan tim bergiliran pada [goal]; [teamId] menunjuk tim tersimpan
  /// (`tiko team save` / REST `/v1/teams`), null = roster bawaan.
  Future<GroupChatResult> runGroupChat({
    required String goal,
    String? teamId,
    int? maxRounds,
  }) async {
    final cfg = config.groupChat;
    final savedDoc = teamId == null ? null : botTeamStore.get(teamId);
    var roster = (savedDoc != null && savedDoc.members.isNotEmpty)
        ? savedDoc.members
        : AgentTeamTool.defaultRegistry.all;
    if (roster.length > cfg.maxAgents) {
      roster = roster.sublist(0, cfg.maxAgents);
    }
    final effective = GroupChatCfg(
      enabled: true,
      maxRounds: (maxRounds != null && maxRounds >= 1 && maxRounds <= 24)
          ? maxRounds
          : cfg.maxRounds,
      maxCharsPerMessage: cfg.maxCharsPerMessage,
      maxTranscriptMessages: cfg.maxTranscriptMessages,
      speakerSelection: cfg.speakerSelection,
      maxAgents: cfg.maxAgents,
    );
    final eco = resourceProfile == 'eco';
    final runner = GroupChatRunner(
      members: roster,
      config: effective,
      emitEvent: events.emit,
      turn: (agent, prompt) {
        final sessionId =
            'groupchat:${teamId ?? 'adhoc'}:${agent.id}:'
            '${DateTime.now().microsecondsSinceEpoch}';
        final allow = agent.toolAllowlist;
        final filter = allow == null
            // Tanpa allowlist eksplisit → tanpa tool (fail-closed, kontrak
            // sama dengan agent_team P2-2).
            ? const <String>{}
            : allow.isEmpty
                ? null
                : Set.of(allow);
        return chatWithStatus(
          prompt,
          sessionId: sessionId,
          channel: 'groupchat',
          userKey: 'groupchat',
          toolFilter: filter,
          configOverride: AgentConfig(
            maxIterations: agent.maxTurns,
            maxTokensPerTask: eco ? 20000 : config.maxTokensPerTask,
            maxWallClockSec: eco ? 120 : config.maxWallClockSec,
            maxToolCalls: eco ? 12 : config.maxToolCalls,
            preferredTier: modelTierToRouterTier(agent.modelTier),
          ),
          personaPrompt:
              agent.systemPrompt.isEmpty ? null : agent.systemPrompt,
        );
      },
    );
    return runner.run(goal: goal);
  }
}
