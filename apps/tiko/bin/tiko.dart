import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';

const _usage = '''
tiko — Pasitiko local-first agent (control plane)

  tiko [opsi] <perintah>

Perintah utama:
  setup [--provider mock|ollama] [--workspace PATH] [--force]
  chat [prompt]              chat (mode auto: embedded)
  run <prompt>
  daemon start|stop|restart|status
  ui                         cetak URL UI
  doctor [--probe]
  route explain --task "..."
  status
  version

Config:
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

Opsi: --config PATH  --json  --no-safe  --mode auto|embedded
''';

Future<void> main(List<String> argv) async {
  var configPath = 'config/agent.yaml';
  var jsonOut = false;
  var safe = true;
  var probe = false;
  var mode = 'auto';
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--config' && i + 1 < argv.length) {
      configPath = argv[++i];
    } else if (a == '--json') {
      jsonOut = true;
    } else if (a == '--no-safe') {
      safe = false;
    } else if (a == '--probe') {
      probe = true;
    } else if (a == '--mode' && i + 1 < argv.length) {
      mode = argv[++i];
    } else if (a == '-h' || a == '--help') {
      stdout.write(_usage);
      return;
    } else {
      rest.add(a);
    }
  }
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

  late final TikoRuntime rt;
  try {
    rt = await TikoRuntime.create(
      configPath: configPath,
      safe: safe,
      // Doctor and config commands must remain available to repair a bad file.
      allowInvalidConfig: cmd == 'doctor' || cmd == 'config',
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
  );
  final bus = EventBus();
  final skillsDir = p.join(rt.workspace, 'skills');

  Future<bool> askUser(ToolCall call, Session session) async {
    stdout.writeln('Konfirmasi tool [${call.name}] risk args=${call.args}');
    stdout.write('Izinkan? [y/N] ');
    final line = stdin.readLineSync()?.trim().toLowerCase();
    return line == 'y' || line == 'yes';
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

    case 'config':
      await _configCmd(store, args, emit, jsonOut);
      return;

    case 'skills':
      final gate = SkillPromotionGate(skillsDir: skillsDir);
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
        final skill = _loadSkill(slug, skillsDir);
        if (skill == null) {
          stderr.writeln('skill not found: $slug');
          exitCode = 1;
          return;
        }
        final r = await gate.evaluateAndMaybePromote(skill, promoteOnPass: args.contains('--promote'));
        emit(r.toJson(), '${r.ok ? 'PASS' : 'FAIL'} ${r.stage}: ${r.message}');
        if (!r.ok) exitCode = 1;
      } else if (args.first == 'approve' && args.length > 1) {
        final skill = _loadSkill(args[1], skillsDir);
        if (skill == null) {
          exitCode = 1;
          return;
        }
        // must evaluate first
        await gate.evaluateAndMaybePromote(skill);
        final r = gate.approve(skill, actor: 'cli');
        emit(r.toJson(), r.message);
        if (!r.ok) exitCode = 1;
      } else if (args.first == 'rollback' && args.length > 1) {
        final skill = _loadSkill(args[1], skillsDir);
        if (skill == null) {
          exitCode = 1;
          return;
        }
        final r = gate.rollback(skill);
        emit(r.toJson(), r.message);
      } else {
        stderr.writeln('skills list|scan <dir>|evaluate <slug>|approve <slug>|rollback <slug>');
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
              stdout.writeln('tiko chat (remote daemon) — /quit keluar');
              while (true) {
                stdout.write('you> ');
                final line = stdin.readLineSync();
                if (line == null) break;
                final x = line.trim();
                if (x.isEmpty) continue;
                if (x == '/quit' || x == '/exit') break;
                try {
                  stdout.writeln('tiko> ${await remote.chat(x)}');
                } catch (e) {
                  stdout.writeln('error: $e');
                }
              }
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
      stdout.writeln('tiko chat — /quit keluar, /doctor, /status');
      while (true) {
        stdout.write('you> ');
        final line = stdin.readLineSync();
        if (line == null) break;
        final t = line.trim();
        if (t.isEmpty) continue;
        if (t == '/quit' || t == '/exit') break;
        if (t == '/doctor') {
          for (final c in await rt.doctor()) {
            stdout.writeln('${c.status.name} ${c.name}: ${c.detail}');
          }
          continue;
        }
        if (t == '/status') {
          stdout.writeln('provider=${rt.config.defaultProvider} memory=${rt.memoryBackend}');
          continue;
        }
        final answer = await rt.chat(t, confirm: askUser);
        stdout.writeln('tiko> $answer');
      }
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

/// Loads only a direct child of the canonical workspace skills directory.
/// Symbolic-link escapes and malformed/oversized skill files are rejected.
Skill? _loadSkill(String slug, String skillsDir) {
  if (slug.trim().isEmpty || slug == '.' || slug == '..' ||
      slug.contains('/') || slug.contains('\\') ||
      !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$').hasMatch(slug)) {
    return null;
  }
  try {
    final root = Directory(skillsDir).resolveSymbolicLinksSync();
    final dir = Directory(p.join(root, slug));
    if (!dir.existsSync()) return null;
    final realDir = dir.resolveSymbolicLinksSync();
    if (p.equals(realDir, root) || !p.isWithin(root, realDir)) return null;
    final file = File(p.join(realDir, 'SKILL.md'));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final realFile = file.resolveSymbolicLinksSync();
    if (!p.isWithin(realDir, realFile) || file.lengthSync() > SkillValidator.maxBytes) {
      return null;
    }
    final skill = SkillParser.parse(file.readAsStringSync(), slug: slug, path: file.path);
    if (skill == null || SkillValidator.validate(skill) != null) return null;
    return skill;
  } catch (_) {
    return null;
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
      stdout.writeln(_getCfg(cfg, args[1]));
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

String _getCfg(TikoConfig c, String path) {
  switch (path) {
    case 'default_provider':
    case 'providers.default':
      return c.defaultProvider;
    case 'workspace':
      return c.workspace;
    case 'api.port':
      return '${c.apiPort}';
    case 'data_dir':
      return c.dataDir;
    default:
      return '(gunakan config show; path $path)';
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

Future<void> _setup(String configPath, List<String> args) async {
  var provider = 'mock';
  var workspace = '.';
  var force = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--provider' && i + 1 < args.length) {
      provider = args[++i];
    } else if (args[i] == '--workspace' && i + 1 < args.length) {
      workspace = args[++i];
    } else if (args[i] == '--force') {
      force = true;
    } else {
      stderr.writeln('Opsi setup tidak dikenal: ${args[i]}');
      exitCode = 2;
      return;
    }
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
  stdout.writeln('Lanjut: tiko doctor --probe && tiko calc 5+1 && tiko chat');
}
