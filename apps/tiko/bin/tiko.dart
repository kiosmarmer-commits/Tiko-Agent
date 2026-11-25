import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart' show ModelDiscovery;
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:tiko_tui/tiko_tui.dart';
import 'package:tiko/batch_cli.dart';
import 'package:tiko/settings_menu.dart';
import 'package:tiko/tiko_cli.dart';

const _usage = '''
tiko — Pasitiko local-first agent (control plane)

  tiko [opsi] <perintah>

Perintah utama:
  setup [--provider mock|ollama] [--workspace PATH] [--force] [--smoke]
  setup --interactive         wizard kredensial provider + gateway
  chat [prompt]              chat (mode auto: embedded)
  run <prompt>
  daemon start|stop|restart|status
  ui                         cetak URL UI
  doctor [--probe] [--fix]
  route explain --task "..."
  status
  version

Config:
  settings                   TUI pengaturan layar penuh (provider, model,
                             keamanan, port; search/preview/dirty-state) —
                             bisa juga `/settings` di chat
  context                    tampilkan project context file aktif
                             (TIKO.md | AGENTS.md | CLAUDE.md | GEMINI.md)
  fix "<tugas>" --verify "<cmd>" [--iter 1-8]
  research "<pertanyaan>" [--concurrency N]
                             riset otomatis: plan → gather → sintesis →
                             review; laporan di data/research (Fase D)
  research runs | show <id>
                             daftar / baca laporan run riset
  research schedule "<pertanyaan>" --cron "0 8 * * *"
                             jadwalkan riset berkala — digest dikirim ke
                             channel; progres live di papan Kanban
                             loop coding/debugging otomatis: edit → verifikasi
                             objektif → umpan balik error (terbatas iterasi)
  team list|show <id>|delete <id>
                             kelola tim bot tersimpan (Fase C)
  team save <id> --name N [--desc D] --member '<json>'...
                             simpan tim; member JSON: {id, role?, prompt,
                             tools? [nama tool], tier?, max_turns?}
  team run "<tujuan>" [--team ID] [--verify "<cmd>"] [--concurrency N]
                             orkestra tim: plan → DAG paralel → sintesis →
                             review → gate verifikasi objektif (Fase B)
  config show|validate
  config get <path>
  config set <path> <value>
  config diff [--revision N]
  config history
  config rollback <revision>

Safety:
  approvals [--all]          daftar approval daemon aktif
  approve <id>               setujui melalui API daemon
  deny <id>                  tolak melalui API daemon

Surface (A2UI, Fase E):
  surface list [--session K] daftar surface tersimpan (default: semua sesi)
  surface show <id>          detail surface: komponen + data model
  surface delete <id>        hapus surface
  surface catalogs           katalog komponen yang di-whitelist

Direct (tanpa LLM):
  calc <ekspresi>
  datetime
  tools list

Skills:
  skills list|scan|evaluate|approve|rollback
  offline status|enqueue|drain

Session:
  session list
  session delete <id>

Migration:
  migrate <claude-code|chatgpt|json> <path> [--owner KEY]

IDE / API:
  acp                        sajikan agent via ACP (JSON-RPC 2.0 stdio)
  mcp                        sajikan agent via MCP server (stdio) — untuk AI
                             agent lain (Claude Desktop, Hermes, dll.)

Evaluation:
  eval <cases.json> [--label L]   jalankan suite evaluasi, laporan JSON

Batch:
  batch run --tasks tasks.jsonl [--concurrency N] [--label L]
                             jalankan task JSONL paralel, tiap turn dicatat
                             ke trajektori (data/trajectories)
  batch export --out out.jsonl [--sharegpt] [--no-redact]
               [--exclude-session ID]
                             ekspor trajektori untuk eval/training (redaksi
                             secret aktif secara default)

Opsi: --config PATH  --json  --no-safe  --fix  --mode auto|embedded
''';

String? _siblingAgentdBinary() {
  final candidate =
      p.join(p.dirname(Platform.resolvedExecutable), 'agentd');
  return File(candidate).existsSync() ? candidate : null;
}

