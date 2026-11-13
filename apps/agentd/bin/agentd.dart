import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

import 'runtime_skill_api.dart';

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
    exit(1);
  }
  final lock = RuntimeLock('${rt.dataDir}/tiko.lock');
  final portOverrideText = Platform.environment['API_PORT'];
  final portOverride = int.tryParse(portOverrideText ?? '');
  if (useApi && portOverrideText != null &&
      (portOverride == null || portOverride < 1 || portOverride > 65535)) {
    stderr.writeln('API_PORT harus berupa integer 1 sampai 65535.');
    await rt.close();
    exit(1);
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

  // ACP agent side over stdio: IDEs that speak ACP (Zed, VS Code extensions)
  // drive the same TikoRuntime through JSON-RPC 2.0, with session/load
  // replaying stored conversation history.
  final useAcp =
      args.contains('--acp') || Platform.environment['TIKO_ACP'] == '1';
  if (useAcp) {
    final acp = AcpAgent(
      handler: (sid, prompt) => rt.chat(
        prompt,
        sessionId: 'acp:$sid',
        channel: 'acp',
        userKey: 'acp',
      ),
      sessionLoader: (sid) => _loadAcpSession(rt, sid),
    );
    stdout.writeln('agentd ACP siap (stdio) \u2014 SIGINT/SIGTERM untuk berhenti');
    final acpServe = acp.serve();
    ProcessSignal.sigint.watch().listen((_) => acp.stop());
    try {
      ProcessSignal.sigterm.watch().listen((_) => acp.stop());
    } catch (_) {}
    await acpServe;
    await rt.close();
    await lock.release();
    return;
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
      exit(1);
    }
    try {
      await ApiTokenStore.write(rt.dataDir, apiToken);
    } catch (error) {
      stderr.writeln('Token API tidak dapat disimpan dengan permission aman: $error');
      await rt.close();
      await lock.release();
      exit(1);
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
  OpenAiCompatServer? openAiServer;

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

  // WhatsApp + Slack webhooks (inbound via HttpApiServer, HMAC-verified).
  final waPhoneId = Platform.environment['WHATSAPP_PHONE_NUMBER_ID'];
  final waAccessToken = Platform.environment['WHATSAPP_ACCESS_TOKEN'];
  final waVerifyToken = Platform.environment['WHATSAPP_VERIFY_TOKEN'];
  final waAppSecret = Platform.environment['WHATSAPP_APP_SECRET'];
  WhatsAppGateway? wa;
  if (waPhoneId != null && waPhoneId.isNotEmpty &&
      waAccessToken != null && waAccessToken.isNotEmpty &&
      waVerifyToken != null && waVerifyToken.isNotEmpty &&
      waAppSecret != null && waAppSecret.isNotEmpty) {
    final appSecret = waAppSecret;
    final gateway = WhatsAppGateway(
      phoneNumberId: waPhoneId,
      accessToken: waAccessToken,
      verifyToken: waVerifyToken,
      signatureVerifier: (raw, header) => WebhookSignature.verifyMeta(
        rawBody: raw,
        headerValue: header,
        appSecret: appSecret,
      ),
    );
    wa = gateway;
    gateways.add(_WhatsAppReplyGateway(gateway));
    stdout.writeln('WhatsApp webhook aktif');
  } else if ((waPhoneId != null && waPhoneId.isNotEmpty) ||
      (waAccessToken != null && waAccessToken.isNotEmpty)) {
    stdout.writeln(
      'WhatsApp webhook dilewati: WHATSAPP_PHONE_NUMBER_ID, '
      'WHATSAPP_ACCESS_TOKEN, WHATSAPP_VERIFY_TOKEN, dan '
      'WHATSAPP_APP_SECRET wajib lengkap',
    );
  }

  final slackWebhookUrl = Platform.environment['SLACK_WEBHOOK_URL'];
  final slackBotToken = Platform.environment['SLACK_BOT_TOKEN'];
  final slackSigningSecret = Platform.environment['SLACK_SIGNING_SECRET'];
  SlackGateway? slackGw;
  if (slackSigningSecret != null && slackSigningSecret.isNotEmpty &&
      (slackWebhookUrl != null && slackWebhookUrl.isNotEmpty ||
          slackBotToken != null && slackBotToken.isNotEmpty)) {
    final slack = SlackGateway(
      webhookUrl: slackWebhookUrl,
      botToken: slackBotToken,
    );
    slackGw = slack;
    gateways.add(_SlackReplyGateway(slack));
    stdout.writeln('Slack webhook aktif');
  } else if (slackSigningSecret != null && slackSigningSecret.isNotEmpty) {
    stdout.writeln(
      'Slack webhook dilewati: SLACK_WEBHOOK_URL atau SLACK_BOT_TOKEN '
      'wajib diisi',
    );
  }

  // Signal (signal-cli JSON-RPC daemon, poll-based).
  final signalRpcUrl = Platform.environment['SIGNAL_RPC_URL'];
  final signalAccount = Platform.environment['SIGNAL_ACCOUNT'];
  final signalAllow = (Platform.environment['SIGNAL_ALLOW'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (signalRpcUrl != null && signalRpcUrl.isNotEmpty) {
    if (signalAccount == null || signalAccount.isEmpty) {
      stderr.writeln('SIGNAL_ACCOUNT wajib');
      exit(1);
    }
    if (signalAllow.isEmpty) {
      stderr.writeln('SIGNAL_ALLOW wajib');
      exit(1);
    }
    final signal = SignalGateway(
      rpcUrl: signalRpcUrl,
      account: signalAccount,
      allowedSenders: signalAllow,
    );
    gateways.add(signal);
    await signal.start();
    stdout.writeln('Signal aktif');
  }

  // Matrix (client-server API v3, /sync long-poll).
  final matrixHomeserver = Platform.environment['MATRIX_HOMESERVER'];
  final matrixToken = Platform.environment['MATRIX_ACCESS_TOKEN'];
  final matrixAllow = (Platform.environment['MATRIX_ALLOW'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (matrixHomeserver != null && matrixHomeserver.isNotEmpty) {
    if (matrixToken == null || matrixToken.isEmpty) {
      stderr.writeln('MATRIX_ACCESS_TOKEN wajib');
      exit(1);
    }
    if (matrixAllow.isEmpty) {
      stderr.writeln('MATRIX_ALLOW wajib');
      exit(1);
    }
    final matrix = MatrixGateway(
      homeserverUrl: matrixHomeserver,
      accessToken: matrixToken,
      allowedRooms: matrixAllow,
    );
    gateways.add(matrix);
    await matrix.start();
    stdout.writeln('Matrix aktif');
  }

  Gateway? gatewayForChannel(String channel) {
    for (final g in gateways) {
      if (g.channel == channel) return g;
    }
    return null;
  }

  /// Parses `/feedback <slug> up|down` (also 👍/👎, +1/-1) and applies it to
  /// the skill registry. In-memory reliability updates immediately; the
  /// durable SkillMetricsLedger sink persists the event. Returns the reply
  /// text, or null when [m] is not a feedback command.
  String? maybeHandleFeedbackCommand(InboundMessage m) {
    final text = m.text.trim();
    if (!text.toLowerCase().startsWith('/feedback')) return null;
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length < 3) {
      return 'Format: /feedback <slug> up|down (atau 👍/👎)';
    }
    final slug = parts[1];
    final raw = parts[2].toLowerCase();
    final positive =
        raw == 'up' || raw == '👍' || raw == '+1' || raw == 'yes';
    final negative =
        raw == 'down' || raw == '👎' || raw == '-1' || raw == 'no';
    if (!positive && !negative) {
      return 'Nilai feedback tidak dikenal: "$raw". Gunakan up|down.';
    }
    final skill = rt.skills.get(slug);
    if (skill == null) return 'Skill "$slug" tidak dikenal.';
    if (skill.status == SkillStatus.draft ||
        skill.status == SkillStatus.retired) {
      return 'Skill "$slug" berstatus ${skill.status.name}; '
          'feedback hanya berlaku untuk skill aktif.';
    }
    rt.skills.applyFeedback(slug, positive: positive);
    return 'Feedback ${positive ? '👍' : '👎'} untuk skill "$slug" dicatat.';
  }

  Future<void> handleMessage(InboundMessage m, {Gateway? replyVia}) async {
    if (!rateLimiter.allow(m.userKey)) {
      await replyVia?.send(OutboundMessage(
        sessionKey: m.sessionKey,
        text: 'Rate limit — coba lagi nanti.',
      ));
      return;
    }

    Future<bool> Function(ToolCall call, Session session, String approvalId)?
        confirm;
    if (tg != null && m.channel == 'telegram') {
      confirm = (call, sess, approvalId) => tg!.requestConfirm(
            sessionKey: m.sessionKey,
            prompt: 'Izinkan *${call.name}*?\n`${call.args}`\n'
                'ID approval: `$approvalId` '
                '(bisa juga disetujui dari web/Flutter atau `tiko approve`)',
          );
    } else if (m.channel == 'cli' && stdin.hasTerminal) {
      confirm = (call, sess, approvalId) async {
        stdout.writeln(
          'Confirm ${call.name}? args=${call.args} id=$approvalId [y/N]',
        );
        final line = stdin.readLineSync()?.trim().toLowerCase();
        return line == 'y' || line == 'yes';
      };
    } else if (m.channel != 'http' && m.channel != 'web') {
      // Channels without an approval UI fail closed. HTTP/Flutter deliberately
      // use the shared ApprovalBroker through /v1/approvals.
      confirm = (call, sess, approvalId) async => false;
    }

    final gw = replyVia ?? gatewayForChannel(m.channel);

    // Closed feedback loop: chat users on any channel can rate the skill(s)
    // of the previous turn with `/feedback <slug> up|down` (or 👍/👎).
    final feedbackReply = maybeHandleFeedbackCommand(m);
    if (feedbackReply != null) {
      await (gw?.send(OutboundMessage(sessionKey: m.sessionKey, text: feedbackReply)) ??
          Future.value());
      if (gw == null && m.channel == 'cli') stdout.writeln('assistant> $feedbackReply');
      return;
    }

    // P1-4 progressive streaming: telegram/discord get one live message that
    // is edited in place as deltas arrive; other channels keep the plain
    // send-once path.
    ProgressiveStreamer? streamer;
    if (gw is TelegramGateway) {
      final chatId = m.sessionKey.startsWith('tg:')
          ? m.sessionKey.substring(3)
          : m.sessionKey;
      final live = TelegramLiveMessage(
        token: gw.token,
        chatId: chatId,
        httpClient: gw.httpClient,
      );
      streamer = ProgressiveStreamer(
        create: live.create,
        update: live.update,
        maxLen: 3500,
      );
    } else if (gw is DiscordGateway && gw.botToken != null) {
      final channelId = m.sessionKey.startsWith('discord:')
          ? m.sessionKey.substring('discord:'.length)
          : m.sessionKey;
      final live = DiscordLiveMessage(botToken: gw.botToken!, channelId: channelId);
      streamer = ProgressiveStreamer(
        create: live.create,
        update: live.update,
        maxLen: 1900,
        minInterval: const Duration(milliseconds: 1200),
      );
    }

    final answer = await rt.chat(
      m.text,
      sessionId: m.sessionKey,
      channel: m.channel,
      userKey: m.userKey,
      confirm: confirm,
      onTextDelta: streamer?.add,
    );

    if (streamer != null && gw != null) {
      final ids = await streamer.finish(answer);
      if (ids.isEmpty) {
        // Live edits never landed (network/platform): fall back to plain send.
        await gw.send(OutboundMessage(sessionKey: m.sessionKey, text: answer));
      }
    } else if (gw != null) {
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

  // Output job mengalir lewat antrean delivery durabel milik runtime:
  // scheduler me-retry kegagalan gateway dengan backoff dan hanya meng-ack
  // run setelah gateway tujuan menerima pesan. Channel tanpa gateway yang
  // cocok tetap menyimpan hasil di sesi (ack lokal — tidak pernah
  // dikirim silang ke gateway lain).
  rt.startScheduler(
    deliver: (job, runId, sessionKey, text) async {
      final target = gatewayForChannel(job.channel);
      if (target == null) {
        stdout.writeln(
          '[scheduler:${job.id}] no gateway for "${job.channel}"; '
          'result kept in session $sessionKey',
        );
        return;
      }
      await target.send(OutboundMessage(sessionKey: sessionKey, text: text));
    },
  );
  stdout.writeln('Scheduler aktif (dikelola TikoRuntime; delivery ack + retry)');

  final webhooks = (wa != null || slackGw != null)
      ? WebhookEndpoint(
          whatsapp: wa,
          whatsappAppSecret: waAppSecret,
          slack: slackGw,
          slackSigningSecret: slackSigningSecret,
          onMessage: (m) => handleMessage(m),
        )
      : null;
  if (useApi) {
    // apiToken was validated and persisted before any background service ran.
    final token = apiToken!;
    try {
      api = HttpApiServer(
        authToken: token,
        host: Platform.environment['API_HOST'] ?? '127.0.0.1',
        port: port,
        webhookEndpoint: webhooks,
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
        skillApi: RuntimeSkillApi(rt),
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
          'routing': {
            'default': rt.config.defaultProvider,
            'tiers': {
              for (final e in rt.config.tierProviders.entries)
                e.key.toString(): e.value,
            },
            'providers': rt.providers.keys.toList(growable: false),
            'health': rt.providerHealth(),
          },
          'mcp': {
            'servers': [
              for (final server in rt.config.mcpServers)
                {
                  'id': server.id,
                  'type': server.type,
                  'enabled': server.enabled,
                  'risk': server.risk,
                  if (server.type == 'http') 'url': server.url,
                  if (server.type == 'stdio') 'command': server.command,
                },
            ],
          },
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
      for (final gateway in gateways) {
        try { await gateway.close(); } catch (_) {}
      }
      await lock.release();
      exit(1);
    } catch (error) {
      stderr.writeln('API startup gagal: $error');
      await api?.stop();
      await rt.close();
      for (final gateway in gateways) {
        try { await gateway.close(); } catch (_) {}
      }
      await lock.release();
      exit(1);
    }
  }

  // OpenAI-compatible API server (Hermes-style): expose the agent as an
  // OpenAI-format backend so any OpenAI-speaking client can use it.
  final openAiPortText = Platform.environment['OPENAI_API_PORT']?.trim() ?? '';
  if (openAiPortText.isNotEmpty) {
    final openAiPort = int.tryParse(openAiPortText);
    final openAiKey = Platform.environment['OPENAI_API_KEY']?.trim() ?? '';
    if (openAiPort == null || openAiPort < 1 || openAiPort > 65535) {
      stderr.writeln('OPENAI_API_PORT harus berupa integer 1 sampai 65535.');
      await rt.close();
      await lock.release();
      exit(1);
    }
    if (openAiKey.length < 32) {
      stderr.writeln('OPENAI_API_KEY terlalu pendek; minimal 32 karakter (128-bit).');
      await rt.close();
      await lock.release();
      exit(1);
    }
    try {
      openAiServer = OpenAiCompatServer(
        config: OpenAiCompatConfig(port: openAiPort, apiKey: openAiKey),
        handler: (req) => rt.chat(
          req.lastUserText,
          sessionId: 'openai:${req.model}',
          channel: 'openai',
          userKey: 'openai',
        ),
      );
      await openAiServer.start();
      stdout.writeln('OpenAI-compatible API aktif di port $openAiPort');
    } catch (error) {
      stderr.writeln('OpenAI-compatible API gagal start: $error');
      await openAiServer?.stop();
      await rt.close();
      await lock.release();
      exit(1);
    }
  }

  final subs = <StreamSubscription>[];
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
  Future<void> closeAll() async {
    await rt.close();
    for (final s in subs) {
      await s.cancel();
    }
    await tg?.close();
    await discord?.close();
    await email?.close();
    await api?.stop();
    await openAiServer?.stop();
  }

  // Bounded shutdown: a hung close() must never leave a zombie daemon that
  // still owns the lock file and the API port.
  var clean = true;
  try {
    await closeAll().timeout(const Duration(seconds: 20));
  } catch (_) {
    clean = false;
    stderr.writeln('Graceful shutdown timed out; force exiting.');
  }
  try {
    await lock.release();
  } catch (_) {}
  // Exit explicitly: lingering signal watchers, timers, or sockets can keep
  // the VM alive after main returns even though shutdown already completed.
  exit(clean ? 0 : 1);
}

Future<List<AcpHistoryEntry>?> _loadAcpSession(TikoRuntime rt, String sid) async {
  final key = 'acp:$sid';
  final all = await rt.sessions.list();
  if (!all.any((s) => s.id == key)) return null;
  final recent = await rt.sessions.recent(key, limit: 50);
  return [
    for (final m in recent)
      if (m.role == 'user' || m.role == 'assistant')
        AcpHistoryEntry(role: m.role, text: m.content),
  ];
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

class _WhatsAppReplyGateway implements Gateway {
  _WhatsAppReplyGateway(this.gateway);
  final WhatsAppGateway gateway;

  @override
  String get channel => 'whatsapp';

  @override
  Stream<InboundMessage> get inbound => const Stream.empty();

  @override
  Future<void> send(OutboundMessage m) async {
    final session = m.sessionKey.startsWith('wa:')
        ? m.sessionKey.substring(3)
        : '';
    if (session.isEmpty) return;
    await gateway.sendText(session, m.text);
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async {}
}

class _SlackReplyGateway implements Gateway {
  _SlackReplyGateway(this.gateway);
  final SlackGateway gateway;

  @override
  String get channel => 'slack';

  @override
  Stream<InboundMessage> get inbound => const Stream.empty();

  @override
  Future<void> send(OutboundMessage m) async {
    final channel = m.sessionKey.startsWith('slack:')
        ? m.sessionKey.substring(6)
        : '';
    if (channel.isEmpty) return;
    await gateway.send(m.text, channel: channel);
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async {}
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
