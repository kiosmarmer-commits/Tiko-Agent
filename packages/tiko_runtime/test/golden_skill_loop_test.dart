import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Scripted LLM that always answers with a complete SKILL.md document. Used
/// as the synthesis provider of the self-learning engine (P1-8).
class _ScriptedSynthesisLlm implements LlmProvider {
  static const skillMd = '''
---
name: Deploy Checklist
description: Prosedur deploy produksi yang aman
triggers: [deploy produksi]
tools: []
version: 1
status: draft
---

# Deploy Checklist
1. Jalankan docker compose config untuk validasi.
2. Deploy dengan docker compose up -d.
3. Cek health check endpoint sebelum lapor selesai.
''';

  @override
  String get id => 'scripted-synthesis';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield const LlmTextDelta(skillMd);
    yield const LlmUsage(TokenUsage(prompt: 10, completion: 10, total: 20));
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

void main() {
  late Directory temp;
  late String skillsDir;
  late String goldenDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_golden_loop_');
    skillsDir = '${temp.path}/skills';
    goldenDir = '${temp.path}/test/golden';
    await Directory(skillsDir).create(recursive: true);
    await Directory(goldenDir).create(recursive: true);
    await File('${temp.path}/agent.yaml').writeAsString('''
profile: default
workspace: "."
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
      scenario: multi_tool
''');
  });

  tearDown(() => temp.delete(recursive: true));

  test('closed loop: tugas kompleks -> file skill baru -> tugas mirip memakai skill',
      () async {
    final sharedSkills = SkillRegistry();
    final engine = SelfLearningEngine(
      llmProvider: _ScriptedSynthesisLlm(),
      skillRegistry: sharedSkills,
      memoryStore: SafeMemoryStore(InMemoryStore()),
      sessionStore: FileSessionStore(path: '${temp.path}/sessions.json'),
      skillsDir: skillsDir,
      config: const SelfLearningConfig(
        synthesisThreshold: 0.7,
        minToolCallsForSynthesis: 2,
      ),
    );

    final runtime = await TikoRuntime.create(
      configPath: '${temp.path}/agent.yaml',
      skills: sharedSkills,
      selfLearningEngine: engine,
    );
    addTearDown(runtime.approvals.close);
    addTearDown(runtime.events.close);
    addTearDown(engine.stop);

    // ---- Fase 1: tugas kompleks (2 tool calls) memicu sintesis skill ----
    final r1 = await runtime.chatWithStatus(
      'hitung 2+3 lalu cek datetime',
      sessionId: 'loop:1',
    );
    expect(r1.success, isTrue);

    final skillFile = File('$skillsDir/deploy-checklist/SKILL.md');
    expect(skillFile.existsSync(), isTrue,
        reason: 'skill baru harus tersimpan sebagai file SKILL.md');
    final skill = sharedSkills.get('deploy-checklist');
    expect(skill, isNotNull);
    expect(skill!.triggers, contains('deploy produksi'));
    expect(skill.status, SkillStatus.draft,
        reason: 'skill baru wajib draft sampai gerbang promosi lulus');

    // ---- Fase 2: gerbang promosi (scan + golden evaluasi terisolasi) ----
    await File('$goldenDir/deploy-checklist.yaml').writeAsString('''
tasks:
  - id: skill-smoke-deploy
    input: "deploy produksi"
    allowed_tools: ["calc", "datetime"]
    answer_contains: ["hasil tool"]
''');
    final eval = await runtime.evaluateSkill('deploy-checklist', promoteOnPass: true);
    expect(eval.ok, isTrue,
        reason: 'eval message: ${eval.message}; findings: ${eval.findings}');
    expect(sharedSkills.get('deploy-checklist')!.status, SkillStatus.trial);

    // ---- Fase 3: tugas mirip berikutnya memakai skill (recordUse) ----
    final usesBefore = sharedSkills.get('deploy-checklist')!.uses;
    expect(usesBefore, 0);
    final r2 = await runtime.chatWithStatus(
      'tolong bantu deploy produksi sekarang',
      sessionId: 'loop:2',
    );
    expect(r2.success, isTrue);
    expect(sharedSkills.get('deploy-checklist')!.uses, greaterThan(0),
        reason: 'skill harus ter-trigger oleh tugas mirip (trigger match)');

    // Skill file survives a fresh registry load (durable procedural memory).
    final reloaded = SkillRegistry();
    final loaded = await reloaded.loadFromDirectory(skillsDir);
    expect(loaded, 1);
    expect(reloaded.get('deploy-checklist'), isNotNull);
  });
}