Future<void> main(List<String> argv) async {
  final parsed = parseTikoArgs(argv);
  final configPath = parsed.configPath;
  final jsonOut = parsed.jsonOut;
  final safe = parsed.safe;
  final probe = parsed.probe;
  final fix = parsed.fix;
  final mode = parsed.mode;
  if (parsed.help) {
    stdout.write(_usage);
    return;
  }
  final rest = parsed.rest;
  if (rest.isEmpty) {
    stdout.write(_usage);
    exitCode = 2;
    return;
  }

  final cmd = rest.first;
  final args = rest.skip(1).toList();

  if (cmd == 'version') {
    stdout.writeln('tiko $tikoVersion');
    return;
  }

  void emit(Object data, String text) {
    stdout.writeln(jsonOut ? jsonEncode(data) : text);
  }

  // setup before full runtime if creating config
  if (cmd == 'setup') {
    await _setup(configPath, args);
    return;
  }

  // Approval commands must talk to the owning daemon. Constructing a second
  // runtime here would create a separate in-memory waiter and cannot safely
  // settle an approval held by the daemon process.
  if (cmd == 'approve' || cmd == 'deny' || cmd == 'approvals') {
    await _handleRemoteApprovals(configPath, cmd, args, jsonOut: jsonOut);
    return;
  }

  // Surface A2UI juga milik daemon (state per sesi + snapshot disk) —
  // runtime kedua lokal tidak punya state yang sama.
  if (cmd == 'surface') {
    await _handleRemoteSurfaces(
      configPath,
      args.isEmpty ? 'list' : args.first,
      args.isEmpty ? const [] : args.sublist(1),
      jsonOut: jsonOut,
    );
    return;
  }

  late final TikoRuntime rt;
  try {
    rt = await TikoRuntime.create(
      configPath: configPath,
      safe: safe,
      // Doctor and config commands must remain available to repair a bad file.
      allowInvalidConfig: cmd == 'doctor' || cmd == 'config' ||
          cmd == 'settings',
    );
  } on ConfigValidationException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
    return;
  }
  final store = ConfigStore(
    configPath: p.absolute(configPath),
    revisionsDir: p.join(rt.dataDir, 'config_revisions'),
  );
  final daemon = DaemonManager(
    dataDir: rt.dataDir,
    apiPort: rt.config.apiPort,
    configPath: p.absolute(configPath),
    safe: safe,
    // Biner AOT hasil install.sh hidup bersebelahan dengan tiko; startup
    // agentd jauh lebih cepat daripada `dart run` (JIT) di mesin lemah.
    agentdBinary: _siblingAgentdBinary(),
  );
  final bus = EventBus();
  final skillsDir = p.join(rt.workspace, 'skills');

  Future<TuiOutcome> openSettingsShortcut() async {
    try {
      await runSettingsMenu(
        configPath: p.absolute(configPath),
        revisionsDir: p.join(rt.dataDir, 'config_revisions'),
        forceLineMode: true,
      );
    } on PromptAborted {
      stdout.writeln();
    }
    return const TuiOutcome([
      '(settings) ditutup. Perubahan config berlaku untuk perintah baru; '
          'daemon aktif perlu `tiko daemon restart` agar memakai config '
          'terbaru.',
    ]);
  }

  Future<bool> askUser(
    ToolCall call,
    Session session,
    String approvalId,
  ) async {
    // F8.2: aksi yang pernah diingat user lolos tanpa prompt — gate tetap
    // berjalan, hanya konfirmasi identik yang di-skip.
    if (!safe && rt.approvalRules.matches(call, sessionId: session.id)) {
      stdout.writeln(
        'Auto-approved via aturan diingat [${call.name}] id=$approvalId',
      );
      return true;
    }
    stdout.writeln(
      'Konfirmasi tool [${call.name}] risk args=${call.args} id=$approvalId',
    );
    stdout.write('Izinkan? [y/N] ');
    final line = stdin.readLineSync()?.trim().toLowerCase();
    if (line != 'y' && line != 'yes') return false;
    stdout.write('Ingat aksi ini? [t]idak / [s]esi / [w]orkspace (t/S) ');
    final remember = stdin.readLineSync()?.trim().toLowerCase();
    if (remember == 's' || remember == 'sesi') {
      await rt.approvalRules.remember(call, scope: 'session', sessionId: session.id);
    } else if (remember == 'w' || remember == 'workspace') {
      await rt.approvalRules.remember(call, scope: 'workspace');
    }
    return true;
  }

  try {
    switch (cmd) {
    case 'calc':
    case 'datetime':
      final res = await rt.direct(cmd, args);
      emit({'ok': res.exitCode == 0, 'output': res.output}, res.output);
      exitCode = res.exitCode;
      return;

    case 'tools':
      if (args.isEmpty || args.first == 'list') {
        final lines = rt.registry.specs
            .map((s) => '${s.name}\t${s.risk}\t${s.description}')
            .join('\n');
        emit({'tools': rt.registry.specs.map((s) => s.name).toList()}, lines);
      }
      return;

    case 'models':
      final providerId = args.isEmpty ? '' : args.first;
      if (providerId.isEmpty) {
        final lines = rt.config.providers.values
            .where((c) => c.enabled)
            .map((c) =>
                '${c.id}\t${c.type}\t${c.model ?? '-'}\t${c.contextLength ?? '-'}')
            .join('\n');
        emit(
          {
            'providers': [
              for (final c in rt.config.providers.values)
                if (c.enabled)
                  {
                    'id': c.id,
                    'type': c.type,
                    'model': c.model,
                    'context_length': c.contextLength,
                  },
            ],
          },
          lines,
        );
        return;
      }
      final cfg = rt.config.providers[providerId];
      if (cfg == null) {
        stderr.writeln('provider "$providerId" tidak ada di config');
        exitCode = 2;
        return;
      }
      final provider = rt.providerById(providerId);
      if (provider is! ModelDiscovery) {
        stderr.writeln(
          'provider "$providerId" (${cfg.type}) tidak mendukung model discovery',
        );
        exitCode = 2;
        return;
      }
      final ModelDiscovery discovery = provider as ModelDiscovery;
      final models = await discovery.discoverModels();
      emit(
        {'provider': providerId, 'models': models},
        models.isEmpty ? '(kosong)' : models.join('\n'),
      );
      return;

    case 'route':
      if (args.isEmpty || args.first != 'explain') {
        stderr.writeln('tiko route explain --task "..."');
        exitCode = 2;
        return;
      }
      var task = args.skip(1).join(' ').trim();
      if (task.startsWith('--task')) {
        task = args.skip(2).join(' ').trim();
      }
      if (task.isEmpty) task = 'halo';
      final expl = await rt.routeExplain(task);
      emit(expl, const JsonEncoder.withIndent('  ').convert(expl));
      return;

    case 'doctor':
      final lockInfo = await daemon.lock.read();
      final ownLock = lockInfo != null && RuntimeLock.isAlive(lockInfo.pid)
          ? lockInfo
          : null;
      final checks = await rt.doctor(
        probe: probe,
        apiPort: rt.config.apiPort,
        lock: ownLock,
      );
      if (jsonOut) {
        emit({'checks': checks.map((c) => c.toJson()).toList()}, '');
      } else {
        for (final c in checks) {
          final mark = c.status == CheckStatus.ok
              ? 'OK'
              : c.status == CheckStatus.warn
                  ? 'WARN'
                  : 'FAIL';
          stdout.writeln('[$mark] ${c.name}: ${c.detail}');
        }
      }
      // F8.4 — `doctor --fix`: provisioning toolchain registry secara
      // interaktif (human-in-loop; tidak pernah auto-install diam-diam).
      if (fix) {
        final plan = buildToolchainPlan();
        if (jsonOut) {
          emit({
            'fix_plan': {
              'apt': plan.aptInstallable.map((r) => r.bin).toList(),
              'manual': plan.manual.map((r) => r.bin).toList(),
            },
          }, const JsonEncoder.withIndent('  ').convert({
            'fix_plan': {
              'apt': plan.aptInstallable.map((r) => r.bin).toList(),
              'manual': plan.manual.map((r) => r.bin).toList(),
            },
          }));
        } else {
          stdout.writeln('\n[tiko doctor --fix] rencana provisioning:');
          stdout.writeln(plan.describe());
        }
        stdout.write('Pasang paket apt (human-in-loop)? [y/N] ');
        final answer = stdin.readLineSync()?.trim().toLowerCase();
        final confirmed = answer == 'y' || answer == 'yes';
        final result = await applyToolchainPlan(
          plan,
          confirm: (_) async => confirmed,
          dryRun: jsonOut,
        );
        stdout.writeln(result.message);
        if (!result.success) exitCode = 1;
      }
      if (checks.any((c) => c.status == CheckStatus.fail)) exitCode = 1;
      return;

    case 'status':
      final st = await daemon.status();
      final body = {
        'version': tikoVersion,
        'provider': rt.config.defaultProvider,
        'memory': rt.memoryBackend,
        'workspace': rt.workspace,
        'dataDir': rt.dataDir,
        'safe': safe,
        'mode': mode,
        'daemon': st,
        'provider_health': rt.providerHealth(),
        'issues': rt.issues.map((i) => i.toString()).toList(),
      };
      emit(body, const JsonEncoder.withIndent('  ').convert(body));
      return;

    case 'daemon':
      if (args.isEmpty) {
        stderr.writeln('daemon start|stop|restart|status');
        exitCode = 2;
        return;
      }
      final sub = args.first;
      Map<String, dynamic> r;
      switch (sub) {
        case 'start':
          r = await daemon.start();
        case 'stop':
          r = await daemon.stop();
        case 'restart':
          r = await daemon.restart();
        case 'status':
          r = await daemon.status();
        default:
          stderr.writeln('unknown daemon $sub');
          exitCode = 2;
          return;
      }
      emit(r, const JsonEncoder.withIndent('  ').convert(r));
      if ((sub == 'start' || sub == 'restart') && r['running'] != true) {
        exitCode = 1;
      } else if (sub == 'stop' && r['stopped'] != true) {
        exitCode = 1;
      }
      return;

    case 'ui':
      final started = await daemon.start();
      if (started['running'] != true) {
        stderr.writeln(started['detail'] ?? started);
        exitCode = 1;
        return;
      }
      final actualPort = started['port'] ?? rt.config.apiPort;
      stdout.writeln('UI: http://127.0.0.1:$actualPort/');
      return;

    case 'settings':
      try {
        await runSettingsMenu(
          configPath: p.absolute(configPath),
          revisionsDir: p.join(rt.dataDir, 'config_revisions'),
        );
      } on PromptAborted {
        stdout.writeln();
        stdout.writeln('Settings ditutup.');
      }
      return;

    case 'config':
      await _configCmd(store, args, emit, jsonOut);
      return;

    case 'skills':
      if (args.isEmpty || args.first == 'list') {
        final dir = Directory(skillsDir);
        if (!dir.existsSync()) {
          stdout.writeln('(no skills/)');
          return;
        }
        for (final e in dir.listSync().whereType<Directory>()) {
          final scan = SkillScanner.scanDirectory(e.path);
          stdout.writeln('${e.path.split('/').last}\tscan=${scan.ok ? 'OK' : 'FAIL'}');
        }
      } else if (args.first == 'scan' && args.length > 1) {
        final r = SkillScanner.scanDirectory(args[1]);
        emit({'ok': r.ok, 'findings': r.findings}, r.ok ? 'OK' : r.findings.join('\n'));
        if (!r.ok) exitCode = 1;
      } else if (args.first == 'evaluate' && args.length > 1) {
        final slug = args[1];
        try {
          final r = await rt.evaluateSkill(
            slug,
            promoteOnPass: args.contains('--promote'),
          );
          emit(r.toJson(), '${r.ok ? 'PASS' : 'FAIL'} ${r.stage}: ${r.message}');
          if (!r.ok) exitCode = 1;
        } on ArgumentError catch (error) {
          stderr.writeln(error.message);
          exitCode = 1;
        }
      } else if (args.first == 'approve' && args.length > 1) {
        var actor = 'cli';
        for (var i = 2; i + 1 < args.length; i++) {
          if (args[i] == '--actor') actor = args[i + 1];
        }
        if (actor.trim().isEmpty) actor = 'cli';
        try {
          final r = await rt.approveSkill(args[1], actor: actor);
          emit(r.toJson(), r.message);
          if (!r.ok) exitCode = 1;
        } on ArgumentError catch (error) {
          stderr.writeln(error.message);
          exitCode = 1;
        }
      } else if (args.first == 'hub') {
        final hubUrl = Platform.environment['TIKO_SKILLS_HUB_URL']?.trim() ?? '';
        if (hubUrl.isEmpty) {
          stderr.writeln('TIKO_SKILLS_HUB_URL belum diset; hub nonaktif.');
          exitCode = 2;
          return;
        }
        final hub = SkillsHubClient(
          config: SkillsHubConfig(
            apiBaseUrl: hubUrl,
            skillsDirectory: skillsDir,
            apiKey: Platform.environment['TIKO_SKILLS_HUB_TOKEN']?.trim().isNotEmpty == true
                ? Platform.environment['TIKO_SKILLS_HUB_TOKEN']!.trim()
                : null,
          ),
        );
        final sub = args.length > 1 ? args[1] : 'list';
        try {
          if (sub == 'search' && args.length > 2) {
            final results = await hub.search(args.sublist(2).join(' '));
            if (results.isEmpty) {
              stdout.writeln('(tidak ada skill cocok)');
            } else {
              for (final s in results) {
                stdout.writeln('${s.id}\t${s.name}\t${s.description}');
              }
            }
          } else if (sub == 'install' && args.length > 2) {
            stdout.writeln('terpasang: ${await hub.installFromHub(args[2])}');
            await rt.reloadSkills();
          } else if (sub == 'uninstall' && args.length > 2) {
            final ok = await hub.uninstall(args[2]);
            stdout.writeln(ok ? 'dihapus ${args[2]}' : 'tidak ditemukan ${args[2]}');
            if (ok) await rt.reloadSkills();
            if (!ok) exitCode = 1;
          } else if (sub == 'list') {
            await hub.refreshInstalled();
            final installed = hub.installed;
            if (installed.isEmpty) {
              stdout.writeln('(belum ada skill hub terpasang)');
            } else {
              for (final e in installed.entries) {
                stdout.writeln('${e.key}\t${e.value.name}\tv${e.value.version}');
              }
            }
          } else {
            stderr.writeln('skills hub list|search <query>|install <id>|uninstall <slug>');
            exitCode = 2;
          }
        } on SkillsHubException catch (e) {
          stderr.writeln('$e');
          exitCode = 1;
        }
      } else if (args.first == 'import' && args.length > 1) {
        final path = args[1];
        final f = File(p.join(path, 'SKILL.md'));
        if (!f.existsSync()) {
          stderr.writeln('SKILL.md tidak ditemukan di $path');
          exitCode = 1;
          return;
        }
        final parsed = AgentSkillManifest.parse(await f.readAsString());
        if (parsed.errors.isNotEmpty) {
          for (final e in parsed.errors) {
            stderr.writeln(e);
          }
          exitCode = 1;
          return;
        }
        final skill = const AgentSkillConverter().toTikoSkill(
          parsed.manifest,
          parsed.body,
          path: f.path,
        );
        rt.skills.register(skill);
        stdout.writeln('skill standar diimpor sebagai trial: ${skill.slug}');
      } else if (args.first == 'install' && args.length > 1) {
        // E3: install skill dari sumber lokal (paket JSON / SKILL.md /
        // direktori) dengan verifikasi SHA-256 opsional. Tanpa registry.
        var expectedSha256 = '';
        for (var i = 2; i + 1 < args.length; i++) {
          if (args[i] == '--sha256') expectedSha256 = args[i + 1];
        }
        try {
          final result = await SkillLocalInstaller(
            skillsDirectory: skillsDir,
            onChanged: (_) => rt.reloadSkills(),
          ).install(
            args[1],
            expectedSha256: expectedSha256.isEmpty ? null : expectedSha256,
          );
          stdout.writeln(
            'terpasang: ${result.slug} (status=draft, sha256=${result.sha256}, '
            'sumber=${result.source})',
          );
          stdout.writeln(
              'Tinjau lalu approve: tiko skills approve ${result.slug}');
        } on SkillLocalInstallException catch (e) {
          stderr.writeln('$e');
          exitCode = 1;
        }
      } else if (args.first == 'rollback' && args.length > 1) {
        var to = 'draft';
        for (var i = 2; i + 1 < args.length; i++) {
          if (args[i] == '--to') to = args[i + 1];
        }
        try {
          final r = await rt.rollbackSkill(args[1], to: to);
          emit(r.toJson(), r.message);
          if (!r.ok) exitCode = 1;
        } on ArgumentError catch (error) {
          stderr.writeln(error.message);
          exitCode = 1;
        }
      } else {
        stderr.writeln(
          'skills list|scan <dir>|evaluate <slug> [--promote]|'
          'approve <slug> [--actor nama]|rollback <slug> [--to draft]|'
          'install <path> [--sha256 <hex>]',
        );
        exitCode = 2;
      }
      return;

    case 'offline':
      if (args.isEmpty || args.first == 'status') {
        final n = await rt.offlineQueue.length();
        final res = rt.lastResources?.toJson() ?? ResourceMonitor.capture(dataDir: rt.dataDir).toJson();
        emit({'queue': n, 'resources': res}, 'offline_queue=$n profile=${res['profile']} network=${res['network_likely']}');
      } else if (args.first == 'enqueue') {
        final text = args.skip(1).join(' ').trim();
        if (text.isEmpty) {
          exitCode = 2;
          return;
        }
        await rt.offlineQueue.enqueue(text: text);
        stdout.writeln('enqueued');
      } else if (args.first == 'drain') {
        final items = await rt.offlineQueue.claim(limit: 100);
        for (final it in items) {
          final id = '${it['id']}';
          final claimToken = '${it['claim_token']}';
          stdout.writeln('drain> ${it['text']}');
          try {
            final outcome = await rt.chatWithStatus(
              '${it['text']}',
              sessionId: '${it['session_id'] ?? 'offline'}',
              channel: '${it['channel'] ?? 'cli'}',
            );
            stdout.writeln('tiko> ${outcome.text}');
            if (outcome.success) {
              await rt.offlineQueue.ack(id, claimToken: claimToken);
            } else {
              await rt.offlineQueue.retry(
                id,
                claimToken: claimToken,
                error: outcome.text,
              );
            }
          } catch (e) {
            stdout.writeln('fail: $e');
            await rt.offlineQueue.retry(id, claimToken: claimToken, error: '$e');
          }
        }
      }
      return;

    case 'session':
      if (args.isEmpty || args.first == 'list') {
        final list = await rt.sessions.list();
        if (jsonOut) {
          emit({'sessions': list.map((s) => {'id': s.id, 'channel': s.channel}).toList()}, '');
        } else {
          for (final s in list) {
            stdout.writeln('${s.id}\t${s.channel}\t${s.title ?? ''}');
          }
        }
      } else if (args.first == 'delete' && args.length > 1) {
        await rt.sessions.delete(args[1]);
        stdout.writeln('deleted ${args[1]}');
      }
      return;

    case 'migrate':
      // Import conversation history from other agents into memory.
      if (args.length < 2) {
        stderr.writeln('pakai: tiko migrate <claude-code|chatgpt|json> <path> [--owner KEY]');
        exitCode = 2;
        return;
      }
      final migrateFormat = switch (args.first) {
        'claude-code' => 'claude_code',
        'chatgpt' => 'chatgpt',
        'json' => 'generic',
        _ => args.first,
      };
      var migrateOwner = '';
      for (var i = 2; i + 1 < args.length; i++) {
        if (args[i] == '--owner') migrateOwner = args[i + 1];
      }
      try {
        final report = await rt.migrateHistory(
          args[1],
          format: migrateFormat,
          ownerKey: migrateOwner.isEmpty ? null : migrateOwner,
        );
        emit(
          report.toJson(),
          'impor ${report.imported} fakta dari ${report.exchanges} exchange '
          '(${report.skipped} dilewati, ${report.errors.length} galat)',
        );
        if (report.errors.isNotEmpty) {
          stderr.writeln(report.errors.take(5).join('\n'));
          exitCode = 1;
        }
      } on FileSystemException catch (error) {
        stderr.writeln(error.message);
        exitCode = 1;
      } on ArgumentError catch (error) {
        stderr.writeln(error.message);
        exitCode = 1;
      }
      return;

    case 'eval':
      // Evaluation harness (P1-6): run a JSON case suite through the real
      // runtime and print the aggregate report.
      if (args.isEmpty) {
        stderr.writeln('eval membutuhkan path file kasus JSON');
        exitCode = 2;
        return;
      }
      final evalLabel = args.contains('--label')
          ? args[args.indexOf('--label') + 1]
          : p.basenameWithoutExtension(args.first);
      final rawCases = jsonDecode(File(args.first).readAsStringSync())
          as List<dynamic>;
      final evalCases = [
        for (final raw in rawCases)
          EvalCase.fromJson(raw as Map<String, dynamic>),
      ];
      final evalReport = await EvalHarness(
        runner: (c) async {
          final sw = Stopwatch()..start();
          final outcome = await rt.chatWithStatus(
            c.prompt,
            sessionId: 'eval:$evalLabel',
            channel: 'eval',
            userKey: 'eval',
          );
          sw.stop();
          return EvalTurnResult(
            text: outcome.text,
            success: outcome.success,
            tokensUsed: outcome.tokensUsed,
            latencyMs: sw.elapsedMilliseconds,
            toolCalls: outcome.toolCallTraces,
          );
        },
      ).run(evalCases, label: evalLabel);
      final artifactDir = Directory(p.join(rt.dataDir, 'eval'))
        ..createSync(recursive: true);
      final artifact = p.join(
        artifactDir.path,
        '${DateTime.now().toUtc().millisecondsSinceEpoch}-$evalLabel.json',
      );
      File(artifact).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(evalReport.toJson()),
      );
      emit(evalReport.toJson(),
          'eval: ${evalCases.length} kasus, laporan disimpan di $artifact');
      return;

    case 'batch':
      // P5 Hermes-parity: batch processing + trajektori export.
      if (args.isEmpty) {
        stderr.writeln('subcommand batch wajib: run | export');
        exitCode = 2;
        return;
      }
      final batchSub = args.first;
      final batchArgs = args.skip(1).toList();
      if (batchSub == 'run') {
        final tasksPath = optValue(batchArgs, '--tasks');
        if (tasksPath == null || tasksPath.trim().isEmpty) {
          stderr.writeln('batch run membutuhkan --tasks <file.jsonl>');
          exitCode = 2;
          return;
        }
        final tasksFile = File(tasksPath);
        if (!tasksFile.existsSync()) {
          stderr.writeln('file tasks tidak ditemukan: $tasksPath');
          exitCode = 2;
          return;
        }
        final rawLabel = optValue(batchArgs, '--label')?.trim() ?? '';
        final label = (rawLabel.isNotEmpty
                ? rawLabel
                : p.basenameWithoutExtension(tasksPath))
            .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final concurrencyRaw = optValue(batchArgs, '--concurrency');
        var concurrency = 1;
        if (concurrencyRaw != null) {
          concurrency = int.tryParse(concurrencyRaw) ?? -1;
          if (concurrency < 1 || concurrency > maxConcurrency) {
            stderr.writeln('--concurrency harus 1..$maxConcurrency');
            exitCode = 2;
            return;
          }
        }
        final List<BatchTaskSpec> specs;
        try {
          specs = parseBatchTasksJsonl(tasksFile.readAsStringSync());
        } on FormatException catch (e) {
          stderr.writeln('tasks JSONL tidak valid: ${e.message}');
          exitCode = 2;
          return;
        }
        final outcome = await runBatch(
          specs: specs,
          label: label,
          concurrency: concurrency,
          logger: TrajectoryLogger(
            directory: p.join(rt.dataDir, 'trajectories'),
          ),
          executor: (spec, sessionId) async {
            final sw = Stopwatch()..start();
            final res = await rt.chatWithStatus(
              spec.prompt,
              sessionId: sessionId,
              channel: 'batch',
              userKey: 'batch',
            );
            sw.stop();
            return (
              output: res.text,
              tools: [for (final t in res.toolCallTraces) t.name],
              success: res.success,
              latencyMs: sw.elapsedMilliseconds,
              tokensUsed: res.tokensUsed,
            );
          },
        );
        final report = buildBatchReport(
          label: label,
          concurrency: concurrency,
          outcome: outcome,
        );
        final artifact = batchArtifactPath(dataDir: rt.dataDir, label: label);
        Directory(p.dirname(artifact)).createSync(recursive: true);
        File(artifact).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report),
        );
        emit(report, 'batch: ${specs.length} task, laporan disimpan di $artifact');
        return;
      }
      if (batchSub == 'export') {
        final outPath = optValue(batchArgs, '--out');
        if (outPath == null || outPath.trim().isEmpty) {
          stderr.writeln('batch export membutuhkan --out <file.jsonl>');
          exitCode = 2;
          return;
        }
        if (File(outPath).existsSync()) {
          stderr.writeln(
              'file output sudah ada; pilih nama lain agar data lama tidak tertimpa: $outPath');
          exitCode = 2;
          return;
        }
        final sharegpt = hasFlag(batchArgs, '--sharegpt');
        final redact = !hasFlag(batchArgs, '--no-redact');
        final exclude = <String>{
          for (var i = 0; i < batchArgs.length; i++)
            if (batchArgs[i] == '--exclude-session' &&
                i + 1 < batchArgs.length)
              batchArgs[i + 1],
        };
        final logger = TrajectoryLogger(
          directory: p.join(rt.dataDir, 'trajectories'),
        );
        final count = sharegpt
            ? await logger.exportShareGpt(
                outputPath: outPath,
                excludeSessions: exclude,
                redactSecrets: redact,
              )
            : await logger.exportForTraining(
                outputPath: outPath,
                excludeSessions: exclude,
                redactSecrets: redact,
              );
        final format = sharegpt ? 'sharegpt' : 'jsonl';
        emit(
          {
            'ok': true,
            'exported': count,
            'out': outPath,
            'format': format,
            'redact': redact,
          },
          'batch export: $count entri ditulis ke $outPath '
              '($format${redact ? '' : ', tanpa redaksi'})',
        );
        return;
      }
      stderr.writeln("subcommand batch tidak dikenal: '$batchSub' (run | export)");
      exitCode = 2;
      return;

    case 'acp':
      // ACP (Agent Client Protocol) agent side over stdio: IDEs that speak
      // ACP (Zed, VS Code extensions) drive the agent through JSON-RPC 2.0.
      final acp = AcpAgent(
        handler: (sid, prompt) => rt.chat(
          prompt,
          sessionId: 'acp:$sid',
          channel: 'acp',
        ),
        sessionLoader: (sid) async {
          final key = 'acp:$sid';
          final all = await rt.sessions.list();
          if (!all.any((s) => s.id == key)) return null;
          final recent = await rt.sessions.recent(key, limit: 50);
          return [
            for (final m in recent)
              if (m.role == 'user' || m.role == 'assistant')
                AcpHistoryEntry(role: m.role, text: m.content),
          ];
        },
      );
      await acp.serve();
      return;

    case 'context':
      // A.1: tampilkan project context file yang aktif untuk turn berikut.
      final proj = resolveProjectContextFile(workspaceRoot: rt.workspace);
      if (proj == null) {
        final names = kProjectContextCandidates.join(' | ');
        stdout.writeln(
          'Tidak ada project context file. Buat salah satu: $names '
          'di root workspace (${rt.workspace}) — isi otomatis masuk system '
          'prompt setiap turn (batas 12.000 karakter).',
        );
        return;
      }
      if (jsonOut) {
        emit({
          'ok': true,
          'file': proj.fileName,
          'path': proj.filePath,
          'chars': proj.content.length,
          'truncated': proj.truncated,
        }, 'project context: ${proj.fileName}');
        return;
      }
      stdout.writeln(
        'Project context aktif: ${proj.fileName} (${proj.filePath}, '
        '${proj.content.length} karakter${proj.truncated ? ', dipotong ke 12.000' : ''})',
      );
      stdout.writeln(proj.content);
      return;

    case 'fix':
      // Fase B — loop coding/debugging otomatis: tugas → edit → verify
      // objektif → umpan balik error → selesai/terbatas iterasi.
      final positional = <String>[];
      String? verifyCmd;
      var iters = 3;
      for (var i = 0; i < args.length; i++) {
        if (args[i] == '--verify') {
          if (i + 1 >= args.length) {
            stderr.writeln('--verify butuh nilai perintah');
            exitCode = 2;
            return;
          }
          verifyCmd = args[++i];
        } else if (args[i] == '--iter') {
          if (i + 1 >= args.length) {
            stderr.writeln('--iter butuh angka');
            exitCode = 2;
            return;
          }
          iters = int.tryParse(args[++i]) ?? -1;
          if (iters < 1 || iters > 8) {
            stderr.writeln('--iter harus 1..8');
            exitCode = 2;
            return;
          }
        } else {
          positional.add(args[i]);
        }
      }
      final task = positional.join(' ').trim();
      if (task.isEmpty) {
        stderr.writeln('pemakaian: tiko fix "<tugas>" --verify "<perintah>" [--iter 1-8]');
        stderr.writeln('contoh: tiko fix "rapikan lib/src/a.dart" --verify "dart analyze"');
        exitCode = 2;
        return;
      }
      final vcmd = (verifyCmd ?? '').trim();
      if (vcmd.isEmpty) {
        stderr.writeln('--verify wajib (gate objektif): tanpa perintah verifikasi, loop '
            'tidak jujur menyatakan sukses. contoh: --verify "dart analyze"');
        exitCode = 2;
        return;
      }
      if (!jsonOut) {
        stdout.writeln('Mulai loop fix ($iters iterasi maks) — gate: $vcmd');
        stdout.writeln('Checkpoint dibuat sebelum edit pertama (.tiko/checkpoints).');
      }
      final fixRes = await rt.runCodeFixLoop(
        task: task,
        verifyCommand: vcmd,
        maxIterations: iters,
        onToolStart: jsonOut
            ? null
            : (tool) => stdout.writeln('[tool] $tool …'),
      );
      emit(fixRes.toJson(), fixRes.success
          ? 'OK: ${fixRes.summary}'
          : 'GAGAL: ${fixRes.summary}');
      exitCode = fixRes.success ? 0 : 1;
      return;

    case 'team':
      // Fase C — orkestra bot team: plan → DAG paralel → sintesis → review
      // → gate verifikasi opsional. Tim tersimpan di data/teams/<id>.json.
      final sub = args.isEmpty ? 'help' : args.first.trim();
      final teamArgs = args.skip(1).toList();
      Future<void> helpTeam() async {
        stderr.writeln(
          "pemakaian: tiko team list | show <id> | delete <id> | "
          "save <id> --name N --member '<json>' ... | "
          'run "<tujuan>" [--team ID] [--verify "<cmd>"] [--concurrency N]',
        );
        exitCode = 2;
      }
      switch (sub) {
        case 'list':
          final saved = rt.botTeamStore.list();
          if (jsonOut) {
            emit({
              'teams': [for (final t in saved) t.toJson()],
              'builtin_members':
                  [for (final m in AgentTeamTool.defaultRegistry.all) m.id],
            }, '');
          } else if (saved.isEmpty) {
            stdout.writeln(
              "Belum ada tim tersimpan. Tim bawaan tersedia always-on: "
              '${AgentTeamTool.defaultRegistry.all.map((m) => m.id).join(', ')} '
              "(id per node). Simpan tim: tiko team save <id> --name N "
              "--member '<json>'.",
            );
          } else {
            for (final t in saved) {
              stdout.writeln(
                '${t.id.padRight(20)} ${t.name} '
                '(${t.members.length} anggota: '
                '${t.members.map((m) => m.id).join(', ')})',
              );
            }
          }
          return;
        case 'show':
          final id = teamArgs.isEmpty ? '' : teamArgs.first.trim();
          final doc = id.isEmpty ? null : rt.botTeamStore.get(id);
          if (doc == null) {
            emit(
              {'ok': false, 'error': 'team "$id" tidak ditemukan'},
              'Tim "$id" tidak ditemukan.');
            exitCode = 1;
            return;
          }
          emit(doc.toJson(),
              const JsonEncoder.withIndent('  ').convert(doc.toJson()));
          return;
        case 'delete':
          final id = teamArgs.isEmpty ? '' : teamArgs.first.trim();
          if (id.isEmpty) {
            stderr.writeln('pemakaian: tiko team delete <id>');
            exitCode = 2;
            return;
          }
          final removed = await rt.botTeamStore.delete(id);
          emit(
            {'ok': removed, 'id': id},
            removed ? 'Tim "$id" dihapus.' : 'Tim "$id" tidak ditemukan.');
          exitCode = removed ? 0 : 1;
          return;
        case 'save':
          final id = teamArgs.isEmpty ? '' : teamArgs.first.trim();
          if (id.isEmpty || !BotTeamDoc.isValidId(id)) {
            stderr.writeln(
              'id tim harus cocok [a-z0-9][a-z0-9_-]{0,63}');
            exitCode = 2;
            return;
          }
          String? name;
          var desc = '';
          final memberJsons = <String>[];
          for (var i = 0; i < teamArgs.length; i++) {
            if (teamArgs[i] == '--name' && i + 1 < teamArgs.length) {
              name = teamArgs[++i];
            } else if (teamArgs[i] == '--desc' && i + 1 < teamArgs.length) {
              desc = teamArgs[++i];
            } else if (teamArgs[i] == '--member' &&
                i + 1 < teamArgs.length) {
              memberJsons.add(teamArgs[++i]);
            }
          }
          if ((name ?? '').trim().isEmpty || memberJsons.isEmpty) {
            stderr.writeln(
              '--name dan minimal satu --member wajib. contoh member: '
              '{"id":"coder","prompt":"Kamu coder ...","tools":'
              '["read_file","write_file","patch_file"],"max_turns":6}');
            exitCode = 2;
            return;
          }
          final members = <AgentSpec>[];
          for (final raw in memberJsons) {
            try {
              final map = jsonDecode(raw);
              if (map is! Map) {
                stderr.writeln('member harus objek JSON: $raw');
                exitCode = 2;
                return;
              }
              final m = Map<String, dynamic>.from(map);
              m['system_prompt'] ??= m.remove('prompt');
              m['tool_allowlist'] ??= m.remove('tools');
              m['model_tier'] ??= m.remove('tier');
              m['max_turns'] ??= m.remove('max_turns');
              final spec = AgentSpec.fromJson(m);
              if (spec.id.trim().isEmpty ||
                  spec.systemPrompt.trim().isEmpty) {
                stderr.writeln('member butuh id dan prompt: $raw');
                exitCode = 2;
                return;
              }
              members.add(AgentSpec(
                id: spec.id.trim(),
                role: spec.role,
                systemPrompt: spec.systemPrompt.trim(),
                toolAllowlist: spec.toolAllowlist,
                modelTier: spec.modelTier,
                maxTurns: spec.maxTurns,
              ));
            } on FormatException catch (e) {
              stderr.writeln('member JSON tidak valid: $e');
              exitCode = 2;
              return;
            }
          }
          final savedDoc = await rt.botTeamStore.save(BotTeamDoc(
            id: id,
            name: (name ?? '').trim(),
            description: desc,
            members: members,
          ));
          emit(
            savedDoc.toJson(),
            'Tim "${savedDoc.id}" tersimpan '
            '(${savedDoc.members.length} anggota).');
          return;
        case 'run':
          final goalArgs = <String>[];
          String? runTeam;
          String? runVerify;
          var concurrency = 4;
          for (var i = 0; i < teamArgs.length; i++) {
            if (teamArgs[i] == '--team' && i + 1 < teamArgs.length) {
              runTeam = teamArgs[++i];
            } else if (teamArgs[i] == '--verify' &&
                i + 1 < teamArgs.length) {
              runVerify = teamArgs[++i];
            } else if (teamArgs[i] == '--concurrency' &&
                i + 1 < teamArgs.length) {
              concurrency = int.tryParse(teamArgs[++i]) ?? -1;
              if (concurrency < 1 || concurrency > 8) {
                stderr.writeln('--concurrency harus 1..8');
                exitCode = 2;
                return;
              }
            } else {
              goalArgs.add(teamArgs[i]);
            }
          }
          final goal = goalArgs.join(' ').trim();
          if (goal.isEmpty) {
            stderr.writeln(
              'pemakaian: tiko team run "<tujuan>" [--team ID] '
              '[--verify "<cmd>"] [--concurrency N]');
            exitCode = 2;
            return;
          }
          if (runTeam != null && rt.botTeamStore.get(runTeam) == null) {
            stderr.writeln('tim "$runTeam" tidak ditemukan (tiko team list)');
            exitCode = 2;
            return;
          }
          if (!jsonOut) {
            stdout.writeln(
              'Orkestra tim dimulai${runTeam == null ? '' : ' ($runTeam)'} '
              '— tujuan: $goal');
          }
          final teamRes = await rt.runBotTeam(
            goal: goal,
            teamId: runTeam,
            verifyCommand: (runVerify ?? '').trim().isEmpty
                ? null
                : (runVerify ?? '').trim(),
            maxConcurrency: concurrency,
            onNodeEvent: jsonOut
                ? null
                : (node, agent, starting) => stdout.writeln(
                    starting
                        ? '[team] node $node dimulai oleh $agent …'
                        : '[team] node $node selesai ($agent)',
                  ),
          );
          emit(teamRes.toJson(), teamRes.success
              ? 'OK: ${teamRes.synthesis}'
              : 'GAGAL: ${teamRes.review ?? teamRes.synthesis}');
          exitCode = teamRes.success ? 0 : 1;
          return;
        default:
          await helpTeam();
          return;
      }


    case 'research':
      // Fase D — riset otomatis: run satu kali atau terjadwal via scheduler
      // (job ber-prefix [RISET]); laporan tersimpan di data/research dan
      // tiap run dicerminkan ke papan Kanban data/kanban.json.
      final rSub = args.isEmpty ? 'run' : args.first.trim();
      final rArgs = rSub == 'run' ? args.toList() : args.skip(1).toList();
      Future<void> helpResearch() async {
        stderr.writeln(
          'pemakaian: tiko research "<pertanyaan>" [--concurrency N] | '
          "runs | show <id> | "
          'schedule "<pertanyaan>" --cron "0 8 * * *" [--tz Zona]');
        exitCode = 2;
      }
      switch (rSub) {
        case 'runs':
          final runs = rt.researchRunStore.runs;
          if (jsonOut) {
            emit({
              'runs': [for (final r in runs) r.toJson()],
            }, '');
          } else if (runs.isEmpty) {
            stdout.writeln(
              'Belum ada run riset. Mulai: tiko research "<pertanyaan>" '
              'atau tiko research schedule.');
          } else {
            for (final r in runs) {
              final q = r.question.length > 48
                  ? '${r.question.substring(0, 47)}…'
                  : r.question;
              stdout.writeln(
                '${r.runId.padRight(14)} ${r.status.padRight(7)} '
                '${r.finishedAt.toLocal().toIso8601String()} $q');
            }
          }
          return;
        case 'show':
          final id = rArgs.isEmpty ? '' : rArgs.first.trim();
          final record = id.isEmpty ? null : rt.researchRunStore.get(id);
          if (record == null) {
            emit({'ok': false, 'error': 'run "$id" tidak ditemukan'},
                'Run riset "$id" tidak ditemukan (tiko research runs).');
            exitCode = 1;
            return;
          }
          final report =
              await rt.researchRunStore.readReport(record.reportName);
          emit(record.toJson(),
              report ?? '(laporan tidak ditemukan)');
          return;
        case 'schedule':
          final qArgs = <String>[];
          String? cron;
          String? tz;
          for (var i = 0; i < rArgs.length; i++) {
            if (rArgs[i] == '--cron' && i + 1 < rArgs.length) {
              cron = rArgs[++i];
            } else if (rArgs[i] == '--tz' && i + 1 < rArgs.length) {
              tz = rArgs[++i];
            } else {
              qArgs.add(rArgs[i]);
            }
          }
          final question = qArgs.join(' ').trim();
          if (question.isEmpty || (cron ?? '').trim().isEmpty) {
            stderr.writeln(
              'pemakaian: tiko research schedule "<pertanyaan>" '
              '--cron "0 8 * * *" [--tz Asia/Jakarta]');
            exitCode = 2;
            return;
          }
          try {
            final job = await rt.scheduleResearch(
              question: question,
              cron: cron!,
              timezone: (tz ?? '').trim().isEmpty ? 'UTC' : tz!.trim(),
            );
            emit(job.toJson(),
              'Riset terjadwal job=${job.id} cron=${job.cron} '
              'tz=${job.timezone} next=${job.nextRun.toIso8601String()}');
          } catch (e) {
            emit({'ok': false, 'error': '$e'}, 'Gagal membuat job riset: $e');
            exitCode = 1;
          }
          return;
        case 'jobs':
          final jobs = rt.researchJobs();
          if (jsonOut) {
            emit({
              'jobs': [for (final j in jobs) j.toJson()],
            }, '');
          } else if (jobs.isEmpty) {
            stdout.writeln(
              'Belum ada riset terjadwal. tiko research schedule '
              '"<pertanyaan>" --cron "0 8 * * *".');
          } else {
            for (final j in jobs) {
              stdout.writeln(
                '${j.id.padRight(14)} ${j.enabled ? "ON " : "OFF"} '
                '${j.cron} tz=${j.timezone} '
                'next=${j.nextRun.toIso8601String()}');
            }
          }
          return;
        case 'run':
        default:
          final qArgs = <String>[];
          var concurrency = 3;
          final scan = rSub == 'run' ? rArgs.skip(1).toList() : rArgs;
          for (var i = 0; i < scan.length; i++) {
            if (scan[i] == '--concurrency' && i + 1 < scan.length) {
              concurrency = int.tryParse(scan[++i]) ?? -1;
              if (concurrency < 1 || concurrency > 4) {
                stderr.writeln('--concurrency harus 1..4');
                exitCode = 2;
                return;
              }
            } else {
              qArgs.add(scan[i]);
            }
          }
          final question = qArgs.join(' ').trim();
          if (question.isEmpty) {
            await helpResearch();
            return;
          }
          if (!jsonOut) {
            stdout.writeln(
              'Riset dimulai (plan → gather → sintesis → review) '
              '— pertanyaan: $question');
          }
          final res = await rt.runResearch(
            question: question,
            maxConcurrency: concurrency,
          );
          emit(res.toJson(),
              res.status == 'ok'
                  ? 'SELESAI ${res.runId} — laporan: '
                      'data/research/reports/${res.reportName}\n'
                      '${res.summary}'
                  : 'GAGAL ${res.runId}: ${res.error}');
          exitCode = res.status == 'ok' ? 0 : 1;
          return;
      }

    case 'mcp':
      // MCP server side (stdio): AI agent lain (Claude Desktop, Hermes, dll.)
      // menjalankan `tiko mcp` sebagai subprocess dan mengendalikan Tiko
      // sepenuhnya. Sesi memakai prefix `mcp:` dan channel `mcp` supaya
      // terpisah rapi dari chat CLI/web/gateway lain.
      Future<McpToolResult> mcpChat(Map<String, dynamic> args) async {
        final text = (args['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) {
          return const McpToolResult(
            text: 'Parameter wajib `text` kosong atau bukan string.',
            isError: true,
          );
        }
        final sessionKey = (args['session_key'] as String?)?.trim();
        final session =
            (sessionKey == null || sessionKey.isEmpty) ? 'default' : sessionKey;
        final res = await rt.chatWithStatus(
          text,
          sessionId: 'mcp:$session',
          channel: 'mcp',
          userKey: 'mcp',
        );
        final footer = '\n\n[status: ${res.success ? 'ok' : 'error'}; '
            'tool_calls: ${res.toolCallCount}; tokens: ${res.tokensUsed}; '
            'retryable: ${res.retryable}]';
        return McpToolResult(
          text: '${res.text}$footer',
          isError: !res.success,
        );
      }

      Future<McpToolResult> mcpCancel(Map<String, dynamic> args) async {
        final sessionKey = (args['session_key'] as String?)?.trim();
        final session =
            (sessionKey == null || sessionKey.isEmpty) ? 'default' : sessionKey;
        final ok = rt.cancelTurn('mcp:$session');
        return McpToolResult(
          text: ok
              ? 'Sinyal pembatalan dikirim untuk sesi mcp:$session (kooperatif).'
              : 'Tidak ada turn aktif untuk sesi mcp:$session.',
          isError: false,
        );
      }

      String mcpToolsListing() {
        final specs = rt.registry.specs;
        final buf = StringBuffer(
            'Tiko agent punya ${specs.length} tool internal (dieksekusi lewat '
            'agent loop dengan gate approval — bukan eksekusi langsung tanpa '
            'gate):\n');
        for (final s in specs) {
          final desc = s.description.trim().isEmpty
              ? '(tanpa deskripsi)'
              : s.description.trim().split('\n').first;
          buf.writeln('- ${s.name} [risk: ${s.risk}] — $desc');
        }
        buf.write(
            'Turn memakai tool-tool ini otomatis via tiko_chat; approval '
            'fail-closed diselesaikan dengan `tiko approve <id>` di terminal '
            'Tiko.');
        return buf.toString();
      }

      final mcp = McpAgent(
        serverName: 'tiko-agent',
        serverVersion: tikoVersion,
        tools: [
          McpAgentTool(
            name: 'tiko_chat',
            description:
                'Jalankan satu turn chat penuh pada Tiko agent (ReAct agent '
                'loop dengan seluruh tool internal + gate approval). Parameter: '
                'text (wajib), session_key (opsional, default "default"). '
                'Tanpa confirm — approval tool berisiko fail-closed dan harus '
                'disetujui dengan `tiko approve <id>` di terminal Tiko.',
            inputSchema: {
              'type': 'object',
              'properties': {
                'text': {
                  'type': 'string',
                  'description': 'Pesan/prompt pengguna untuk Tiko agent.',
                },
                'session_key': {
                  'type': 'string',
                  'description':
                      'Kunci sesi logis; dipetakan ke sesi `mcp:<session_key>`.',
                },
              },
              'required': ['text'],
            },
            handler: mcpChat,
          ),
          McpAgentTool(
            name: 'tiko_cancel',
            description:
                'Batalkan turn yang sedang berjalan pada sesi Tiko '
                '(kooperatif). Parameter: session_key (opsional).',
            inputSchema: {
              'type': 'object',
              'properties': {
                'session_key': {
                  'type': 'string',
                  'description': 'Kunci sesi yang sama dengan tiko_chat.',
                },
              },
            },
            handler: mcpCancel,
          ),
          McpAgentTool(
            name: 'tiko_tools',
            description:
                'Daftar tool internal Tiko (nama, deskripsi, level risiko) '
                'yang dipakai agent loop saat turn berjalan.',
            inputSchema: {'type': 'object', 'properties': {}},
            handler: (_) async => McpToolResult(text: mcpToolsListing()),
          ),
          McpAgentTool(
            name: 'tiko_sessions',
            description: 'Daftar sesi Tiko yang tersimpan (id, channel, judul).',
            inputSchema: {'type': 'object', 'properties': {}},
            handler: (_) async {
              final all = await rt.sessions.list();
              if (all.isEmpty) {
                return const McpToolResult(text: 'Belum ada sesi tersimpan.');
              }
              final buf = StringBuffer('Sesi tersimpan (${all.length}):\n');
              for (final s in all) {
                final title = (s.title == null || s.title!.isEmpty)
                    ? '(tanpa judul)'
                    : s.title;
                buf.writeln(
                    '- ${s.id} [channel: ${s.channel}, turn: ${s.turns}] — $title');
              }
              return McpToolResult(text: buf.toString());
            },
          ),
          McpAgentTool(
            name: 'tiko_status',
            description: 'Status runtime Tiko (versi, jumlah tool terdaftar).',
            inputSchema: {'type': 'object', 'properties': {}},
            handler: (_) async => McpToolResult(
              text: 'Tiko v$tikoVersion; runtime: local-first; '
                  'tool_count: ${rt.registry.specs.length}.',
            ),
          ),
        ],
      );
      await mcp.serve();
      return;

    case 'chat':
    case 'run':
      final prompt = args.join(' ').trim();
      if (cmd == 'run' && prompt.isEmpty) {
        stderr.writeln('run membutuhkan prompt');
        exitCode = 2;
        return;
      }
      // mode auto: reuse daemon if alive; daemon mode starts it
      if (mode == 'daemon' || mode == 'auto') {
        final st = await daemon.status();
        if (st['running'] == true) {
          stdout.writeln('(mode $mode: memakai daemon pid=${st['pid']})');
          final tok = await ApiTokenStore.read(rt.dataDir);
          if (tok != null && tok.isNotEmpty && (mode == 'daemon' || mode == 'auto')) {
            final port = st['port'] ?? rt.config.apiPort;
            final remote = TikoRemoteClient(
              baseUrl: 'http://127.0.0.1:$port',
              token: tok,
            );
            if (await remote.health()) {
              if (prompt.isNotEmpty) {
                final ans = await remote.chat(prompt);
                stdout.writeln(ans);
                return;
              }
              await TuiSession(
                handler: (input) async {
                  if (input == '/help') {
                    return const TuiOutcome([
                      'Perintah Tiko:',
                      '  /help      bantuan singkat',
                      '  /status    provider dan runtime aktif',
                      '  /doctor    pemeriksaan kesehatan',
                      '  /settings  ubah konfigurasi interaktif',
                      '  /clear     bersihkan terminal',
                      '  /quit      keluar',
                      'Teks biasa dikirim ke agent. Tab melengkapi /command.',
                    ]);
                  }
                  if (input == '/clear') {
                    return const TuiOutcome([], clear: true);
                  }
                  if (input == '/quit' || input == '/exit') {
                    return const TuiOutcome([], exit: true);
                  }
                  if (input == '/settings') {
                    return await openSettingsShortcut();
                  }
                  try {
                    return TuiOutcome(['tiko> ${await remote.chat(input)}']);
                  } catch (e) {
                    return TuiOutcome(['error: $e']);
                  }
                },
                completer: chatCompleter,
                historyStore: TuiHistoryStore(
                  p.join(rt.dataDir, 'tui-history.txt'),
                ),
                banner: [
                  '╭─ Tiko Chat · remote daemon ─╮',
                  '│ provider: ${rt.config.defaultProvider}',
                  '│ /help bantuan · /settings konfigurasi · /quit keluar',
                  '╰──────────────────────────────╯',
                ],
                prompt: 'you> ',
              ).run();
              return;
            }
          }
        } else if (mode == 'daemon') {
          final r = await daemon.start();
          stdout.writeln('daemon: ${r['action']} $r');
        }
      }
      if (prompt.isNotEmpty) {
        final answer = await rt.chat(prompt, confirm: askUser);
        stdout.writeln(answer);
        bus.emit('chat', {'prompt': prompt});
        return;
      }
      // interactive
      TuiProgress? turnProgress;
      await TuiSession(
        handler: (input) async {
          if (input == '/help') {
            return const TuiOutcome([
              'Perintah Tiko:',
              '  /help      bantuan singkat',
              '  /status    provider dan runtime aktif',
              '  /doctor    pemeriksaan kesehatan',
              '  /settings  ubah konfigurasi interaktif',
              '  /clear     bersihkan terminal',
              '  /quit      keluar',
              'Teks biasa dikirim ke agent. Tab melengkapi /command.',
            ]);
          }
          if (input == '/clear') {
            return const TuiOutcome([], clear: true);
          }
          if (input == '/quit' || input == '/exit') {
            return const TuiOutcome([], exit: true);
          }
          if (input == '/settings') {
            return await openSettingsShortcut();
          }
          if (input == '/doctor') {
            return TuiOutcome([
              for (final c in await rt.doctor())
                '${c.status.name} ${c.name}: ${c.detail}',
            ]);
          }
          if (input == '/status') {
            return TuiOutcome([
              'provider=${rt.config.defaultProvider} '
                  'memory=${rt.memoryBackend}',
            ]);
          }
          // TUI-P3: progress live — status tool/durasi saat turn berjalan,
          // ringkasan tool setelah respons, Ctrl-C kooperatif membatalkan.
          final p = turnProgress;
          final traces = <ToolCallTrace>[];
          final res = await rt.chatWithStatus(
            input,
            confirm: askUser,
            onToolStart:
                p == null ? null : (name) => p.status('tool $name…'),
            onToolTrace: (t) {
              traces.add(t);
              p?.status(
                'tool ${t.name} ${t.isError ? 'gagal' : 'selesai'} '
                '(${(t.durationMs / 1000).toStringAsFixed(1)}s)',
              );
            },
          );
          final lines = <String>['tiko> ${res.text}'];
          if (res.toolCallTraces.isNotEmpty) {
            lines.add('tools: ${res.toolCallCount} call · '
                '${res.tokensUsed} token');
            for (final t in res.toolCallTraces) {
              lines.add('  [${t.isError ? 'err' : 'ok'}] ${t.name} '
                  '${(t.durationMs / 1000).toStringAsFixed(1)}s');
            }
          }
          return TuiOutcome(lines);
        },
        completer: chatCompleter,
        onTurnStart: (progress) => turnProgress = progress,
        onCancelKey: () => rt.cancelTurn('cli:default'),
        historyStore: TuiHistoryStore(
          p.join(rt.dataDir, 'tui-history.txt'),
        ),
        banner: [
          '╭─ Tiko Chat · embedded ────────╮',
          '│ provider: ${rt.config.defaultProvider}',
          '│ /help bantuan · /settings konfigurasi · /quit keluar',
          '╰───────────────────────────────╯',
        ],
        prompt: 'you> ',
      ).run();
      return;

    default:
      stderr.writeln('Perintah tidak dikenal: $cmd\n');
      stdout.write(_usage);
      exitCode = 2;
    }
  } finally {
    await rt.close();
  }
}

