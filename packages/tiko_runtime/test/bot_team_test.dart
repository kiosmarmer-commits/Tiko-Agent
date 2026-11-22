import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Fase C — test orkestra bot team: store, parser rencana, runner penuh
/// (plan → DAG → sintesis → review → verify), dan tool `bot_team`.

AgentSpec _member(
  String id,
  AgentRole role,
  String prompt, {
  List<String>? tools,
  int maxTurns = 3,
}) =>
    AgentSpec(
      id: id,
      role: role,
      systemPrompt: prompt,
      toolAllowlist: tools,
      maxTurns: maxTurns,
    );

ChatRunResult _turn(String text) =>
    ChatRunResult(text: text, success: true, tokensUsed: 7, toolCallCount: 2);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko-bot-team-test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('BotTeamStore', () {
    test('save/load/delete roundtrip', () async {
      final store = BotTeamStore(dataDir: tmp.path);
      final doc = BotTeamDoc(
        id: 'paket-ui',
        name: 'Tim UI',
        description: 'desc',
        members: [
          _member('planner', AgentRole.planner, 'Kamu planner.'),
          _member('coder', AgentRole.coder, 'Kamu coder.', tools: const []),
        ],
      );
      await store.save(doc);
      final reloaded = BotTeamStore(dataDir: tmp.path);
      await reloaded.load();
      expect(reloaded.list().map((d) => d.id), contains('paket-ui'));
      final got = reloaded.get('paket-ui')!;
      expect(got.name, 'Tim UI');
      expect(got.members.length, 2);
      expect(got.members[1].toolAllowlist, const []);
      // null allowlist vs empty list harus tetap terbedakan setelah roundtrip
      expect(await reloaded.delete('paket-ui'), isTrue);
      expect(await reloaded.delete('paket-ui'), isFalse);
    });

    test('file korup dilompati, tidak menggagalkan store', () async {
      final dir = Directory(p.join(tmp.path, 'teams'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'rusak.json'))
          .writeAsString('{ini bukan json');
      final store = BotTeamStore(dataDir: tmp.path);
      await store.load();
      expect(store.list(), isEmpty);
    });

    test('tim tanpa anggota diabaikan saat load', () async {
      final dir = Directory(p.join(tmp.path, 'teams'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'kosong.json')).writeAsString(jsonEncode({
        'id': 'kosong',
        'name': 'Tanpa Anggota',
        'members': [
          {'id': 'x', 'system_prompt': '   '},
        ],
      }));
      final store = BotTeamStore(dataDir: tmp.path);
      await store.load();
      expect(store.get('kosong'), isNull);
    });

    test('laporan run: simpan, baca balik, list terbaru dulu', () async {
      final store = BotTeamStore(dataDir: tmp.path);
      await store.saveRunReport({'run_id': 't-aaa', 'success': true});
      await store.saveRunReport({'run_id': 't-bbb', 'success': false});
      final list = await store.listRunReports();
      expect(list.map((r) => r['run_id']).toList(), ['t-bbb', 't-aaa']);
      expect((await store.readRunReport('t-aaa'))!['success'], isTrue);
      // traversal ditolak fail-closed
      expect(await store.readRunReport('../teams/nonexistent'), isNull);
    });
  });

  group('parseBotTeamPlan', () {
    const agentIds = ['planner', 'researcher', 'coder', 'critic', 'summarizer'];

    test('JSON murni valid → plan planner', () {
      final plan = parseBotTeamPlan(
        jsonEncode({
          'tasks': [
            {'id': 't1', 'prompt': 'riset A', 'agent': 'researcher'},
            {
              'id': 't2',
              'prompt': 'tulis kodenya',
              'agent': 'coder',
              'depends_on': ['t1'],
            },
          ],
        }),
        agentIds: agentIds,
      );
      expect(plan, isNotNull);
      expect(plan!.source, 'planner');
      expect(plan.tasks.length, 2);
      expect(plan.tasks[1].agentId, 'coder');
    });

    test('JSON dalam code fence + prose → tetap terparse', () {
      final plan = parseBotTeamPlan(
        'Berikut rencananya:\n```json\n'
        '{"tasks":[{"id":"a","prompt":"p"}]}\n```\nsemoga membantu',
        agentIds: agentIds,
      );
      expect(plan, isNotNull);
      expect(plan!.tasks.single.id, 'a');
    });

    test('agent tak dikenal → null (fallback)', () {
      expect(
        parseBotTeamPlan(
          '{"tasks":[{"id":"a","prompt":"p","agent":"hantu"}]}',
          agentIds: agentIds,
        ),
        isNull,
      );
    });

    test('dependensi siklus → null', () {
      expect(
        parseBotTeamPlan(
          '{"tasks":['
          '{"id":"a","prompt":"p","depends_on":["b"]},'
          '{"id":"b","prompt":"p","depends_on":["a"]}]}',
          agentIds: agentIds,
        ),
        isNull,
      );
    });

    test('lebih dari 12 node → null', () {
      final tasks = [
        for (var i = 0; i < 13; i++) {'id': 'n$i', 'prompt': 'p'}
      ];
      expect(
        parseBotTeamPlan(jsonEncode({'tasks': tasks}), agentIds: agentIds),
        isNull,
      );
    });

    test('bukan JSON → null', () {
      expect(parseBotTeamPlan('coba-coba saja', agentIds: agentIds), isNull);
    });
  });

  group('BotTeamRunner', () {
    BotTeamRunner makeRunner({
      required List<AgentSpec> roster,
      String Function()? plannerText,
      Future<ChatRunResult> Function(AgentSpec agent, String slot,
              String prompt)?
          turn,
      void Function(String type, Map<String, dynamic> data)? emitEvent,
      String? verifyCommand,
      int repairIterations = 1,
      int maxConcurrency = 4,
      int? maxOutputChars,
    }) {
      final registry = AgentRegistry();
      for (final spec in roster) {
        registry.register(spec);
      }
      return BotTeamRunner(
        members: registry,
        plannerTurn: (prompt) async {
          final t = plannerText?.call() ?? '';
          return _turn(t);
        },
        memberTurn: turn ?? (agent, slot, prompt) async => _turn('jawaban'),
        workspacePath: tmp.path,
        emitEvent: emitEvent,
        maxConcurrency: maxConcurrency,
        maxOutputChars: maxOutputChars ?? 6000,
      );
    }

    final roster = [
      _member('planner', AgentRole.planner, 'Kamu planner.'),
      _member('researcher', AgentRole.researcher, 'Kamu researcher.'),
      _member('coder', AgentRole.coder, 'Kamu coder.', tools: const []),
      _member('critic', AgentRole.critic, 'Kamu critic.'),
      _member('summarizer', AgentRole.summarizer, 'Kamu summarizer.'),
    ];

    const validPlan = '{"tasks":[{"id":"riset","prompt":"riset topik",'
        '"agent":"researcher"},{"id":"tulis","prompt":"tulis laporan",'
        '"agent":"researcher","depends_on":["riset"]}]}';

    test('rencana planner valid → dag dieksekusi berurutan + sintesis', () async {
      final slots = <String, String>{};
      final events = <String>[];
      final runner = makeRunner(
        roster: roster,
        plannerText: () => validPlan,
        emitEvent: (t, d) => events.add(t),
        turn: (agent, slot, prompt) async {
          slots[slot] = prompt;
          if (slot == 'tulis') {
            expect(prompt, contains('--- hasil riset ---'),
                reason: 'dependensi harus diprefix-kan');
            expect(prompt, contains('hasil researcher/riset'));
          }
          return _turn('hasil ${agent.id}/$slot');
        },
      );
      final res = await runner.run(goal: 'buat laporan');
      expect(res.success, isTrue);
      expect(res.planSource, 'planner');
      expect(res.nodeRecords.map((n) => n.nodeId), ['riset', 'tulis']);
      // Sintesis lewat turn summarizer (__synthesis) — output dari stub.
      expect(res.synthesis, contains('__synthesis'));
      expect(events, containsAll(['team.planned', 'team.node_started']));
      expect(slots.keys, containsAll(['riset', 'tulis']));
      expect(res.tokensUsed, greaterThan(0));
    });

    test('planner menghasilkan sampah → fallback satu node tujuan', () async {
      final prompts = <String>[];
      final runner = makeRunner(
        roster: roster,
        plannerText: () => 'maaf, saya tidak tahu format json',
        turn: (agent, slot, prompt) async {
          prompts.add('[$slot] $prompt');
          return _turn('ok');
        },
      );
      final res = await runner.run(goal: 'tugas tunggal');
      expect(res.success, isTrue);
      expect(res.planSource, 'fallback');
      expect(res.nodeRecords.single.nodeId, 'main');
      expect(prompts.first, contains('[main] tugas tunggal'));
    });

    test('planner throw → fallback, orkestra tetap berjalan', () async {
      final registry = AgentRegistry();
      for (final spec in roster) {
        registry.register(spec);
      }
      final runner = BotTeamRunner(
        members: registry,
        plannerTurn: (prompt) async => throw Exception('planner mati'),
        memberTurn: (agent, slot, prompt) async => _turn('ok'),
        workspacePath: tmp.path,
      );
      final res = await runner.run(goal: 'tugas');
      expect(res.planSource, 'fallback');
      expect(res.success, isTrue);
    });

    test('node gagal dicatat jujur → success false', () async {
      final runner = makeRunner(
        roster: roster,
        plannerText: () => validPlan,
        turn: (agent, slot, prompt) async {
          if (slot == 'tulis') {
            throw Exception('model mati');
          }
          return _turn('ok');
        },
      );
      final res = await runner.run(goal: 'tugas');
      expect(res.success, isFalse);
      final failed = res.nodeRecords.singleWhere((n) => n.nodeId == 'tulis');
      expect(failed.ok, isFalse);
      expect(failed.error, contains('model mati'));
      expect(res.review, isNotNull);
    });

    test('review critic memanggil turn dengan konteks gagal', () async {
      String? reviewPrompt;
      final runner = makeRunner(
        roster: roster,
        plannerText: () => validPlan,
        turn: (agent, slot, prompt) async {
          if (slot == '__review') {
            reviewPrompt = prompt;
            return _turn('cacat: belum diverifikasi');
          }
          if (slot == 'tulis') throw Exception('mati');
          return _turn('ok');
        },
      );
      final res = await runner.run(goal: 'tugas');
      expect(reviewPrompt, contains('Tugas GAGAL'));
      expect(reviewPrompt, contains('tulis'));
      expect(res.review, 'cacat: belum diverifikasi');
    });

    test('sintesis deterministik bila tanpa summarizer', () async {
      final rosterTanpaSummarizer = [
        _member('planner', AgentRole.planner, 'Kamu planner.'),
        _member('worker', AgentRole.custom, 'Kamu worker.'),
      ];
      final runner = makeRunner(
        roster: rosterTanpaSummarizer,
        plannerText: () =>
            '{"tasks":[{"id":"a","prompt":"kerja","agent":"worker"}]}',
      );
      final res = await runner.run(goal: 'tujuan A');
      expect(res.synthesis, contains('Tujuan: tujuan A'));
      expect(res.synthesis, contains('[a via worker]'));
    });

    test('verify gate + turn perbaikan lulus di percobaan kedua', () async {
      // probe: sukses hanya bila file flag ada; dibuat saat repair turn.
      final probeScript = File(p.join(tmp.path, 'probe_team.sh'))
        ..writeAsStringSync('#!/bin/sh\n'
            'if [ -f verify.pass ]; then\n'
            '  echo ok\n'
            '  exit 0\n'
            'fi\n'
            'echo "verifikasi gagal" >&2\n'
            'exit 1\n');
      final repairPrompts = <String>[];
      final runner = makeRunner(
        roster: roster,
        plannerText: () =>
            '{"tasks":[{"id":"a","prompt":"ubah kode","agent":"coder"}]}',
        turn: (agent, slot, prompt) async {
          if (slot.startsWith('__repair')) {
            repairPrompts.add(prompt);
            File(p.join(tmp.path, 'verify.pass')).writeAsStringSync('1');
            return _turn('memperbaiki');
          }
          return _turn('ubah kode selesai');
        },
      );
      final res = await runner.run(
        goal: 'ubah kode',
        verifyCommand: 'sh probe_team.sh',
        repairIterations: 1,
      );
      expect(repairPrompts, hasLength(1));
      expect(repairPrompts.single, contains('Verifikasi tim GAGAL'));
      expect(repairPrompts.single, contains('ubah kode'));
      expect(res.verifyOk, isTrue);
      expect(res.verifyExitCode, 0);
      expect(res.success, isTrue);
      expect(probeScript.path, isNotEmpty);
    });

    test('verify selalu gagal → success false, attempts sesuai limit',
        () async {
      File(p.join(tmp.path, 'probe_fail.sh')).writeAsStringSync('#!/bin/sh\n'
          'echo "masih error" >&2\nexit 3\n');
      var repairs = 0;
      final runner = makeRunner(
        roster: roster,
        plannerText: () =>
            '{"tasks":[{"id":"a","prompt":"kerja","agent":"coder"}]}',
        turn: (agent, slot, prompt) async {
          if (slot.startsWith('__repair')) repairs++;
          return _turn('coba');
        },
      );
      final res = await runner.run(
        goal: 'kerja',
        verifyCommand: 'sh probe_fail.sh',
        repairIterations: 2,
      );
      expect(res.success, isFalse);
      expect(res.verifyOk, isFalse);
      expect(res.verifyExitCode, 3);
      expect(repairs, 2);
    });

    test('tail verifikasi terpotong sesuai maxOutputChars', () async {
      File(p.join(tmp.path, 'probe_big.sh')).writeAsStringSync(''
          'for i in 0 1 2 3 4 5 6 7 8 9; do\n'
          '  echo "baris-\$i"\n'
          'done\n'
          'echo "baris-akhir"\n'
          'exit 1\n');
      String? repairPrompt;
      final runner = makeRunner(
        roster: roster,
        plannerText: () =>
            '{"tasks":[{"id":"a","prompt":"kerja","agent":"coder"}]}',
        maxOutputChars: 40,
        turn: (agent, slot, prompt) async {
          if (slot.startsWith('__repair')) repairPrompt = prompt;
          return _turn('coba');
        },
      );
      final res = await runner.run(
        goal: 'kerja',
        verifyCommand: 'sh probe_big.sh',
      );
      expect(res.verifyOk, isFalse);
      expect(repairPrompt, contains('[tail terpotong ke 40 karakter terakhir]'));
      expect(repairPrompt, contains('baris-akhir'));
      expect(repairPrompt!.contains('baris-0'), isFalse);
    });

    test('tanpa verify → verifyOk null dan sukses murni dari node', () async {
      final runner = makeRunner(
        roster: roster,
        plannerText: () => validPlan,
      );
      final res = await runner.run(goal: 'tugas');
      expect(res.verifyOk, isNull);
      expect(res.verifyExitCode, isNull);
      expect(res.success, isTrue);
    });

    test('konkurensi di luar 1..8 ditolak; registry kosong ditolak', () {
      expect(
        () => BotTeamRunner(
          members: AgentRegistry(),
          plannerTurn: (p) async => _turn(''),
          memberTurn: (a, s, p) async => _turn(''),
          workspacePath: tmp.path,
        ),
        throwsArgumentError,
      );
      final registry = AgentRegistry()..register(roster.first);
      expect(
        () => BotTeamRunner(
          members: registry,
          plannerTurn: (p) async => _turn(''),
          memberTurn: (a, s, p) async => _turn(''),
          workspacePath: tmp.path,
          maxConcurrency: 9,
        ),
        throwsArgumentError,
      );
    });
  });

  group('tool bot_team', () {
    test('goal kosong → error jujur', () async {
      final tool = BotTeamTool(
        starter: ({required goal, teamId, verifyCommand, maxConcurrency}) =>
            throw StateError('tidak boleh terpanggil'),
      );
      final ctx = ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: Directory.systemTemp.path,
      );
      final r = await tool.run({'goal': '   '}, ctx);
      expect(r.isError, isTrue);
      expect(r.content, contains('goal wajib'));
      final spec = tool.spec;
      expect(spec.name, 'bot_team');
      expect(spec.inputSchema['required'], contains('goal'));
    });

    test('starter sukses → JSON result, isError false', () async {
      final tool = BotTeamTool(
        starter: ({required goal, teamId, verifyCommand, maxConcurrency}) async {
          expect(goal, 'riset pasar');
          expect(teamId, 'paket-ui');
          expect(verifyCommand, 'dart test');
          return {
            'success': true,
            'run_id': 't-abc',
            'goal': goal,
            'synthesis': 'ringkasan',
          };
        },
      );
      final ctx = ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: Directory.systemTemp.path,
      );
      final r = await tool.run({
        'goal': 'riset pasar',
        'team_id': 'paket-ui',
        'verify_command': 'dart test',
      }, ctx);
      expect(r.isError, isFalse);
      final decoded = jsonDecode(r.content) as Map<String, dynamic>;
      expect(decoded['run_id'], 't-abc');
    });

    test('starter gagal → isError true dengan pesan', () async {
      final tool = BotTeamTool(
        starter: ({required goal, teamId, verifyCommand, maxConcurrency}) async {
          throw Exception('runtime mati');
        },
      );
      final ctx = ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: Directory.systemTemp.path,
      );
      final r = await tool.run({'goal': 'x'}, ctx);
      expect(r.isError, isTrue);
      expect(r.content, contains('gagal dijalankan'));
    });
  });
}
