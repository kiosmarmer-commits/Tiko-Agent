import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

import 'runtime_skill_api.dart';

const _usage = '''
agentd — daemon host TikoAgent (gateways + scheduler + HTTP)

  agentd [opsi]

Opsi:
  --cli         mode CLI interaktif (default bila tanpa --api/--telegram)
  --api, --ui   aktifkan HTTP API/UI (atau env API_TOKEN / AGENT_UI=1)
  --telegram    aktifkan gateway Telegram (atau env TG_TOKEN)
  --acp         sajikan agent via ACP (JSON-RPC 2.0 stdio, atau TIKO_ACP=1)
  --no-safe     matikan mode safe
  --help, -h    tampilkan bantuan ini

Config: env TIKO_CONFIG (default config/agent.yaml)
''';

/// agentd — thin host around [TikoRuntime] (gateways + scheduler + HTTP).
Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  final useTelegram =
      args.contains('--telegram') || Platform.environment['TG_TOKEN'] != null;
  final useApi =
      args.contains('--api') ||
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
  if (useApi &&
      portOverrideText != null &&
      (portOverride == null || portOverride < 1 || portOverride > 65535)) {
    stderr.writeln('API_PORT harus berupa integer 1 sampai 65535.');
    await rt.close();
    exit(1);
  }
  final port = portOverride ?? rt.config.apiPort;

  // Instance lock (do not kill other processes)
  try {
    await lock.acquire(
      profile: rt.config.profile,
      version: tikoVersion,
      port: port,
    );
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
    stdout.writeln(
      'agentd ACP siap (stdio) \u2014 SIGINT/SIGTERM untuk berhenti',
    );
    final acpServe = acp.serve();
    ProcessSignal.sigint.watch().listen((_) => acp.stop());
    try {
      ProcessSignal.sigterm.watch().listen((_) => acp.stop());
    } catch (_) {} // best-effort
    await acpServe;
    await rt.close();
    await lock.release();
    return;
  }

  try {
    final mcpCount = await rt.startMcp();
    if (mcpCount > 0)
      stdout.writeln('$mcpCount MCP tool(s) aktif dalam sandbox OS');
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
      stderr.writeln(
        'API_TOKEN terlalu pendek; minimal 32 karakter (128-bit).',
      );
      await rt.close();
      await lock.release();
      exit(1);
    }
    try {
      await ApiTokenStore.write(rt.dataDir, apiToken);
    } catch (error) {
      stderr.writeln(
        'Token API tidak dapat disimpan dengan permission aman: $error',
      );
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

  // Bot Mode: routing grup memakai BotStore yang sama dengan slash `/bot`
  // (satu sumber kebenaran). Tanpa profil bot, semua channel berperilaku
  // seperti biasa.
  final botRouter = BotGroupRouter(rt.botStore);
  if (rt.botStore.list().isNotEmpty) {
    stdout.writeln('Bot Mode aktif: ${rt.botStore.list().length} bot');
  }
  final gateways = <Gateway>[];
  void addGateway(Gateway gateway) {
    gateways.add(ResilientGateway(gateway));
  }

  TelegramGateway? tg;
  DiscordGateway? discord;
  EmailGateway? email;
  ImapPoller? imap;
  StreamSubscription<ImapEmail>? imapSub;
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
    addGateway(discord);
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
    addGateway(email);
    stdout.writeln('Email SMTP aktif');
  }

  // Email inbound via IMAP poll (TLS-only, allowlist wajib).
  final imapHost = Platform.environment['IMAP_HOST'];
  if (imapHost != null && imapHost.isNotEmpty) {
    final imapUser = Platform.environment['IMAP_USER'] ?? '';
    final imapPass = Platform.environment['IMAP_PASSWORD'] ?? '';
    final imapAllow = (Platform.environment['IMAP_ALLOW'] ?? '')
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (imapUser.isEmpty || imapPass.isEmpty || imapAllow.isEmpty) {
      stderr.writeln('IMAP_USER, IMAP_PASSWORD, dan IMAP_ALLOW wajib');
      exit(1);
    }
    if (email == null) {
      stderr.writeln(
        'IMAP_HOST butuh jalur balasan SMTP: set EMAIL_FROM/SMTP_HOST juga',
      );
      exit(1);
    }
    final emailGateway = email;
    imap = ImapPoller(
      host: imapHost,
      port: int.tryParse(Platform.environment['IMAP_PORT'] ?? '') ?? 993,
      username: imapUser,
      password: imapPass,
      allowSenders: imapAllow,
      pollInterval: Duration(
        seconds:
            int.tryParse(Platform.environment['IMAP_POLL_SEC'] ?? '') ?? 60,
      ),
      onError: stderr.writeln,
    );
    imapSub = imap.emails.listen((m) {
      emailGateway.pushInbound(
        fromAddr: m.from,
        subject: m.subject,
        body: m.body,
      );
    });
    imap.start();
    stdout.writeln('Email IMAP inbound aktif (${imap.host}:${imap.port})');
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
    final sttBase = Platform.environment['STT_API_BASE'];
    if ((whisper != null && whisper.isNotEmpty) ||
        (sttKey != null && sttKey.isNotEmpty)) {
      stt = SttClient(
        whisperBin: whisper,
        openaiApiKey: sttKey,
        openaiBaseUrl: sttBase ?? 'https://api.openai.com/v1',
      );
    }
    tg = TelegramGateway(token: token, allowedUserIds: allow, stt: stt);
    addGateway(tg);
    await tg.start();
    stdout.writeln('Telegram aktif');
  }

  // WhatsApp + Slack webhooks (inbound via HttpApiServer, HMAC-verified).
  final waPhoneId = Platform.environment['WHATSAPP_PHONE_NUMBER_ID'];
  final waAccessToken = Platform.environment['WHATSAPP_ACCESS_TOKEN'];
  final waVerifyToken = Platform.environment['WHATSAPP_VERIFY_TOKEN'];
  final waAppSecret = Platform.environment['WHATSAPP_APP_SECRET'];
  WhatsAppGateway? wa;
  if (waPhoneId != null &&
      waPhoneId.isNotEmpty &&
      waAccessToken != null &&
      waAccessToken.isNotEmpty &&
      waVerifyToken != null &&
      waVerifyToken.isNotEmpty &&
      waAppSecret != null &&
      waAppSecret.isNotEmpty) {
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
    addGateway(_WhatsAppReplyGateway(gateway));
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
  if (slackSigningSecret != null &&
      slackSigningSecret.isNotEmpty &&
      (slackWebhookUrl != null && slackWebhookUrl.isNotEmpty ||
          slackBotToken != null && slackBotToken.isNotEmpty)) {
    final slack = SlackGateway(
      webhookUrl: slackWebhookUrl,
      botToken: slackBotToken,
    );
    slackGw = slack;
    addGateway(_SlackReplyGateway(slack));
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
    addGateway(signal);
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
    addGateway(matrix);
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
  /// the skill registry. `/feedback up|down` without a slug rates the whole
  /// last turn (C1): skills of that turn get durable metrics and the
  /// self-evolution trajectory ledger re-blends its reward. Returns the
  /// reply text, or null when [m] is not a feedback command.
  Future<String?> maybeHandleFeedbackCommand(InboundMessage m) async {
    final text = m.text.trim();
    if (!text.toLowerCase().startsWith('/feedback')) return null;
    final parts = text.split(RegExp(r'\s+'));
    bool? parseVote(String raw) {
      final up = raw == 'up' || raw == '👍' || raw == '+1' || raw == 'yes';
      final down = raw == 'down' || raw == '👎' || raw == '-1' || raw == 'no';
      if (up) return true;
      if (down) return false;
      return null;
    }

    if (parts.length == 2) {
      final vote = parseVote(parts[1].toLowerCase());
      if (vote == null) {
        return 'Format: /feedback <slug> up|down (atau 👍/👎), '
            'atau /feedback up|down untuk turn terakhir.';
      }
      final skills = await rt.applyTurnFeedback(
        sessionId: m.sessionKey,
        positive: vote,
        actor: 'chat:${m.channel}',
      );
      final skillNote = skills.isEmpty
          ? 'tidak ada skill pada turn terakhir'
          : 'skill: ${skills.join(", ")}';
      return 'Feedback ${vote ? '👍' : '👎'} untuk turn terakhir dicatat '
          '($skillNote).';
    }
    if (parts.length < 3) {
      return 'Format: /feedback <slug> up|down (atau 👍/👎)';
    }
    final slug = parts[1];
    final raw = parts[2].toLowerCase();
    final positive = parseVote(raw);
    final negative = positive != null;
    if (!negative) {
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

  Future<void> handleMessage(
    InboundMessage m, {
    Gateway? replyVia,
    void Function(String toolName)? onToolStart,
    void Function(ToolCallTrace trace)? onToolTrace,
  }) async {
    if (!rateLimiter.allow(m.userKey)) {
      await replyVia?.send(
        OutboundMessage(
          sessionKey: m.sessionKey,
          text: 'Rate limit — coba lagi nanti.',
        ),
      );
      return;
    }

    // Bot Mode runs before any approval prompt or live message is created,
    // so a dropped group message leaves no side effect on the platform.
    // Dispatch = ikat sesi ke bot yang di-mention (semantik `/bot use`);
    // persona + model bot kemudian disuntik otomatis oleh funnel chat.
    final botRoute = botRouter.route(
      text: m.text,
      isGroup: BotModeGate.isGroup(m),
    );
    if (botRoute.drops) {
      return;
    }
    if (botRoute.dispatches) {
      await rt.botStore.bind(m.sessionKey, botRoute.target!.id);
    }

    Future<bool> Function(ToolCall call, Session session, String approvalId)?
    confirm;
    if (tg != null && m.channel == 'telegram') {
      confirm = (call, sess, approvalId) => tg!.requestConfirm(
        sessionKey: m.sessionKey,
        requesterKey: m.userKey,
        prompt:
            'Izinkan *${call.name}*?\n`${call.args}`\n'
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
    final feedbackReply = await maybeHandleFeedbackCommand(m);
    if (feedbackReply != null) {
      await (gw?.send(
            OutboundMessage(sessionKey: m.sessionKey, text: feedbackReply),
          ) ??
          Future.value());
      if (gw == null && m.channel == 'cli')
        stdout.writeln('assistant> $feedbackReply');
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
      final live = DiscordLiveMessage(
        botToken: gw.botToken!,
        channelId: channelId,
      );
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
      onToolStart: onToolStart,
      onToolTrace: onToolTrace,
      attachments: m.attachments,
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
      // Idempotency key deterministik (jobId+runId): gateway yang platformnya
      // mendukung dedup (Matrix txnId, SMTP Message-ID) dapat mengenali
      // kirim ulang at-least-once dan tidak menggandakan pesan.
      await target.send(
        OutboundMessage(
          sessionKey: sessionKey,
          text: text,
          idempotencyKey: deliveryIdempotencyKey(job.id, runId),
        ),
      );
    },
  );
  stdout.writeln(
    'Scheduler aktif (dikelola TikoRuntime; delivery ack + retry)',
  );

  final webhooks = (wa != null || slackGw != null)
      ? WebhookEndpoint(
          whatsapp: wa,
          whatsappAppSecret: waAppSecret,
          slack: slackGw,
          slackSigningSecret: slackSigningSecret,
          onMessage: (m) => handleMessage(m),
        )
      : null;

  // Agent manager (P2-05): read-only view of the shared kanban board and
  // audit logs. A second KanbanBoard instance is safe: every mutation is
  // guarded by the same CrossProcessLock as the tool instance.
  final tasksBoard = KanbanBoard('${rt.dataDir}/kanban.json');
  final logsDirectory = Directory(rt.audit.directory);
  if (useApi) {
    // apiToken was validated and persisted before any background service ran.
    final token = apiToken!;
    // Typed GenUI actions (GUI-P0-04): spesifikasi yang dirender agen
    // didaftarkan per sesi sehingga POST /v1/ui/actions bisa memvalidasi
    // ownership, expiry, single-use, dan nilai form sebelum diteruskan.
    final uiActions = GenUiActionRegistry();

    /// Fase E (A2UI): daftarkan surface yang dirender agen dari balasan
    /// chat agar state tersimpan, event `surface.*` dipancarkan, dan aksi
    /// tombol bisa divalidasi (anti-replay) di POST /v1/ui/actions.
    void ingestA2uiSurfaces(String sessionKey, String reply) {
      for (final block in extractA2uiBlocks(reply)) {
        try {
          rt.a2ui.ingest(sessionKey, block.messages);
        } on FormatException {
          // event surface.rejected sudah dipancarkan bridge; balasan chat
          // tetap terkirim tanpa mengunci turn (fail-closed).
        }
      }
    }

    Future<String> httpMessage(InboundMessage m) async {
      final c = Completer<String>();
      await handleMessage(m, replyVia: _CollectGateway(c));
      String reply;
      try {
        reply = await c.future.timeout(const Duration(seconds: 180));
      } catch (_) {
        return '(timeout)';
      }
      for (final block in extractGenUiBlocks(reply)) {
        uiActions.register(m.sessionKey, block.spec);
      }
      ingestA2uiSurfaces(m.sessionKey, reply);
      return reply;
    }

    /// C4 Chat-UX: jalur WS dengan frame progress live — status mulai/selesai
    /// turn, nama tool yang mulai dieksekusi, dan per-tool selesai (durasi
    /// nyata, args tersanitasi runtime; hanya `path` yang diteruskan untuk
    /// kartu file). Socket ditutup gateway setelah `done` seperti biasa.
    Future<String> wsMessage(
      InboundMessage m,
      void Function(Map<String, dynamic> frame) progress,
    ) async {
      progress({
        'type': 'chat.status',
        'state': 'running',
        'session': m.sessionKey,
      });
      final c = Completer<String>();
      await handleMessage(
        m,
        replyVia: _CollectGateway(c),
        onToolStart: (name) =>
            progress({'type': 'chat.toolStart', 'name': name}),
        onToolTrace: (t) => progress({
              'type': 'chat.tool',
              'name': t.name,
              'is_error': t.isError,
              'duration_ms': t.durationMs,
              if (t.args['path'] is String) 'path': t.args['path'],
            }),
      );
      String reply;
      try {
        reply = await c.future.timeout(const Duration(seconds: 180));
      } catch (_) {
        reply = '(timeout)';
      }
      for (final block in extractGenUiBlocks(reply)) {
        uiActions.register(m.sessionKey, block.spec);
      }
      ingestA2uiSurfaces(m.sessionKey, reply);
      progress({
        'type': 'chat.status',
        'state': 'done',
        'session': m.sessionKey,
      });
      return reply;
    }

    final webRootDir = _findWebRoot();
    try {
      api = HttpApiServer(
        authToken: token,
        host: Platform.environment['API_HOST'] ?? '127.0.0.1',
        port: port,
        webhookEndpoint: webhooks,
        webRoot: webRootDir,
        onMessage: httpMessage,
        onMessageWithProgress: wsMessage,
        onCancelTurn: (sessionKey) async => rt.cancelTurn(sessionKey),
        surfacesProvider: (sessionKey) async => rt.a2ui.list(sessionKey),
        surfaceGetter: (id) async => rt.a2ui.get(id),
        surfaceDeleter: (id) => rt.a2ui.delete(id),
        uiActionHandler: (sessionKey, actionId, values, {surfaceId}) async {
          if (surfaceId != null) {
            // Aksi dari surface A2UI: validasi ownership + anti-replay via
            // surface bridge; gagal → GenUiActionRejected (400 di gateway).
            if (!rt.a2ui.consumeAction(sessionKey, surfaceId, actionId)) {
              throw const GenUiActionRejected(
                  'aksi surface tidak dikenal untuk sesi ini (tidak pernah '
                  'dirender, sudah dipakai, atau surface sudah dihapus)');
            }
            final text = values.isEmpty
                ? '/surface $surfaceId $actionId'
                : '/surface $surfaceId $actionId ${jsonEncode(values)}';
            final answer = await httpMessage(
              InboundMessage(
                channel: 'http',
                userKey: 'ui-action',
                sessionKey: sessionKey,
                text: text,
              ),
            );
            return {'ok': true, 'text': answer};
          }
          uiActions.validateAndConsume(sessionKey, actionId, values);
          final text = values.isEmpty
              ? '/ui $actionId'
              : '/ui $actionId ${jsonEncode(values)}';
          final answer = await httpMessage(
            InboundMessage(
              channel: 'http',
              userKey: 'ui-action',
              sessionKey: sessionKey,
              text: text,
            ),
          );
          return {'ok': true, 'text': answer};
        },
        listSessions: () async {
          final list = await rt.sessions.list();
          return list
              .map(
                (s) => {
                  'id': s.id,
                  'channel': s.channel,
                  'title': s.title,
                  'updated_at': s.updatedAt.toIso8601String(),
                  'turns': s.turns,
                },
              )
              .toList();
        },
        sessionMessages: (id, {required int limit, required int offset}) async {
          // recent(limit + offset) returns the most recent window oldest
          // first; dropping the last `offset` messages yields the page that
          // ends `offset` messages before the newest one.
          final window = await rt.sessions.recent(
            id,
            limit: ((limit + offset).clamp(1, 400)).toInt(),
          );
          if (offset >= window.length) return <Map<String, dynamic>>[];
          final ending = window.sublist(0, window.length - offset);
          final start = ending.length > limit ? ending.length - limit : 0;
          return [
            for (final m in ending.sublist(start))
              {'role': m.role, 'content': m.content},
          ];
        },
        deleteSession: (id) => rt.sessions.delete(id),
        renameSession: (id, title) => rt.sessions.rename(id, title),
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
        decideApproval: (id, allow, {actor}) async {
          final r = await rt.decideApproval(
            id,
            approve: allow,
            actor: actor ?? 'api',
          );
          return r != null;
        },
        onShutdown: () async {
          if (!shutdownSignal.isCompleted) shutdownSignal.complete();
        },
        skillApi: RuntimeSkillApi(rt),
        tasksProvider: () async =>
            (await tasksBoard.list()).map((t) => t.toJson()).toList(),
        researchRunsProvider: () async =>
            [for (final r in rt.researchRunStore.runs) r.toJson()],
        researchRunGetter: (runId) async {
          final record = rt.researchRunStore.get(runId);
          if (record == null) return null;
          final report =
              await rt.researchRunStore.readReport(record.reportName);
          return {
            'run': record.toJson(),
            'report': report,
          };
        },
        researchStarter: (body) => rt
            .runResearch(
              question: (body['question'] as String).trim(),
              maxConcurrency:
                  (body['max_concurrency'] as int?) ?? 3,
            )
            .then((r) => r.toJson()),
        logsProvider: () async {
          if (!await logsDirectory.exists()) return <Map<String, dynamic>>[];
          final files = <File>[];
          await for (final entity in logsDirectory.list()) {
            if (entity is File &&
                _baseName(entity.path).startsWith('audit-') &&
                entity.path.endsWith('.jsonl')) {
              files.add(entity);
            }
          }
          files.sort((a, b) => b.path.compareTo(a.path));
          return [
            for (final f in files)
              {'name': _baseName(f.path), 'bytes': await f.length()},
          ];
        },
        logContentProvider: (name) async {
          if (!name.startsWith('audit-') || !name.endsWith('.jsonl'))
            return null;
          final file = File('${logsDirectory.path}/$name');
          if (!await file.exists()) return null;
          const maxBytes = 64 * 1024;
          final length = await file.length();
          final start = length > maxBytes ? length - maxBytes : 0;
          final raf = await file.open();
          try {
            await raf.setPosition(start);
            var content = utf8.decode(
              await raf.read(maxBytes),
              allowMalformed: true,
            );
            if (start > 0) {
              final nl = content.indexOf('\n');
              if (nl >= 0) content = content.substring(nl + 1);
            }
            return {
              'name': name,
              'bytes': length,
              'truncated': start > 0,
              'content': content,
            };
          } finally {
            await raf.close();
          }
        },
        listBots: () async =>
            rt.botStore.list().map((b) => b.toJson()).toList(),
        getBot: (id) async => rt.botStore.get(id)?.toJson(),
        createBot: (body) async {
          final id = body['id'] as String;
          if (rt.botStore.get(id) != null) {
            throw ApiRequestException(409, 'conflict', 'bot "$id" sudah ada');
          }
          final profile = await rt.botStore.create(
            id: id,
            name: (body['name'] as String).trim(),
            persona: (body['persona'] as String?) ?? '',
            model: body['model'] as String?,
            greeting: (body['greeting'] as String?) ?? '',
          );
          final allowlist = (body['tool_allowlist'] as List?)
              ?.cast<String>()
              .toList();
          if (allowlist == null || allowlist.isEmpty) return profile.toJson();
          final updated = await rt.botStore.update(
            id,
            (b) => b.copyWith(toolAllowlist: allowlist),
          );
          return updated.toJson();
        },
        updateBot: (id, body) async {
          final current = rt.botStore.get(id);
          if (current == null) return null;
          final updated = current.copyWith(
            name: (body['name'] as String?)?.trim(),
            persona: body['persona'] as String?,
            model: body['model'] as String?,
            clearModel: body.containsKey('model') && body['model'] == null,
            greeting: body['greeting'] as String?,
            toolAllowlist: (body['tool_allowlist'] as List?)
                ?.cast<String>()
                .toList(),
          );
          final saved = await rt.botStore.update(id, (_) => updated);
          return saved.toJson();
        },
        deleteBot: (id) async {
          if (rt.botStore.get(id) == null) return false;
          await rt.botStore.delete(id);
          return true;
        },
        listBotBindings: () async => rt.botStore.bindings(),
        bindBot: (botId, sessionId) async {
          if (rt.botStore.get(botId) == null) return false;
          await rt.botStore.bind(sessionId, botId);
          return true;
        },
        unbindBot: (botId, sessionId) async {
          if (rt.botStore.get(botId) == null ||
              rt.botStore.boundBotId(sessionId) != botId) {
            return false;
          }
          await rt.botStore.unbind(sessionId);
          return true;
        },
        teamsProvider: () async => [
          for (final t in rt.botTeamStore.list()) t.toJson(),
        ],
        getTeam: (id) async => rt.botTeamStore.get(id)?.toJson(),
        createTeam: (body) async {
          final id = body['id'] as String;
          if (rt.botTeamStore.get(id) != null) {
            throw ApiRequestException(409, 'conflict', 'team "$id" sudah ada');
          }
          return (await _saveTeam(rt, id, body)).toJson();
        },
        updateTeam: (id, body) async {
          final current = rt.botTeamStore.get(id);
          if (current == null) return null;
          final members = body.containsKey('members')
              ? _parseTeamMembers(body['members'])
              : current.members;
          final name = ((body['name'] as String?) ?? current.name).trim();
          if (name.isEmpty) {
            throw ApiRequestException(
              400,
              'invalid_request',
              'name wajib diisi',
            );
          }
          final doc = BotTeamDoc(
            id: id,
            name: name,
            description:
                (body['description'] as String?) ?? current.description,
            members: members,
          );
          await rt.botTeamStore.save(doc);
          return doc.toJson();
        },
        deleteTeam: (id) => rt.botTeamStore.delete(id),
        teamRunsProvider: () => rt.botTeamStore.listRunReports(),
        teamRunStarter: (body) => rt
            .runBotTeam(
              goal: (body['goal'] as String).trim(),
              teamId: body['team_id'] as String?,
              verifyCommand: body['verify_command'] as String?,
              maxConcurrency:
                  (body['max_concurrency'] as int?) ?? 4,
            )
            .then((r) => r.toJson()),
        providersProvider: () async {
          final health = rt.providerHealth();
          return {
            'default': rt.defaultProviderId,
            'providers': [
              for (final id in rt.providerIds())
                {
                  'id': id,
                  if (rt.providerById(id) != null)
                    'capabilities': {
                      'tool_calling': rt
                          .providerById(id)!
                          .capabilities
                          .toolCalling,
                      'vision': rt.providerById(id)!.capabilities.vision,
                      'streaming': rt.providerById(id)!.capabilities.streaming,
                      'max_context': rt
                          .providerById(id)!
                          .capabilities
                          .maxContext,
                    },
                  'health': health[id],
                },
            ],
            'tiers': {
              for (final e in rt.config.tierProviders.entries)
                '${e.key}': e.value,
            },
            'session_overrides': rt.sessionModelOverrides(),
            'session_model_choices': rt.sessionModelChoices(),
          };
        },
        providerModels: (providerId) => rt.discoverProviderModels(providerId),
        sessionProviderSetter: (sessionId, arg, model) async {
          if (arg.toLowerCase() == 'default') {
            rt.clearSessionProvider(sessionId);
            return true;
          }
          return rt.setSessionModel(sessionId, arg.toLowerCase(), model);
        },
        pluginProvider: () async {
          final base = rt.pluginSnapshot();
          return {
            'plugins': base['plugins'],
            'events': base['events'],
            'tools': rt.toolCatalog(),
            'mcp': rt.mcpSnapshot(),
            'hooks': rt.hookSnapshot(),
          };
        },
        channelsProvider: () async => channelsSnapshot({
          'telegram': tg != null,
          'discord': gatewayForChannel('discord') != null,
          'email': email != null,
          'imap': imap != null,
          'whatsapp': wa != null,
          'slack': slackGw != null,
          'signal': gatewayForChannel('signal') != null,
          'matrix': gatewayForChannel('matrix') != null,
          'openai': openAiServer != null,
          'http': api != null,
        }),
        pluginConsentSetter: (plugin, action) async {
          final result = action == 'grant'
              ? await rt.grantPluginConsent(plugin)
              : await rt.revokePluginConsent(plugin);
          return {'ok': result.ok, 'message': result.message};
        },
        jobsProvider: () async => [
          // (wiring teams berada di atas; helper _saveTeam di bawah)
          for (final job in rt.jobs.all)
            {
              'id': job.id,
              'cron': job.cron,
              'prompt': job.prompt,
              'channel': job.channel,
              'user_key': job.userKey,
              'enabled': job.enabled,
              'missed_policy': job.missedPolicy.name,
              'timezone': job.timezone,
              'next_run': job.nextRun.toUtc().toIso8601String(),
              'last_run': job.lastRun?.toUtc().toIso8601String(),
              'delivery_state': job.deliveryState,
              'paused': job.paused,
              'skill': job.skill,
              'last_status': job.lastStatus,
              'last_error': job.lastError,
              'failure_streak': job.failureStreak,
            },
        ],
        createJob: (body) async {
          try {
            final job = await rt.jobs.addAndSave(
              cron: body['cron'] as String,
              prompt: body['prompt'] as String,
              channel: (body['channel'] as String?)?.trim() ?? 'http',
              userKey: (body['user_key'] as String?)?.trim() ?? 'admin',
              missedPolicy: _missedPolicy(body['missed_policy'] as String?),
              timezone:
                  ((body['timezone'] as String?)?.trim().isNotEmpty ?? false)
                  ? (body['timezone'] as String).trim()
                  : 'UTC',
              skill: (body['skill'] as String?)?.trim(),
            );
            return job.toJson();
          } on FormatException catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        updateJob: (id, body) async {
          try {
            final job = rt.jobs.update(
              id,
              cron: body['cron'] as String?,
              prompt: body['prompt'] as String?,
              channel: (body['channel'] as String?)?.trim(),
              userKey: (body['user_key'] as String?)?.trim(),
              enabled: body['enabled'] as bool?,
              missedPolicy: body['missed_policy'] as String?,
              timezone: (body['timezone'] as String?)?.trim(),
              paused: body['paused'] as bool?,
              skill: body['skill'] as String?,
            );
            return job?.toJson();
          } on FormatException catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        deleteJob: (id) async {
          final ok = rt.jobs.remove(id);
          if (ok) await rt.jobs.save();
          return ok;
        },
        runJobNow: (id) async {
          final job = rt.jobs.runNow(id);
          if (job == null) return null;
          await rt.jobs.save();
          return job.toJson();
        },
        pauseJob: (id, paused) async {
          final job = rt.jobs.setPaused(id, paused);
          if (job == null) return null;
          await rt.jobs.save();
          return job.toJson();
        },
        securityProvider: () async {
          final snapshot = rt.securitySnapshot();
          snapshot['active_sessions'] = (await rt.sessions.list()).length;
          return snapshot;
        },
        auditQueryProvider: (filters) => rt.auditQuery(
          tool: filters['tool'] as String?,
          session: filters['session'] as String?,
          risk: filters['risk'] as String?,
          verdict: filters['verdict'] as String?,
          taint: filters['taint'] as bool?,
          since: filters['since'] as DateTime?,
          until: filters['until'] as DateTime?,
          limit: filters['limit'] as int? ?? 50,
          offset: filters['offset'] as int? ?? 0,
        ),
        artifactsListProvider: (dir) async {
          try {
            return rt.artifactsList(sub: dir);
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        artifactsReadProvider: (path) async {
          try {
            return rt.artifactsRead(path);
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          } on StateError catch (e) {
            throw ApiRequestException(404, 'not_found', '$e');
          }
        },
        artifactsDiffProvider: (path) async {
          try {
            return rt.artifactsDiff(path);
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        runsProvider: () async => rt.turnInspectorSnapshot(),
        memoryCuratedProvider: () async => rt.memoryCuratedGet(),
        memoryCuratedSetProvider: (body) async {
          try {
            return await rt.memoryCuratedSet(
              file: body['file'] as String,
              text: body['text'] as String,
            );
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        memoryLayersProvider: (filters) async => rt.memoryLayersGet(
          query: filters['q'] as String?,
          limit: filters['limit'] as int? ?? 200,
        ),
        memoryLayerAddProvider: (body) async {
          try {
            return await rt.memoryLayerAdd(
              layer: body['layer'] as String,
              text: body['text'] as String,
              importance: body['importance'] as double? ?? 0.5,
              tags: [for (final t in (body['tags'] as List? ?? const [])) '$t'],
              ownerKey: body['owner_key'] as String?,
              sourceSession: body['source_session'] as String?,
            );
          } on ArgumentError catch (e) {
            throw ApiRequestException(400, 'invalid_request', '$e');
          }
        },
        memoryLayerDeleteProvider: (id) async {
          try {
            return await rt.memoryLayerDelete(id);
          } on StateError catch (e) {
            throw ApiRequestException(404, 'not_found', '$e');
          }
        },
        memoryRagProvider: () async => rt.memoryRagSources(),
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
      if (webRootDir != null) {
        stdout.writeln('UI http://127.0.0.1:$port/');
        _openLocalBrowser('http://127.0.0.1:$port/');
      } else {
        stderr.writeln(
          'Web UI tidak tersedia: build Flutter Web tidak ditemukan.');
        stderr.writeln(
          'Jalankan: cd apps/agent_flutter && flutter build web --release, '
              'atau set WEB_ROOT=/path/ke/build/web, lalu restart daemon.',
        );
      }
      stdout.writeln(
        'Token tersimpan di ${ApiTokenStore.pathFor(rt.dataDir)} (permission 600).',
      );
    } on SocketException catch (e) {
      stderr.writeln(
        'Gagal bind port $port: $e\n'
        'tiko doctor — atau ubah api.port / hentikan proses lain.',
      );
      await api?.stop();
      await rt.close();
      for (final gateway in gateways) {
        try {
          await gateway.close();
        } catch (_) {} // best-effort
      }
      await lock.release();
      exit(1);
    } catch (error) {
      stderr.writeln('API startup gagal: $error');
      await api?.stop();
      await rt.close();
      for (final gateway in gateways) {
        try {
          await gateway.close();
        } catch (_) {} // best-effort
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
      stderr.writeln(
        'OPENAI_API_KEY terlalu pendek; minimal 32 karakter (128-bit).',
      );
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
    subs.add(
      gw.inbound.listen((m) {
        unawaited(handleMessage(m, replyVia: gw));
      }),
    );
  }

  final interactive =
      !useApi && (forceCli || (stdin.hasTerminal && gateways.isEmpty));

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
      await handleMessage(
        InboundMessage(
          channel: 'cli',
          userKey: 'local',
          sessionKey: 'cli:local',
          text: text,
        ),
      );
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
    } catch (_) {} // best-effort
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
    await imapSub?.cancel();
    await imap?.stop();
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
  } catch (_) {} // best-effort
  // Exit explicitly: lingering signal watchers, timers, or sockets can keep
  // the VM alive after main returns even though shutdown already completed.
  exit(clean ? 0 : 1);
}

Future<List<AcpHistoryEntry>?> _loadAcpSession(
  TikoRuntime rt,
  String sid,
) async {
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

/// GUI-P1-09: normalisasi missed_policy dari HTTP (skip | run_once |
/// catch_up, case-insensitive) ke enum [MissedPolicy].
MissedPolicy _missedPolicy(String? name) {
  if (name == null) return MissedPolicy.runOnce;
  final normalized = name.replaceAll('_', '').toLowerCase();
  for (final candidate in MissedPolicy.values) {
    if (candidate.name.toLowerCase() == normalized) return candidate;
  }
  throw ArgumentError('invalid missed_policy: $name');
}

/// GUI-P1-07: snapshot status channel gateway (read-only). [active] adalah
/// channel -> status aktif saat daemon start; hanya **nama** variabel env
/// yang diiklankan — nilai rahasia tidak pernah dilewati ke HTTP.
Future<Map<String, dynamic>> channelsSnapshot(Map<String, bool> active) async =>
    {
      'channels': [
        for (final e in active.entries)
          {
            'channel': e.key,
            'active': e.value,
            'env': _channelEnv[e.key] ?? const <String>[],
          },
      ],
    };

/// Nama variabel env per channel (GUI-P1-07) — setup via env + restart.
const Map<String, List<String>> _channelEnv = {
  'telegram': ['TG_TOKEN', 'TG_ALLOW', 'WHISPER_BIN', 'STT_API_KEY'],
  'discord': [
    'DISCORD_WEBHOOK',
    'DISCORD_BOT_TOKEN',
    'DISCORD_ALLOW',
    'DISCORD_APP_ID',
  ],
  'email': ['EMAIL_FROM', 'SMTP_HOST', 'SMTP_PORT', 'EMAIL_ALLOW'],
  'imap': [
    'IMAP_HOST',
    'IMAP_PORT',
    'IMAP_USER',
    'IMAP_PASSWORD',
    'IMAP_ALLOW',
    'IMAP_POLL_SEC',
  ],
  'whatsapp': [
    'WHATSAPP_PHONE_NUMBER_ID',
    'WHATSAPP_ACCESS_TOKEN',
    'WHATSAPP_VERIFY_TOKEN',
    'WHATSAPP_APP_SECRET',
  ],
  'slack': ['SLACK_WEBHOOK_URL', 'SLACK_BOT_TOKEN', 'SLACK_SIGNING_SECRET'],
  'signal': ['SIGNAL_RPC_URL', 'SIGNAL_ACCOUNT', 'SIGNAL_ALLOW'],
  'matrix': ['MATRIX_HOMESERVER', 'MATRIX_ACCESS_TOKEN', 'MATRIX_ALLOW'],
  'openai': ['OPENAI_API_PORT', 'OPENAI_API_KEY'],
  'http': ['API_HOST', 'API_PORT'],
};

/// Auto-open the web dashboard after the HTTP server starts (Jalur A fase 2).
/// Hanya untuk bind loopback; daemon yang di-spawn app Flutter desktop /
/// scheduler lain menyetel TIKO_NO_BROWSER=1 agar tidak ada tab ekstra.
void _openLocalBrowser(String url) {
  final env = Platform.environment;
  if (env['TIKO_NO_BROWSER'] == '1' || env['TIKO_OPEN_BROWSER'] == '0') {
    return;
  }
  final bind = (env['API_HOST'] ?? '127.0.0.1').toLowerCase();
  if (bind != '127.0.0.1' && bind != 'localhost' && bind != '::1') return;
  final command = Platform.isWindows
      ? 'cmd'
      : Platform.isMacOS
          ? 'open'
          : 'xdg-open';
  final arguments = Platform.isWindows ? ['/c', 'start', '', url] : [url];
  Process.run(command, arguments).ignore();
}

String? _findWebRoot() {
  // Jalur A fase 3: satu-satunya web UI adalah hasil `flutter build web`;
  // dashboard vanilla apps/agentd/web sudah dipensiunkan (lihat docs/10).
  final env = Platform.environment['WEB_ROOT'];
  if (env != null && env.isNotEmpty && File('$env/index.html').existsSync()) {
    return env;
  }
  for (final c in [
    'apps/agent_flutter/build/web',
    '${Directory.current.path}/apps/agent_flutter/build/web',
    '../apps/agent_flutter/build/web',
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

String _baseName(String path) {
  final idx = path.lastIndexOf('/');
  return idx < 0 ? path : path.substring(idx + 1);
}

/// Fase C — mapper payload tim REST → [BotTeamDoc] tersimpan. Persona
/// wajib (satu-satunya pembeda perilaku antar anggota); tanpa allowlist
/// berarti anggota berjalan tanpa tool (fail-closed, kontrak agent_team).
Future<BotTeamDoc> _saveTeam(
  TikoRuntime rt,
  String id,
  Map<String, dynamic> body,
) async {
  final name = ((body['name'] as String?) ?? '').trim();
  final membersBody = body['members'];
  final members = membersBody is List
      ? _parseTeamMembers(membersBody)
      : const <AgentSpec>[];
  if (name.isEmpty) {
    throw ApiRequestException(400, 'invalid_request', 'name wajib diisi');
  }
  if (members.isEmpty) {
    throw ApiRequestException(
      400,
      'invalid_request',
      'members wajib berupa daftar 1..12 anggota ({id, prompt, ...})',
    );
  }
  final doc = BotTeamDoc(
    id: id,
    name: name,
    description: (body['description'] as String?) ?? '',
    members: members,
  );
  await rt.botTeamStore.save(doc);
  return doc;
}

List<AgentSpec> _parseTeamMembers(Object? raw) {
  if (raw is! List) {
    throw ApiRequestException(
      400,
      'invalid_request',
      'members wajib berupa daftar',
    );
  }
  if (raw.isEmpty || raw.length > 12) {
    throw ApiRequestException(
      400,
      'invalid_request',
      'members wajib 1..12 anggota',
    );
  }
  final out = <AgentSpec>[];
  for (final item in raw) {
    if (item is! Map) {
      throw ApiRequestException(400, 'invalid_request', 'member harus objek');
    }
    final m = Map<String, dynamic>.from(item);
    m['system_prompt'] ??= m.remove('prompt');
    m['tool_allowlist'] ??= m.remove('tools');
    m['model_tier'] ??= m.remove('tier');
    m['max_turns'] ??= m.remove('max_turns');
    final spec = AgentSpec.fromJson(m);
    if (spec.id.trim().isEmpty || spec.systemPrompt.trim().isEmpty) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'member butuh id dan prompt',
      );
    }
    out.add(AgentSpec(
      id: spec.id.trim(),
      role: spec.role,
      systemPrompt: spec.systemPrompt.trim(),
      toolAllowlist: spec.toolAllowlist,
      modelTier: spec.modelTier,
      maxTurns: spec.maxTurns,
    ));
  }
  return out;
}