Future<void> _configCmd(
  ConfigStore store,
  List<String> args,
  void Function(Object, String) emit,
  bool jsonOut,
) async {
  if (args.isEmpty) {
    stderr.writeln('config show|validate|get|set|diff|history|rollback');
    exitCode = 2;
    return;
  }
  final sub = args.first;
  switch (sub) {
    case 'validate':
      final (cfg, issues) = TikoConfig.load(store.configPath);
      if (issues.isEmpty) {
        emit({'ok': true}, 'config OK provider=${cfg.defaultProvider}');
      } else {
        for (final i in issues) {
          stdout.writeln(i);
        }
        exitCode = issues.any((x) => x.fatal) ? 1 : 0;
      }
    case 'show':
      final text = await File(store.configPath).readAsString();
      // Do not echo raw credential values from arbitrary future config keys.
      final redacted = text.split('\n').map((line) {
        final trimmed = line.trimLeft();
        final key = trimmed.split(':').first.toLowerCase().replaceAll('-', '_');
        final secretLike = RegExp(r'(api_key|token|secret|password|credential|private_key|webhook)').hasMatch(key);
        if (secretLike && !trimmed.toLowerCase().contains('env:')) {
          final indent = line.substring(0, line.length - trimmed.length);
          return '$indent$key: [REDACTED]';
        }
        return line;
      }).join('\n');
      stdout.writeln(redacted);
    case 'get':
      if (args.length < 2) {
        exitCode = 2;
        return;
      }
      final (cfg, _) = TikoConfig.load(store.configPath);
      stdout.writeln(getCfg(cfg, args[1]));
    case 'set':
      if (args.length < 3) {
        stderr.writeln('config set <path> <value>');
        exitCode = 2;
        return;
      }
      final r = await store.setPath(args[1], args.sublist(2).join(' '));
      if (r.issues.any((i) => i.fatal)) {
        for (final i in r.issues) {
          stdout.writeln(i);
        }
        exitCode = 1;
      } else {
        emit({'revision': r.revision}, 'OK revision ${r.revision}');
      }
    case 'diff':
      int? rev;
      if (args.length >= 3 && args[1] == '--revision') {
        rev = int.tryParse(args[2]);
      }
      stdout.writeln(await store.diff(revision: rev));
    case 'history':
      final h = await store.history();
      for (final m in h) {
        stdout.writeln('r${m['revision']} ${m['at']} ${m['actor']} ${m['note']}');
      }
    case 'rollback':
      if (args.length < 2) {
        exitCode = 2;
        return;
      }
      final to = int.parse(args[1]);
      final r = await store.rollback(to);
      emit({'revision': r.revision}, 'rollback -> r${r.revision}');
    default:
      exitCode = 2;
  }
}

