import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// agentd — thin host around [TikoRuntime] (gateways + scheduler + HTTP).
Future<void> main(List<String> args) async {
  final useTelegram =
      args.contains('--telegram') || Platform.environment['TG_TOKEN'] != null;
  final useApi = args.contains('--api') ||
      args.contains('--ui') ||
      Platform.environment['API_TOKEN'] != null ||
      Platform.environment['AGENT_UI'] == '1';
  final forceCli = args.contains('--cli');
  final configPath = Platform.environment['TIKO_CONFIG'] ?? 'config/agent.yaml';
  final safe = !args.contains('--no-safe');

  late final TikoRuntime rt;
  try {
    rt = await TikoRuntime.create(configPath: configPath, safe: safe);
  } on ConfigValidationException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
    return;
  }
  final lock = RuntimeLock('${rt.dataDir}/tiko.lock');
  final portOverrideText = Platform.environment['API_PORT'];
  final portOverride = int.tryParse(portOverrideText ?? '');
  if (useApi && portOverrideText != null &&
      (portOverride == null || portOverride < 1 || portOverride > 65535)) {
    stderr.writeln('API_PORT harus berupa integer 1 sampai 65535.');
    await rt.close();
    exitCode = 1;
    return;
  }
  final port = portOverride ?? rt.config.apiPort;

  // Instance lock (do not kill other processes)
  try {
    await lock.acquire(profile: rt.config.profile, version: tikoVersion, port: port);
  } on LockHeldException catch (e) {
    stderr.writeln('$e');
    await rt.close();
    exit(1);
  }

  // Only a newly locked daemon process may expire leftover approvals. CLI
  // readers can safely inspect the same ledger while this daemon is alive.
  try {
    await rt.approvals.expirePendingOnStartup();
  } catch (error) {
    stderr.writeln('Gagal memulihkan approval ledger: $error');
    await rt.close();
    await lock.release();
    exit(1);
  }

  try {
    final mcpCount = await rt.startMcp();
    if (mcpCount > 0) stdout.writeln('$mcpCount MCP tool(s) aktif dalam sandbox OS');
  } catch (error) {
    stderr.writeln('MCP startup gagal secara fail-closed: $error');
  }

  // Resolve and persist the API credential before starting any gateway or
  // scheduler. A daemon without a safely persisted token would be alive but
  // unreachable by its local CLI/Flutter clients, so fail closed instead.
  final configuredToken = Platform.environment['API_TOKEN']?.trim();
  final apiToken = !useApi
      ? null
      : (configuredToken == null || configuredToken.isEmpty
          ? _randomToken()
          : configuredToken);
  if (apiToken != null) {
    if (apiToken.length < 32) {
      stderr.writeln('API_TOKEN terlalu pendek; minimal 32 karakter (128-bit).');
      await rt.close();
      await lock.release();
      exitCode = 1;
      return;
    }
    try {
      await ApiTokenStore.write(rt.dataDir, apiToken);
    } catch (error) {
      stderr.writeln('Token API tidak dapat disimpan dengan permission aman: $error');
      await rt.close();
      await lock.release();
      exitCode = 1;
      return;
    }
    if (configuredToken == null || configuredToken.isEmpty) {
      stdout.writeln('API token acak dibuat dan disimpan secara lokal.');
    }
  }

  final shutdownSignal = Completer<void>();

  stdout.writeln('agentd $tikoVersion via TikoRuntime');
  stdout.writeln(
    'provider=${rt.config.defaultProvider} memory=${rt.memoryBackend} '
    'profile=${rt.resourceProfile} workspace=${rt.workspace}',
  );

  // Jobs/scheduler/tools are owned by the shared TikoRuntime.
  rt.registry.register(PlanTaskTool(PlanExecute(_primaryLlm(rt))));

  final rateLimiter = RateLimiter(maxPerMinute: 20);
  final gateways = <Gateway>[];
  TelegramGateway? tg;
  DiscordGateway? discord;
  EmailGateway? email;
  HttpApiServer? api;

  // Discord
  final discordWebhook = Platform.environment['DISCORD_WEBHOOK'];
  final discordBot = Platform.environment['DISCORD_BOT_TOKEN'];
  if ((discordWebhook != null && discordWebhook.isNotEmpty) ||
      (discordBot != null && discordBot.isNotEmpty)) {
    final allow = (Platform.environment['DISCORD_ALLOW'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    discord = DiscordGateway(
      webhookUrl: discordWebhook,
      botToken: discordBot,
      allowedUserIds: allow,
      applicationId: Platform.environment['DISCORD_APP_ID'],
      registerSlash: Platform.environment['DISCORD_SLASH'] != '0',
    );
    gateways.add(discord);
    if (discordBot != null && discordBot.isNotEmpty) {
      await discord.start();
      stdout.writeln('Discord aktif');
    }
  }

  // Email
  final emailFrom = Platform.environment['EMAIL_FROM'];
  if (emailFrom != null && emailFrom.isNotEmpty) {
    email = EmailGateway(
      from: emailFrom,
      host: Platform.environment['SMTP_HOST'] ?? '127.0.0.1',
      port: int.tryParse(Platform.environment['SMTP_PORT'] ?? '25') ?? 25,
      toAllowlist: (Platform.environment['EMAIL_ALLOW'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet(),
      defaultTo: Platform.environment['EMAIL_TO'],
      useStartTls: Platform.environment['SMTP_STARTTLS'] == '1',
      username: Platform.environment['SMTP_USER'],
      password: Platform.environment['SMTP_PASS'],
    );
    gateways.add(email);
    stdout.writeln('Email SMTP aktif');
  }

  // Telegram
  if (useTelegram) {
    final token = Platform.environment['TG_TOKEN'];
    if (token == null || token.isEmpty) {
      stderr.writeln('TG_TOKEN wajib');
      exit(1);
    }
    final allow = (Platform.environment['TG_ALLOW'] ?? '')
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
    if (allow.isEmpty) {
      stderr.writeln('TG_ALLOW wajib');
      exit(1);
    }
    SttClient? stt;
    final whisper = Platform.environment['WHISPER_BIN'];
    final sttKey = Platform.environment['STT_API_KEY'];
    if ((whisper != null && whisper.isNotEmpty) ||
        (sttKey != null && sttKey.isNotEmpty)) {
      stt = SttClient(
        whisperBin: whisper,
        apiBaseUrl: sttKey != null
            ? (Platform.environment['STT_API_BASE'] ?? 'https://api.openai.com/v1')
            : null,
        apiKey: sttKey,
      );
    }
    tg = TelegramGateway(token: token, allowedUserIds: allow, stt: stt);
    gateways.add(tg);
    await tg.start();
    stdout.writeln('Telegram aktif');
  }

  Gateway? gatewayForChannel(String channel) {
    for (final g in gateways) {
      if (g.channel == channel) return g;
    }
    return null;
  }

  Future<void> handleMessage(InboundMessage m, {Gateway? replyVia}) async {
    if (!rateLimiter.allow(m.userKey)) {
      await replyVia?.send(OutboundMessage(
        sessionKey: m.sessionKey,
        text: 'Rate limit — coba lagi nanti.',
      ));
      return;
    }

    Future<bool> Function(ToolCall call, Session session)? confirm;
    if (tg != null && m.channel == 'telegram') {
      confirm = (call, sess) => tg!.requestConfirm(
            sessionKey: m.sessionKey,
            prompt: 'Izinkan *${call.name}*?\n`${call.args}`',
          );
    } else if (m.channel == 'cli' && stdin.hasTerminal) {
      confirm = (call, sess) async {
        stdout.writeln('Confirm ${call.name}? args=${call.args} [y/N]');
        final line = stdin.readLineSync()?.trim().toLowerCase();
        return line == 'y' || line == 'yes';
      };
    } else if (m.channel != 'http' && m.channel != 'web') {
      // Channels without an approval UI fail closed. HTTP/Flutter deliberately
      // use the shared ApprovalBroker through /v1/approvals.
      confirm = (call, sess) async => false;
    }

    final answer = await rt.chat(
      m.text,
      sessionId: m.sessionKey,
      channel: m.channel,
      userKey: m.userKey,
      confirm: confirm,
    );

    final gw = replyVia ?? gatewayForChannel(m.channel);
    if (gw != null) {
      await gw.send(OutboundMessage(sessionKey: m.sessionKey, text: answer));
    } else if (m.channel == 'cli') {
      stdout.writeln('assistant> $answer');
    } else {
      // Scheduler/job without matching gateway: log only (F-14 fixed)
      stdout.writeln('[${m.channel}] $answer');
    }
    rt.events.emit('message.done', {
      'session': m.sessionKey,
      'channel': m.channel,
    });
  }

  final jobEventsSub = rt.events.stream.listen((event) {
    if (event.type != 'job.completed') return;
    final channel = event.data['channel'] as String? ?? '';
    final sessionKey = event.data['session_id'] as String? ?? '';
    final text = event.data['text'] as String? ?? '';
    final target = gatewayForChannel(channel);
    if (target == null) {
      // No exact destination available: retain the result locally, never send
      // it to an unrelated first/available gateway.
      stdout.writeln('[scheduler:${event.data['job_id']}] no gateway for "$channel"; result kept in session $sessionKey');
      return;
    }
    unawaited(target.send(OutboundMessage(sessionKey: sessionKey, text: text)).catchError((error) {
      stdout.writeln('[scheduler:${event.data['job_id']}] delivery failed for "$channel": $error; result remains in session $sessionKey');
    }));
  });
  rt.startScheduler();
  stdout.writeln('Scheduler aktif (dikelola TikoRuntime)');

  if (useApi) {
    // apiToken was validated and persisted before any background service ran.
    final token = apiToken!;
    try {
      api = HttpApiServer(
        authToken: token,
        host: Platform.environment['API_HOST'] ?? '127.0.0.1',
        port: port,
        webRoot: _findWebRoot(),
        onMessage: (m) async {
          final c = Completer<String>();
          await handleMessage(m, replyVia: _CollectGateway(c));
          try {
            return await c.future.timeout(const Duration(seconds: 180));
          } catch (_) {
            return '(timeout)';
          }
        },
        listSessions: () async {
          final list = await rt.sessions.list();
          return list
              .map((s) => {
                    'id': s.id,
                    'channel': s.channel,
                    'title': s.title,
                    'updated_at': s.updatedAt.toIso8601String(),
                    'turns': s.turns,
                  })
              .toList();
        },
        listMemories: () => rt.listMemories(),
        deleteMemory: (id) => rt.deleteMemory(id),
        doctorProvider: () async {
          final ownLock = await lock.read();
          final checks = await rt.doctor(
            probe: false,
            apiPort: port,
            lock: ownLock,
          );
          return checks.map((c) => c.toJson()).toList();
        },
        eventsProvider: () => rt.events.recent(),
        eventStream: rt.events.stream.map((event) => event.toJson()),
        listApprovals: () async =>
            (await rt.approvals.all()).map((a) => a.toJson()).toList(),
        decideApproval: (id, allow) async {
          final r = await rt.decideApproval(id, approve: allow, actor: 'api');
          return r != null;
        },
        onShutdown: () async {
          if (!shutdownSignal.isCompleted) shutdownSignal.complete();
        },
        capabilitiesProvider: () => {
          'version': tikoVersion,
          'provider': rt.config.defaultProvider,
          'memory': rt.memoryBackend,
          'resource_profile': rt.resourceProfile,
          'sandbox': rt.sandboxKind.name,
        },
        statusProvider: () => {
          'ok': true,
          'version': tikoVersion,
          'provider': rt.config.defaultProvider,
          'memory': rt.memoryBackend,
          'safe_mode': rt.safety.safeMode,
          'jobs': rt.jobs.all.length,
          'resource_profile': rt.resourceProfile,
          'sandbox': rt.sandboxKind.name,
        },
      );
      await api.start();
      stdout.writeln('UI http://127.0.0.1:$port/');
      stdout.writeln('Token tersimpan di ${ApiTokenStore.pathFor(rt.dataDir)} (permission 600).');
    } on SocketException catch (e) {
      stderr.writeln(
        'Gagal bind port $port: $e\n'
        'tiko doctor — atau ubah api.port / hentikan proses lain.',
      );
      await api?.stop();
      await rt.close();
      await jobEventsSub.cancel();
      for (final gateway in gateways) {
        try { await gateway.close(); } catch (_) {}
      }
      await lock.release();
      exitCode = 1;
      return;
    } catch (error) {
      stderr.writeln('API startup gagal: $error');
      await api?.stop();
      await rt.close();
      await jobEventsSub.cancel();
      for (final gateway in gateways) {
        try { await gateway.close(); } catch (_) {}
      }
      await lock.release();
      exitCode = 1;
      return;
    }
  }

  final subs = <StreamSubscription>[];
  subs.add(jobEventsSub);
  for (final gw in gateways) {
    subs.add(gw.inbound.listen((m) {
      unawaited(handleMessage(m, replyVia: gw));
    }));
  }

  final interactive = !useApi &&
      (forceCli || (stdin.hasTerminal && gateways.isEmpty));

  if (interactive) {
    stdout.writeln('CLI: /quit /doctor /status');
    while (true) {
      stdout.write('you> ');
      final line = stdin.readLineSync();
      if (line == null) break;
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text == '/quit') break;
      if (text == '/doctor') {
        for (final c in await rt.doctor()) {
          stdout.writeln('${c.status.name} ${c.name}: ${c.detail}');
        }
        continue;
      }
      if (text == '/status') {
        stdout.writeln(
          'provider=${rt.config.defaultProvider} memory=${rt.memoryBackend}',
        );
        continue;
      }
      await handleMessage(InboundMessage(
        channel: 'cli',
        userKey: 'local',
        sessionKey: 'cli:local',
        text: text,
      ));
    }
  } else {
    stdout.writeln('Daemon siap — SIGINT/SIGTERM untuk berhenti');
    ProcessSignal.sigint.watch().listen((_) {
      if (!shutdownSignal.isCompleted) shutdownSignal.complete();
    });
    try {
      ProcessSignal.sigterm.watch().listen((_) {
        if (!shutdownSignal.isCompleted) shutdownSignal.complete();
      });
    } catch (_) {}
    await shutdownSignal.future;
  }

  stdout.writeln('Shutdown…');
  // Close the runtime once: it denies pending approvals, stops scheduled work,
  // and terminates managed MCP child processes before gateway shutdown.
  await rt.close();
  for (final s in subs) {
    await s.cancel();
  }
  await tg?.close();
  await discord?.close();
  await email?.close();
  await api?.stop();
  await lock.release();
}

LlmProvider _primaryLlm(TikoRuntime rt) {
  final id = rt.config.defaultProvider;
  return rt.providers[id] ?? rt.providers.values.first;
}

String _randomToken() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String? _findWebRoot() {
  for (final c in [
    'apps/agentd/web',
    'web',
    '${Directory.current.path}/apps/agentd/web',
  ]) {
    if (File('$c/index.html').existsSync()) return c;
  }
  return null;
}

class _CollectGateway implements Gateway {
  _CollectGateway(this.completer);
  final Completer<String> completer;

  @override
  String get channel => 'http';

  @override
  Stream<InboundMessage> get inbound => const Stream.empty();

  @override
  Future<void> send(OutboundMessage m) async {
    if (!completer.isCompleted) completer.complete(m.text);
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async {}
}