Future<void> _handleRemoteApprovals(
  String configPath,
  String command,
  List<String> args, {
  required bool jsonOut,
}) async {
  final (config, issues) = TikoConfig.load(configPath);
  final fatal = issues.where((issue) => issue.fatal).toList();
  if (fatal.isNotEmpty) {
    for (final issue in fatal) {
      stderr.writeln(issue);
    }
    stderr.writeln('Perbaiki config sebelum mengakses approval daemon.');
    exitCode = 1;
    return;
  }

  final configDir = p.dirname(p.absolute(configPath));
  final root = p.basename(configDir) == 'config' ? p.dirname(configDir) : configDir;
  final dataDir = p.isAbsolute(config.dataDir)
      ? config.dataDir
      : p.normalize(p.join(root, config.dataDir));
  String? token;
  try {
    token = await ApiTokenStore.read(dataDir);
  } catch (error) {
    stderr.writeln('File token daemon tidak aman/tidak dapat dibaca: $error');
    exitCode = 1;
    return;
  }
  if (token == null || token.isEmpty) {
    stderr.writeln('Token daemon tidak ditemukan di ${ApiTokenStore.pathFor(dataDir)}.');
    stderr.writeln('Jalankan daemon dengan API aktif, lalu ulangi perintah.');
    exitCode = 1;
    return;
  }

  final lockInfo = await RuntimeLock(p.join(dataDir, 'tiko.lock')).read();
  final lockPort = lockInfo != null && RuntimeLock.isAlive(lockInfo.pid)
      ? lockInfo.port
      : null;
  final envPort = int.tryParse(Platform.environment['API_PORT'] ?? '');
  final daemonPort = envPort != null && envPort >= 1 && envPort <= 65535
      ? envPort
      : lockPort ?? config.apiPort;
  final remote = TikoRemoteClient(
    baseUrl: 'http://127.0.0.1:$daemonPort',
    token: token,
  );
  try {
    if (!await remote.health()) {
      stderr.writeln('Daemon tidak aktif pada port $daemonPort.');
      exitCode = 1;
      return;
    }

    if (command == 'approvals') {
      final list = await remote.approvals(includeHistory: args.contains('--all'));
      if (jsonOut) {
        stdout.writeln(jsonEncode({'approvals': list}));
      } else if (list.isEmpty) {
        stdout.writeln('(tidak ada approval)');
      } else {
        for (final item in list) {
          stdout.writeln(
            '${item['id']}\t${item['state']}\t${item['tool']}\t${item['risk']}',
          );
        }
      }
      return;
    }

    if (args.isEmpty || args.first.isEmpty) {
      stderr.writeln('tiko $command <approval-id>');
      exitCode = 2;
      return;
    }
    final id = args.first;
    final approved = await remote.decideApproval(
      id,
      approve: command == 'approve',
    );
    if (!approved) {
      stderr.writeln('Approval tidak lagi pending, kedaluwarsa, atau tidak ditemukan: $id');
      exitCode = 1;
      return;
    }
    final state = command == 'approve' ? 'approved' : 'denied';
    if (jsonOut) {
      stdout.writeln(jsonEncode({'ok': true, 'id': id, 'state': state}));
    } else {
      stdout.writeln('$state $id');
    }
  } catch (error) {
    stderr.writeln('Gagal mengakses approval daemon: $error');
    exitCode = 1;
  }
}

/// Handler perintah `tiko surface ...` (Fase E3): semua operasi memakai
/// API daemon (`/v1/surfaces*`) karena state surface tersimpan di proses
/// daemon (memori + snapshot disk), bukan di runtime CLI ini.
Future<void> _handleRemoteSurfaces(
  String configPath,
  String command,
  List<String> args, {
  required bool jsonOut,
}) async {
  final (config, issues) = TikoConfig.load(configPath);
  final fatal = issues.where((issue) => issue.fatal).toList();
  if (fatal.isNotEmpty) {
    for (final issue in fatal) {
      stderr.writeln(issue);
    }
    stderr.writeln('Perbaiki config sebelum mengakses surface daemon.');
    exitCode = 1;
    return;
  }

  final configDir = p.dirname(p.absolute(configPath));
  final root = p.basename(configDir) == 'config' ? p.dirname(configDir) : configDir;
  final dataDir = p.isAbsolute(config.dataDir)
      ? config.dataDir
      : p.normalize(p.join(root, config.dataDir));
  String? token;
  try {
    token = await ApiTokenStore.read(dataDir);
  } catch (error) {
    stderr.writeln('File token daemon tidak aman/tidak dapat dibaca: $error');
    exitCode = 1;
    return;
  }
  if (token == null || token.isEmpty) {
    stderr.writeln('Token daemon tidak ditemukan di ${ApiTokenStore.pathFor(dataDir)}.');
    stderr.writeln('Jalankan daemon dengan API aktif, lalu ulangi perintah.');
    exitCode = 1;
    return;
  }

  final lockInfo = await RuntimeLock(p.join(dataDir, 'tiko.lock')).read();
  final lockPort = lockInfo != null && RuntimeLock.isAlive(lockInfo.pid)
      ? lockInfo.port
      : null;
  final envPort = int.tryParse(Platform.environment['API_PORT'] ?? '');
  final daemonPort = envPort != null && envPort >= 1 && envPort <= 65535
      ? envPort
      : lockPort ?? config.apiPort;
  final remote = TikoRemoteClient(
    baseUrl: 'http://127.0.0.1:$daemonPort',
    token: token,
  );

  String? sessionFilter;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--session' && i + 1 < args.length) {
      sessionFilter = args[++i];
    }
  }
  final positional = [
    for (var i = 0; i < args.length; i++)
      if (args[i] != '--session' &&
          (i == 0 || args[i - 1] != '--session'))
        args[i]
  ];

  try {
    switch (command) {
      case 'list':
        final list = await remote.surfaces(sessionKey: sessionFilter);
        if (jsonOut) {
          stdout.writeln(jsonEncode({'surfaces': list}));
        } else if (list.isEmpty) {
          stdout.writeln('(tidak ada surface)');
        } else {
          for (final item in list) {
            stdout.writeln(
              '${item['surfaceId']}\t${item['sessionKey']}\t'
              '${item['updatedAt']}',
            );
          }
        }
      case 'show':
        if (positional.isEmpty) {
          stderr.writeln('tiko surface show <id>');
          exitCode = 2;
          return;
        }
        final doc = await remote.surface(positional.first);
        if (doc == null) {
          stderr.writeln('Surface tidak ditemukan: ${positional.first}');
          exitCode = 1;
          return;
        }
        stdout.writeln(jsonOut ? jsonEncode(doc) : const JsonEncoder.withIndent('  ').convert(doc));
      case 'delete':
        if (positional.isEmpty) {
          stderr.writeln('tiko surface delete <id>');
          exitCode = 2;
          return;
        }
        final ok = await remote.deleteSurface(positional.first);
        if (!ok) {
          stderr.writeln('Surface tidak ditemukan atau gagal dihapus: ${positional.first}');
          exitCode = 1;
          return;
        }
        if (jsonOut) {
          stdout.writeln(jsonEncode({'ok': true, 'id': positional.first}));
        } else {
          stdout.writeln('dihapus ${positional.first}');
        }
      case 'catalogs':
        final res = await remote.surfaceCatalogs();
        if (jsonOut) {
          stdout.writeln(jsonEncode(res));
        } else {
          for (final cat in res['catalogs'] as List<dynamic>) {
            final catMap = cat as Map<String, dynamic>;
            stdout.writeln(
              '${catMap['catalogId']}\t${(catMap['components'] as List).join(', ')}',
            );
          }
        }
      default:
        stderr.writeln('surface list|show <id>|delete <id>|catalogs');
        exitCode = 2;
    }
  } catch (error) {
    stderr.writeln('Gagal mengakses surfaces daemon: $error');
    exitCode = 1;
  }
}

Future<void> _setup(String configPath, List<String> args) async {
  final setup = parseSetupArgs(
    args,
    onUnknown: (message) => stderr.writeln(message),
  );
  if (setup == null) {
    exitCode = 2;
    return;
  }
  final provider = setup.provider;
  final workspace = setup.workspace;
  final force = setup.force;
  final interactive = setup.interactive;

  if (interactive) {
    try {
      await _setupInteractive(configPath, force);
    } on PromptAborted {
      stdout.writeln();
      stdout.writeln('Setup dibatalkan.');
      exitCode = 130;
    }
    return;
  }

  final file = File(configPath);
  await file.parent.create(recursive: true);
  if (await file.exists() && !force) {
    final (existing, issues) = TikoConfig.load(file.path);
    if (issues.any((issue) => issue.fatal)) {
      stderr.writeln('Config sudah ada tetapi tidak valid:');
      for (final issue in issues) {
        stderr.writeln(issue);
      }
      stderr.writeln('Perbaiki config atau jalankan setup --force untuk membuat ulang.');
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Config sudah ada: ${p.absolute(configPath)} '
      '(provider=${existing.defaultProvider}); tidak diubah.',
    );
    stdout.writeln('Lanjut: tiko doctor --probe && tiko chat');
    return;
  }

  late final String yaml;
  try {
    yaml = TikoConfig.setupYaml(provider: provider, workspace: workspace);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
    return;
  }
  final (expected, expectedIssues) = TikoConfig.parse(yaml);
  if (expectedIssues.any((issue) => issue.fatal)) {
    stderr.writeln('Template internal setup gagal divalidasi:');
    for (final issue in expectedIssues) {
      stderr.writeln(issue);
    }
    exitCode = 1;
    return;
  }

  final configAbs = p.absolute(configPath);
  final configDir = p.dirname(configAbs);
  final projectRoot = p.basename(configDir) == 'config'
      ? p.dirname(configDir)
      : configDir;
  final dataDir = p.isAbsolute(expected.dataDir)
      ? expected.dataDir
      : p.join(projectRoot, expected.dataDir);
  final store = ConfigStore(
    configPath: configAbs,
    revisionsDir: p.join(dataDir, 'config_revisions'),
  );
  final result = await store.writeFull(yaml, note: 'setup');
  if (result.issues.any((issue) => issue.fatal)) {
    stderr.writeln('Setup dibatalkan; konfigurasi tidak disimpan:');
    for (final issue in result.issues) {
      stderr.writeln(issue);
    }
    exitCode = 1;
    return;
  }

  // Read back from disk and assert that the requested provider is truly active.
  final (actual, actualIssues) = TikoConfig.load(configAbs);
  if (actualIssues.any((issue) => issue.fatal) ||
      actual.defaultProvider != expected.defaultProvider ||
      !actual.providers.containsKey(actual.defaultProvider) ||
      !actual.providers[actual.defaultProvider]!.enabled) {
    stderr.writeln('Verifikasi konfigurasi setelah setup gagal; cek $configAbs.');
    for (final issue in actualIssues) {
      stderr.writeln(issue);
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'setup OK revision=${result.revision} '
    'provider=${actual.defaultProvider} type=${actual.providers[actual.defaultProvider]!.type}',
  );
  stdout.writeln('Config: $configAbs');
  if (setup.smoke) {
    final smokeOk = await _setupSmokeTurn(configAbs);
    if (!smokeOk) {
      exitCode = 1;
      return;
    }
  }
  stdout.writeln('Lanjut: tiko doctor --probe && tiko chat');
}

/// F1 (docs/15 §2) — satu turn agentic pasca-setup: bukti konfigurasi
/// benar-benar lewat loop tool, bukan hanya config valid. Deterministik:
/// mock `assisted` memanggil tool `calc` untuk pertanyaan hitungan.
/// Tidak pernah throw — kegagalan menghasilkan `false` + pesan.
Future<bool> _setupSmokeTurn(String configAbs) async {
  stdout.writeln('Smoke (F1): menjalankan satu turn agentic uji...');
  TikoRuntime? rt;
  try {
    rt = await TikoRuntime.create(configPath: configAbs);
    final sw = Stopwatch()..start();
    final run = await rt.chatWithStatus(
      'hitung 5+1',
      sessionId: 'cli:setup-smoke',
      channel: 'cli',
      userKey: 'setup',
    );
    sw.stop();
    final ok = run.success && run.toolCallCount > 0 && run.text.contains('6');
    if (ok) {
      stdout.writeln(
        '  ✓ smoke OK (${run.toolCallCount} tool call, '
        '${sw.elapsedMilliseconds} ms): ${run.text.trim()}',
      );
      return true;
    }
    stderr.writeln(
      '  ✗ smoke GAGAL: success=${run.success} '
      'toolCalls=${run.toolCallCount} jawaban="${run.text.trim()}"',
    );
    return false;
  } catch (error) {
    stderr.writeln('  ✗ smoke GAGAL: $error');
    return false;
  } finally {
    await rt?.events.close();
  }
}

Future<void> _setupInteractive(String configPath, bool force) async {
  stdout.writeln('Wizard onboarding Tiko — kredensial disimpan sebagai SecretRef');
  stdout.writeln('env:VAR di config, nilai rahasianya di gateway.env (permission 600).');
  stdout.writeln('');
  final prompts = PromptRunner();
  const providerTypes = [
    'mock',
    'ollama_native',
    'openai',
    'deepseek',
    'anthropic',
    'gemini',
    'openai_compat',
    'openai_responses',
    'azure_openai',
    'bedrock',
  ];
  String providerType;
  while (true) {
    final choice = await prompts.select(
      'Tipe provider:',
      [...providerTypes, 'Lainnya (id preset lain)…'],
      def: 'mock',
    );
    if (choice == 'Lainnya (id preset lain)…') {
      providerType = await prompts.prompt(
        'id preset (mis. cerberus)',
        required: true,
        completions: providerTypes,
      );
    } else {
      providerType = choice;
    }
    try {
      OnboardingWizard.renderConfigYaml(OnboardingProfile(
        providerType: providerType,
        workspace: '.',
      ));
      break;
    } on ArgumentError {
      stdout.writeln('  Tipe provider tidak dikenal, coba lagi.');
    }
  }
  // Simpan pilihan custom agar langkah berikutnya konsisten dengan menu.
  stdout.writeln('Provider dipilih: $providerType');

  final needsKey = providerType != 'mock' && providerType != 'ollama_native';
  final baseUrl = needsKey
      ? await prompts.prompt('base_url (kosongkan untuk default preset)')
      : '';
  final model = await prompts.prompt('model (kosongkan untuk default)');

  final env = <String, String>{};
  String? apiKeyEnvVar;
  if (needsKey) {
    apiKeyEnvVar = OnboardingProfile.defaultApiKeyVar(providerType);
    env[apiKeyEnvVar] = await prompts.prompt('API key ($apiKeyEnvVar)', required: true);
  }

  if (await prompts.confirm('Aktifkan gateway Telegram?')) {
    env['TG_TOKEN'] = await prompts.prompt('TG_TOKEN', required: true);
    env['TG_ALLOW'] = await prompts.prompt('TG_ALLOW (id user, dipisah koma)', required: true);
  }
  if (await prompts.confirm('Aktifkan gateway Discord?')) {
    env['DISCORD_BOT_TOKEN'] = await prompts.prompt('DISCORD_BOT_TOKEN', required: true);
    env['DISCORD_ALLOW'] = await prompts.prompt('DISCORD_ALLOW (id user, dipisah koma)');
  }
  if (await prompts.confirm('Aktifkan email SMTP (outbound)?')) {
    env['EMAIL_FROM'] = await prompts.prompt('EMAIL_FROM', required: true);
    env['SMTP_HOST'] = await prompts.prompt('SMTP_HOST', required: true);
    env['SMTP_PORT'] = await prompts.prompt('SMTP_PORT', def: '587');
    final smtpUser = await prompts.prompt('SMTP_USER');
    if (smtpUser.isNotEmpty) {
      env['SMTP_USER'] = smtpUser;
      env['SMTP_PASS'] = await prompts.prompt('SMTP_PASS', required: true);
      env['SMTP_STARTTLS'] = '1';
    }
    final emailAllow = await prompts.prompt('EMAIL_ALLOW (tujuan diizinkan, dipisah koma)');
    if (emailAllow.isNotEmpty) env['EMAIL_ALLOW'] = emailAllow;
  }
  if (await prompts.confirm('Aktifkan email inbound IMAP?')) {
    env['IMAP_HOST'] = await prompts.prompt('IMAP_HOST', required: true);
    env['IMAP_PORT'] = await prompts.prompt('IMAP_PORT', def: '993');
    env['IMAP_USER'] = await prompts.prompt('IMAP_USER', required: true);
    env['IMAP_PASSWORD'] = await prompts.prompt('IMAP_PASSWORD', required: true);
    env['IMAP_ALLOW'] = await prompts.prompt('IMAP_ALLOW (pengirim diizinkan)', required: true);
  }

  final profile = OnboardingProfile(
    providerType: providerType,
    workspace: await prompts.prompt('Workspace', def: '.', required: true),
    baseUrl: baseUrl.isEmpty ? null : baseUrl,
    model: model.isEmpty ? null : model,
    apiKeyEnvVar: apiKeyEnvVar,
    env: env,
  );

  final configAbs = p.absolute(configPath);
  final configDir = p.dirname(configAbs);
  final projectRoot = p.basename(configDir) == 'config'
      ? p.dirname(configDir)
      : configDir;
  try {
    var forceWrite = force;
    final existing = File(configPath);
    if (await existing.exists() && !force) {
      stdout.writeln('');
      stdout.writeln('Config sudah ada: ${p.absolute(configPath)}');
      forceWrite = await prompts.confirm(
        '  Timpa config dengan hasil wizard ini? (y/t)',
      );
      if (!forceWrite) {
        stdout.writeln(
          'Config tidak diubah. Untuk overwrite tanpa tanya, jalankan '
          '`tiko setup --interactive --force`.',
        );
        return;
      }
    }
    final paths = await OnboardingWizard.writeAll(
      configPath: configPath,
      dataDir: p.join(projectRoot, 'data'),
      profile: profile,
      force: forceWrite,
    );
    stdout.writeln('');
    stdout.writeln('✓ Config disimpan: ${paths.configPath}');
    stdout.writeln('✓ Env file disimpan: ${paths.envPath} (permission 600)');
    stdout.writeln('');
    stdout.writeln('Lanjut:');
    stdout.writeln('  source ${paths.envPath}');
    stdout.writeln('  tiko doctor --probe && tiko chat');
  } on StateError catch (error) {
    stderr.writeln('✗ GAGAL menyimpan: ${error.message}');
    stderr.writeln('Tidak ada perubahan yang selesai; jalankan ulang wizard.');
    exitCode = 1;
  } on ArgumentError catch (error) {
    stderr.writeln('✗ GAGAL: ${error.message}');
    exitCode = 2;
  }
}
