import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'webhook_endpoint.dart';
import 'skill_api.dart';

typedef MessageHandler = Future<String> Function(InboundMessage message);

/// C4 Chat-UX: handler dengan jalur progress — frame `Map` dikirim langsung
/// ke klien WS pemesan saat turn berjalan (`chat.status`, `chat.tool`, dll).
typedef MessageHandlerWithProgress = Future<String> Function(
  InboundMessage message,
  void Function(Map<String, dynamic> frame) progress,
);

/// Exception yang dilempar callback API untuk memetakan kegagalan domain
/// (convlict/not found/dsb.) ke respons HTTP typed via [_error] alih-alih
/// 500 generik. (GUI-P1-04)
class ApiRequestException implements Exception {
  ApiRequestException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'ApiRequestException($status, $code): $message';
}

/// HTTP + WebSocket API + static web UI for beginners.
class HttpApiServer {
  HttpApiServer({
    required this.onMessage,
    required this.authToken,
    this.host = '127.0.0.1',
    this.port = 8787,
    this.statusProvider,
    this.listMemories,
    this.deleteMemory,
    this.webRoot,
    this.listSessions,
    this.sessionMessages,
    this.uiActionHandler,
    this.surfacesProvider,
    this.surfaceGetter,
    this.surfaceCreator,
    this.surfaceDeleter,
    this.deleteSession,
    this.renameSession,
    this.doctorProvider,
    this.capabilitiesProvider,
    this.eventsProvider,
    this.listApprovals,
    this.decideApproval,
    this.eventStream,
    this.onShutdown,
    this.webhookEndpoint,
    this.skillApi,
    this.tasksProvider,
    this.logsProvider,
    this.logContentProvider,
    this.listBots,
    this.getBot,
    this.createBot,
    this.updateBot,
    this.deleteBot,
    this.listBotBindings,
    this.bindBot,
    this.unbindBot,
    this.teamsProvider,
    this.getTeam,
    this.createTeam,
    this.updateTeam,
    this.deleteTeam,
    this.teamRunsProvider,
    this.teamRunStarter,
    this.providersProvider,
    this.providerModels,
    this.sessionProviderSetter,
    this.pluginProvider,
    this.pluginConsentSetter,
    this.hooksSnapshotProvider,
    this.hookAddProvider,
    this.hookUpdateProvider,
    this.hookDeleteProvider,
    this.hookTestProvider,
    this.channelsProvider,
    this.jobsProvider,
    this.createJob,
    this.updateJob,
    this.deleteJob,
    this.runJobNow,
    this.pauseJob,
    this.researchRunsProvider,
    this.researchRunGetter,
    this.researchStarter,
    this.securityProvider,
    this.auditQueryProvider,
    this.artifactsListProvider,
    this.artifactsReadProvider,
    this.artifactsDiffProvider,
    this.runsProvider,
    this.memoryCuratedProvider,
    this.memoryCuratedSetProvider,
    this.memoryLayersProvider,
    this.memoryLayerAddProvider,
    this.memoryLayerDeleteProvider,
    this.memoryRagProvider,
    this.onMessageWithProgress,
    this.onCancelTurn,
    this.smartHomeProviders,
    this.smartHomeDevices,
    this.smartHomeDevice,
    this.smartHomeExecute,
  });

  final MessageHandler onMessage;

  /// F6 (docs/15 §7) — smart-home user-facing REST (read-only + execute).
  /// Null = smart-home tidak dikonfigurasi host (gateway balas 501).
  final Future<List<String>> Function()? smartHomeProviders;
  final Future<List<Map<String, dynamic>>> Function(String? provider)?
      smartHomeDevices;
  final Future<Map<String, dynamic>?> Function(String provider, String deviceId)?
      smartHomeDevice;
  final Future<Map<String, dynamic>> Function(
    String provider,
    String deviceId,
    Map<String, dynamic> command,
  )? smartHomeExecute;

  /// C4 Chat-UX: bila diset, WS `/v1/stream` memakainya (menggantikan
  /// [onMessage]) dan meneruskan frame progress ke klien yang meminta.
  final MessageHandlerWithProgress? onMessageWithProgress;

  /// C4 Chat-UX: permintaan stop dari WS (`{type: cancel, session_key}`);
  /// kembalikan true bila sinyal pembatalan terkirim (kooperatif).
  final Future<bool> Function(String sessionKey)? onCancelTurn;
  final String authToken;
  final String host;
  final int port;
  final Map<String, Object?> Function()? statusProvider;
  final Future<List<Map<String, dynamic>>> Function()? listMemories;
  final Future<bool> Function(String id)? deleteMemory;
  final String? webRoot;
  final Future<List<Map<String, dynamic>>> Function()? listSessions;

  /// Transcript of one session, oldest first. [offset] skips that many most
  /// recent messages so clients can page backwards (load-earlier).
  final Future<List<Map<String, dynamic>>> Function(
    String sessionId, {
    required int limit,
    required int offset,
  })?
  sessionMessages;
  final Future<bool> Function(String sessionId)? deleteSession;
  final Future<bool> Function(String sessionId, String title)? renameSession;

  /// Typed GenUI action (GUI-P0-04): memvalidasi action id terhadap registry
  /// per sesi (ownership + expiry + single-use + nilai form), lalu meneruskan
  /// aksi ke agent loop. Melempar GenUiActionRejected bila tidak valid.
  /// Fase E: [surfaceId] diisi klien bila aksi berasal dari surface A2UI;
  /// host memvalidasi ownership + anti-replay aksi surface tersebut.
  final Future<Map<String, dynamic>> Function(
    String sessionKey,
    String actionId,
    Map<String, dynamic> values, {
    String? surfaceId,
  })?
  uiActionHandler;

  /// A2UI surfaces (Fase E). Callback null membuat endpoint terkait
  /// merespons 501 not_implemented (fail-closed, pola `/v1/teams`).
  final Future<List<Map<String, dynamic>>> Function(String? sessionKey)?
      surfacesProvider;
  final Future<Map<String, dynamic>?> Function(String surfaceId)?
      surfaceGetter;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      surfaceCreator;
  final Future<bool> Function(String surfaceId)? surfaceDeleter;
  final Future<List<Map<String, dynamic>>> Function()? doctorProvider;
  final Map<String, Object?> Function()? capabilitiesProvider;
  final List<Map<String, dynamic>> Function()? eventsProvider;
  final Future<List<Map<String, dynamic>>> Function()? listApprovals;
  final Future<bool> Function(String id, bool approve, {String? actor})?
  decideApproval;
  final Stream<Map<String, dynamic>>? eventStream;
  final Future<void> Function()? onShutdown;

  /// Inbound platform webhooks (WhatsApp/Slack) mounted on this server.
  final WebhookEndpoint? webhookEndpoint;

  static final Random _rng = Random.secure();

  /// Format action id GenUI (sama dengan parser D1: [A-Za-z0-9_.-], 1-64).
  static final RegExp _safeActionId = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');

  /// Aktor approval dari client (GUI-P0-06): dibatasi 64 karakter tanpa
  /// karakter kontrol; null bila tidak tersedia agar wiring daemon memakai
  /// default 'api'.
  static String? _sanitizeActor(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  /// Validasi payload bot (GUI-P1-04): id cocok pola BotProfile.isValidId
  /// di tiko_runtime, name wajib string non-kosong, field di-whitelist.
  static final RegExp _botIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  /// C2 Chat-UX: batas lampiran inline ({name, mime, data_base64}).
  /// Deviasi dari docs/11 (yang menghendaki endpoint upload + id): gateway
  /// stateless, jadi lampiran dikirim inline base64 per pesan dengan cap
  /// ketat — tanpa file yang tersimpan di gateway.
  static const _attachmentMaxCount = 4;
  static const _attachmentMaxBytes = 2 * 1024 * 1024;
  static final RegExp _attachmentNamePattern =
      RegExp(r'^[A-Za-z0-9._() -]{1,128}$');
  static const _attachmentExtraMimes = {
    'application/json',
    'application/x-ndjson',
    'application/yaml',
    'application/x-yaml',
    'application/toml',
    'application/xml',
    'application/javascript',
    'application/x-sh',
  };
  static const _attachmentImageMimes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  };

  static bool _attachmentMimeAllowed(String mime) {
    if (mime.startsWith('image/')) {
      return _attachmentImageMimes.contains(mime);
    }
    if (mime.startsWith('text/')) return true;
    return _attachmentExtraMimes.contains(mime);
  }

  /// Validasi `attachments` fail-closed: maksimum [_attachmentMaxCount] file,
  /// nama aman 1-128 karakter, mime allowlist (text/*, application subset,
  /// image png/jpeg/gif/webp), isi base64 valid, size maksimum 2 MiB.
  /// Melempar [ApiRequestException] 400 dengan pesan bahasa Indonesia.
  static List<Attachment> _parseAttachments(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'attachments harus berupa array {name, mime, data_base64}.',
      );
    }
    if (raw.length > _attachmentMaxCount) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'maksimum $_attachmentMaxCount lampiran per pesan '
        '(diterima ${raw.length}).',
      );
    }
    final out = <Attachment>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran #${i + 1} harus berupa object {name, mime, data_base64}.',
        );
      }
      final name = (item['name'] as String? ?? '').trim();
      if (!_attachmentNamePattern.hasMatch(name)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran #${i + 1}: nama wajib 1-128 karakter alfanumerik '
          '(boleh . _ ( ) - spasi).',
        );
      }
      final mime = (item['mime'] as String? ?? '').trim().toLowerCase();
      if (!_attachmentMimeAllowed(mime)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran "$name": mime "$mime" tidak didukung. '
          'Yang didukung: text/*, application/json|yaml|toml|xml|javascript|x-ndjson|x-sh, '
          'image/png|jpeg|gif|webp.',
        );
      }
      final data = item['data_base64'];
      if (data is! String || data.trim().isEmpty) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran "$name": data_base64 wajib string base64 non-kosong.',
        );
      }
      var normalized = data.replaceAll(RegExp(r'\s'), '');
      final mod = normalized.length % 4;
      if (mod == 1) {
        throw ApiRequestException(400, 'invalid_request',
            'lampiran "$name": panjang base64 tidak valid.');
      }
      if (mod == 2) normalized = '$normalized==';
      if (mod == 3) normalized = '$normalized=';
      Uint8List bytes;
      try {
        bytes = Uint8List.fromList(base64.decode(normalized));
      } on FormatException {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran "$name": data_base64 tidak dapat didekode.',
        );
      }
      if (bytes.length > _attachmentMaxBytes) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'lampiran "$name" terlalu besar: ${bytes.length} byte; '
          'maksimum $_attachmentMaxBytes byte (2 MiB).',
        );
      }
      out.add(Attachment(
        type: mime.startsWith('image/') ? 'image' : 'document',
        urlOrBytes: bytes,
        mime: mime,
        name: name,
      ));
    }
    return out;
  }

  /// Error respons dalam bentuk OpenAI-compatible (`error.{message,type}`)
  /// agar klien OpenAI/LibreChat dapat menampilkannya apa adanya.
  void _openaiError(
    HttpRequest req,
    int status,
    String type,
    String message,
  ) {
    req.response.statusCode = status;
    _json(req, {
      'error': {'message': message, 'type': type, 'code': type},
    });
  }

  /// Id chatcmpl deterministik-acak 24 hex (mustahil tabrakan untuk
  /// konten sebar; cukup untuk idikasi klien).
  static String _openaiId() {
    final vals = List<int>.generate(12, (_) => _rng.nextInt(256));
    return vals.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Konversi `content` OpenAI (string atau array parts) menjadi teks;
  /// null bila format tidak didukung (fail-closed).
  static String? _openaiContentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final piece in content) {
        if (piece is! Map) return null;
        final type = piece['type'];
        final text = piece['text'];
        if (type != 'text' || text is! String) return null;
        parts.add(text);
      }
      return parts.join('\n');
    }
    return null;
  }

  /// Map `messages` OpenAI menjadi satu prompt turn runtime:
  /// system block pertama, transcript percakapan sebelumnya sebagai
  /// konteks, user message terakhir paling akhir (dominan).
  /// Null bila tidak ada user message teks / role tak didukung (fail-closed).
  static String? _openaiPrompt(List messages) {
    final system = <String>[];
    final transcript = <String>[];
    String? lastUser;
    for (final m in messages) {
      if (m is! Map) return null;
      final role = m['role'];
      final content = _openaiContentText(m['content']);
      if (role is! String || content == null) return null;
      final text = content.trim();
      if (role == 'system') {
        system.add(text);
      } else if (role == 'user') {
        transcript.add('User: $text');
        lastUser = text;
      } else if (role == 'assistant') {
        transcript.add('Assistant: $text');
      } else {
        return null;
      }
    }
    if (lastUser == null) return null;
    final buf = StringBuffer();
    if (system.isNotEmpty) {
      buf.writeln('[system]');
      buf.writeln(system.join('\n'));
      buf.writeln('[/system]');
    }
    final rest = transcript.length > 1
        ? transcript.sublist(0, transcript.length - 1)
        : <String>[];
    if (rest.isNotEmpty) {
      buf.writeln('[transcript percakapan sebelumnya — hanya konteks]');
      buf.write(rest.join('\n\n'));
      buf.writeln('\n[/transcript]');
    }
    buf.write(lastUser);
    return buf.toString();
  }
  static const _botCreateKeys = {
    'id',
    'name',
    'persona',
    'model',
    'greeting',
    'tool_allowlist',
  };
  static const _botUpdateKeys = {
    'name',
    'persona',
    'model',
    'greeting',
    'tool_allowlist',
  };

  /// Validasi payload `POST /v1/plugins/consent` (GUI-P1-06): plugin
  /// nama non-kosong maks 64, action wajib `grant`/`revoke`.
  Map<String, dynamic> _validatePluginConsentPayload(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'body wajib berupa mapping {plugin, action}',
      );
    }
    final plugin = decoded['plugin'];
    if (plugin is! String ||
        plugin.trim().isEmpty ||
        plugin.trim().length > 64) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'plugin wajib nama non-kosong maksimal 64 karakter',
      );
    }
    final action = decoded['action'];
    if (action is! String || (action != 'grant' && action != 'revoke')) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'action wajib grant atau revoke',
      );
    }
    return {'plugin': plugin.trim().toLowerCase(), 'action': action};
  }

  /// Path item hook `/v1/hooks/<n>` (SETTINGS-HOOKS) — hanya indeks numerik
  /// agar `/v1/hooks/test` tidak tertelan.
  static final _hookIndexRe = RegExp(r'^/v1/hooks/\d+$');

  int _parseHookIndex(String path) {
    final raw = path.split('/').last;
    final index = int.tryParse(raw);
    if (index == null) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'index hook wajib integer',
      );
    }
    return index;
  }

  /// Validasi payload POST/PATCH /v1/hooks (SETTINGS-HOOKS): satu mapping
  /// aturan `{event, webhook?/script?, timeout_sec?, env?}`. Validasi
  /// semantik penuh (range timeout, path script) di runtime `HookRuleConfig
  /// .validateJson` — tingkat server hanya menjamin bentuk mapping.
  Map<String, dynamic> _validateHookRulePayload(Object? decoded) {
    if (decoded is! Map<String, dynamic>) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'body wajib berupa mapping aturan hook '
            '{event, webhook/script, timeout_sec?, env?}',
      );
    }
    return decoded;
  }

  /// Validasi path query /v1/artifacts: non-kosong (kecuali dir), maksimal
  /// 256 karakter, tanpa rawan kontrol/NUL. Validasi keamanan penuh
  /// (symlink/escaping) di runtime via PathSafety — fail-closed.
  String _parseArtifactsPath(
    String? raw, {
    bool allowEmpty = false,
    required String field,
  }) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty && !allowEmpty) {
      throw ApiRequestException(
        400,
        'invalid_request',
        "parameter $field wajib",
      );
    }
    if (value.length > 256) {
      throw ApiRequestException(
        400,
        'invalid_request',
        "$field maksimal 256 karakter",
      );
    }
    if (value.contains('\u0000') ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw ApiRequestException(
        400,
        'invalid_request',
        "$field mengandung karakter invalid",
      );
    }
    return value;
  }

  /// Validasi payload PATCH /v1/memory/curated (GUI-P1-12): pilih file
  /// kurasi ('memory'/'user') + teks pengganti (string, sane cap).
  Map<String, dynamic> _validateMemoryCuratedPatch(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'body JSON object wajib',
      );
    }
    final file = raw['file'];
    if (file is! String || (file != 'memory' && file != 'user')) {
      throw ApiRequestException(
        400,
        'invalid_request',
        "file wajib 'memory' atau 'user'",
      );
    }
    final text = raw['text'];
    if (text is! String) {
      throw ApiRequestException(400, 'invalid_request', 'text string wajib');
    }
    if (text.length > 200000) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'text maksimal 200000 karakter',
      );
    }
    return {'file': file, 'text': text};
  }

  /// Normalisasi query string GET /v1/memory/layers (GUI-P1-12):
  /// q (opsional, substr retrieval) + limit 1..500.
  Map<String, dynamic> _parseMemoryLayersQuery(Map<String, String> q) {
    var limit = 200;
    final rawLimit = q['limit']?.trim() ?? '';
    if (rawLimit.isNotEmpty) {
      final parsed = int.tryParse(rawLimit);
      if (parsed == null) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'limit harus bilangan',
        );
      }
      if (parsed < 1 || parsed > 500) {
        throw ApiRequestException(400, 'invalid_request', 'limit wajib 1..500');
      }
      limit = parsed;
    }
    final query = q['q']?.trim() ?? '';
    return {
      'q': query.isEmpty ? null : (query.length > 256 ? null : query),
      'limit': limit,
    };
  }

  /// Validasi payload POST /v1/memory/layers (GUI-P1-12): layer enum,
  /// text wajib, importance 0..1, tags maks 12.
  Map<String, dynamic> _validateMemoryLayerPayload(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'body JSON object wajib',
      );
    }
    final layer = raw['layer'];
    if (layer is! String ||
        !['episodic', 'semantic', 'procedural'].contains(layer)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'layer wajib episodic/semantic/procedural',
      );
    }
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) {
      throw ApiRequestException(400, 'invalid_request', 'text wajib diisi');
    }
    if (text.length > 20000) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'text maksimal 20000 karakter',
      );
    }
    final importanceRaw = raw['importance'];
    if (importanceRaw is! num && importanceRaw != null) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'importance harus angka',
      );
    }
    final importance = (importanceRaw as num?)?.toDouble();
    if (importance != null && (importance < 0 || importance > 1)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'importance wajib 0..1',
      );
    }
    final tagsRaw = raw['tags'];
    if (tagsRaw is! List && tagsRaw != null) {
      throw ApiRequestException(400, 'invalid_request', 'tags harus array');
    }
    final tags = <String>[
      for (final tag in (tagsRaw as List? ?? const []))
        if (tag is String && tag.trim().isNotEmpty)
          (tag.trim().length > 64 ? tag.trim().substring(0, 64) : tag.trim()),
    ];
    if (tags.length > 12) {
      throw ApiRequestException(400, 'invalid_request', 'tags maksimal 12');
    }
    return {
      'layer': layer,
      'text': text,
      'importance': importance ?? 0.5,
      'tags': tags,
      if (raw['owner_key'] is String) 'owner_key': raw['owner_key'],
      if (raw['source_session'] is String)
        'source_session': raw['source_session'],
    };
  }

  /// Normalisasi + validasi query string /v1/audit menjadi filter typed.
  /// Nilai invalid (limit bukan angka, since/until bukan ISO, taint bukan
  /// boolean) → 400 invalid_request.
  Map<String, dynamic> _parseAuditQuery(Map<String, String> q) {
    final filters = <String, dynamic>{};
    String? text(String key, {int maxLen = 128}) {
      final value = q[key]?.trim();
      if (value == null || value.isEmpty) return null;
      if (value.length > maxLen) {
        throw ApiRequestException(
          400,
          'invalid_request',
          "$key maksimal $maxLen karakter",
        );
      }
      return value;
    }

    final tool = text('tool');
    if (tool != null) filters['tool'] = tool;
    final session = text('session');
    if (session != null) filters['session'] = session;
    final risk = text('risk', maxLen: 32);
    if (risk != null) filters['risk'] = risk;
    final verdict = text('verdict', maxLen: 32);
    if (verdict != null) filters['verdict'] = verdict;
    final taintRaw = text('taint', maxLen: 8);
    if (taintRaw != null) {
      final lower = taintRaw.toLowerCase();
      if (lower != 'true' && lower != 'false') {
        throw ApiRequestException(
          400,
          'invalid_request',
          "taint hanya 'true' atau 'false'",
        );
      }
      filters['taint'] = lower == 'true';
    }
    for (final key in const ['since', 'until']) {
      final raw = text(key, maxLen: 64);
      if (raw == null) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        throw ApiRequestException(
          400,
          'invalid_request',
          "$key bukan timestamp ISO valid",
        );
      }
      filters[key] = parsed.toUtc();
    }
    final limitRaw = q['limit']?.trim();
    if (limitRaw != null && limitRaw.isNotEmpty) {
      final parsed = int.tryParse(limitRaw);
      if (parsed == null || parsed < 1 || parsed > 200) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'limit harus angka 1..200',
        );
      }
      filters['limit'] = parsed;
    }
    final offsetRaw = q['offset']?.trim();
    if (offsetRaw != null && offsetRaw.isNotEmpty) {
      final parsed = int.tryParse(offsetRaw);
      if (parsed == null || parsed < 0) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'offset harus angka >= 0',
        );
      }
      filters['offset'] = parsed;
    }
    return filters;
  }

  void _validateJobPayload(
    Map<String, dynamic> body, {
    required bool forCreate,
  }) {
    const allowed = {
      'cron',
      'prompt',
      'channel',
      'user_key',
      'enabled',
      'missed_policy',
      'timezone',
      'paused',
      'skill',
      'context_from',
      'watch',
    };
    for (final key in body.keys) {
      if (!allowed.contains(key)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'field tidak dikenal: $key',
        );
      }
    }
    if (forCreate) {
      final cron = body['cron'];
      if (cron is! String || cron.trim().isEmpty) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'cron wajib diisi (ekspresi 5 field, mis. "*/5 * * * *")',
        );
      }
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        throw ApiRequestException(400, 'invalid_request', 'prompt wajib diisi');
      }
    }
    final cron = body['cron'];
    if (cron != null &&
        (cron is! String || cron.trim().isEmpty || cron.trim().length > 256)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'cron wajib string non-kosong maks 256',
      );
    }
    final prompt = body['prompt'];
    if (prompt != null &&
        (prompt is! String || prompt.trim().isEmpty || prompt.length > 10000)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'prompt wajib string 1..10000 karakter',
      );
    }
    final channel = body['channel'];
    if (channel != null &&
        (channel is! String ||
            channel.trim().isEmpty ||
            channel.trim().length > 64)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'channel wajib string non-kosong maks 64',
      );
    }
    final userKey = body['user_key'];
    if (userKey != null &&
        (userKey is! String ||
            userKey.trim().isEmpty ||
            userKey.trim().length > 256)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'user_key wajib string non-kosong maks 256',
      );
    }
    final enabled = body['enabled'];
    if (enabled != null && enabled is! bool) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'enabled wajib boolean',
      );
    }
    final paused = body['paused'];
    if (paused != null && paused is! bool) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'paused wajib boolean',
      );
    }
    final skill = body['skill'];
    if (skill != null &&
        (skill is! String ||
            skill.trim().isEmpty ||
            skill.trim().length > 64 ||
            skill.trim().contains(' '))) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'skill wajib slug non-kosong maks 64 tanpa spasi (telisan `all` untuk menghapus lampiran)',
      );
    }
    final policy = body['missed_policy'];
    if (policy != null) {
      if (policy is! String) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'missed_policy wajib string',
        );
      }
      const known = {'skip', 'runonce', 'catchup'};
      if (!known.contains(policy.replaceAll('_', '').toLowerCase())) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'missed_policy wajib skip | run_once | catch_up',
        );
      }
    }
    final timezone = body['timezone'];
    if (timezone != null &&
        (timezone is! String ||
            timezone.trim().isEmpty ||
            timezone.trim().length > 64)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'timezone wajib nama zona IANA maks 64',
      );
    }
    final contextFrom = body['context_from'];
    if (contextFrom != null && contextFrom is! List) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'context_from wajib array id job (maks 5)',
      );
    }
    if (contextFrom is List) {
      final valid = contextFrom.every(
        (e) => e is String && e.trim().isNotEmpty && e.trim().length <= 64,
      );
      if (!valid || contextFrom.length > 5) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'context_from wajib maks 5 id string 1..64 karakter',
        );
      }
    }
    final watch = body['watch'];
    if (watch != null) {
      if (watch is! Map) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'watch wajib objek {kind: url, url: ...}',
        );
      }
      final url = watch['url'];
      if (watch['kind'] != 'url' ||
          url is! String ||
          !(url.startsWith('http://') || url.startsWith('https://'))) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'watch wajib {kind: "url", url: scheme http(s)}',
        );
      }
    }
  }

  void _validateBotPayload(
    Map<String, dynamic> body, {
    required bool forCreate,
  }) {
    final allowed = forCreate ? _botCreateKeys : _botUpdateKeys;
    for (final key in body.keys) {
      if (!allowed.contains(key)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'field tidak dikenal: $key',
        );
      }
    }
    if (forCreate) {
      final id = body['id'];
      if (id is! String || !_botIdPattern.hasMatch(id)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'id bot wajib [a-z0-9][a-z0-9_-]{0,63}',
        );
      }
    }
    final name = body['name'];
    if (forCreate && (name is! String || name.trim().isEmpty)) {
      throw ApiRequestException(400, 'invalid_request', 'name wajib diisi');
    }
    if (name != null &&
        (name is! String || name.trim().isEmpty || name.trim().length > 128)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'name wajib string non-kosong maks 128',
      );
    }
    for (final key in const ['persona', 'greeting']) {
      final value = body[key];
      if (value != null && value is! String) {
        throw ApiRequestException(
          400,
          'invalid_request',
          '$key wajib berupa string',
        );
      }
    }
    final model = body['model'];
    if (model != null && model is! String) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'model wajib string atau null',
      );
    }
    final allowlist = body['tool_allowlist'];
    if (allowlist != null &&
        (allowlist is! List || allowlist.any((e) => e is! String))) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'tool_allowlist wajib berupa daftar string',
      );
    }
  }

  static final RegExp _teamIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static const Set<String> _teamUpdateKeys = {'name', 'description', 'members'};

  void _validateTeamPayload(
    Map<String, dynamic> body, {
    required bool forCreate,
  }) {
    final allowed = forCreate ? {'id', 'name', 'description', 'members'} : _teamUpdateKeys;
    for (final key in body.keys) {
      if (!allowed.contains(key)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'field tidak dikenal: $key',
        );
      }
    }
    if (forCreate) {
      final id = body['id'];
      if (id is! String || !_teamIdPattern.hasMatch(id)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'id team wajib [a-z0-9][a-z0-9_-]{0,63}',
        );
      }
    }
    if (forCreate && (body['name'] is! String || (body['name'] as String).trim().isEmpty)) {
      throw ApiRequestException(
        400,
        'invalid_request',
        'name wajib diisi',
      );
    }
    if (forCreate || body.containsKey('members')) {
      final members = body['members'];
      if (members is! List ||
          members.isEmpty ||
          members.length > 12 ||
          members.any((e) => e is! Map)) {
        throw ApiRequestException(
          400,
          'invalid_request',
          'members wajib berupa daftar 1..12 objek anggota '
          '({id, prompt, role?, tools?, tier?, max_turns?})',
        );
      }
    }
  }

  /// Skill management callbacks (P1-03).
  final SkillApi? skillApi;

  /// Agent manager callbacks (P2-05): kanban tasks, log files, log content.
  final Future<List<Map<String, dynamic>>> Function()? tasksProvider;
  final Future<List<Map<String, dynamic>>> Function()? logsProvider;
  final Future<Map<String, dynamic>?> Function(String name)? logContentProvider;

  /// Bot manager callbacks (GUI-P1-04). Callback yang null membuat endpoint
  /// terkait merespons 501 not_implemented.
  final Future<List<Map<String, dynamic>>> Function()? listBots;
  final Future<Map<String, dynamic>?> Function(String id)? getBot;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  createBot;
  final Future<Map<String, dynamic>?> Function(
    String id,
    Map<String, dynamic> body,
  )?
  updateBot;
  final Future<bool> Function(String id)? deleteBot;
  final Future<Map<String, String>> Function()? listBotBindings;
  final Future<bool> Function(String botId, String sessionId)? bindBot;
  final Future<bool> Function(String botId, String sessionId)? unbindBot;

  /// Fase C — orkestra bot team. Callback yang null membuat endpoint
  /// terkait merespons 501 not_implemented. `teamRunStarter` berjalan
  /// sinkron (orkestra bisa berjalan lama; progress via `/v1/stream`).
  final Future<List<Map<String, dynamic>>> Function()? teamsProvider;
  final Future<Map<String, dynamic>?> Function(String id)? getTeam;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  createTeam;
  final Future<Map<String, dynamic>?> Function(
    String id,
    Map<String, dynamic> body,
  )?
  updateTeam;
  final Future<bool> Function(String id)? deleteTeam;
  final Future<List<Map<String, dynamic>>> Function()? teamRunsProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  teamRunStarter;

  /// Provider & model manager callbacks (GUI-P1-05). Callback yang null
  /// membuat endpoint terkait merespons 501 not_implemented.
  final Future<Map<String, dynamic>> Function()? providersProvider;

  /// Live model discovery per provider (Hermes-parity); null → 501.
  final Future<Map<String, dynamic>> Function(String providerId)?
  providerModels;

  /// [model] null/'' berarti pakai model default provider.
  final Future<bool> Function(String sessionId, String providerArg,
      String? model)? sessionProviderSetter;

  /// Plugin & tools manager callbacks (GUI-P1-06). Callback yang null
  /// membuat endpoint terkait merespons 501 not_implemented.
  final Future<Map<String, dynamic>> Function()? pluginProvider;

  /// [action] adalah `grant` atau `revoke`; hasil memuat `ok` dan `message`.
  final Future<Map<String, dynamic>> Function(String plugin, String action)?
  pluginConsentSetter;

  /// Hooks manager callbacks (SETTINGS-HOOKS): snapshot aturan + statistik,
  /// CRUD aturan (berlaku live + persist config `hooks:`), dan uji fire.
  /// Callback null membuat endpoint `/v1/hooks*` merespons 501.
  final Future<Map<String, dynamic>> Function()? hooksSnapshotProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  hookAddProvider;
  final Future<Map<String, dynamic>> Function(int index, Map<String, dynamic> body)?
  hookUpdateProvider;
  final Future<Map<String, dynamic>> Function(int index)? hookDeleteProvider;
  final Future<Map<String, dynamic>> Function(int index)? hookTestProvider;

  /// Channels setup (GUI-P1-07): status channel gateway aktif + nama env
  /// yang mengonfigurasinya (read-only; env + restart untuk mengubah).
  final Future<Map<String, dynamic>> Function()? channelsProvider;

  /// Riset otomatis (Fase D). Callback yang null membuat endpoint
  /// `/v1/research/*` merespons 501 not_implemented.
  final Future<List<Map<String, dynamic>>> Function()? researchRunsProvider;
  final Future<Map<String, dynamic>?> Function(String runId)?
      researchRunGetter;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      researchStarter;

  /// Automation / cron CRUD callbacks (GUI-P1-09). Callback yang null
  /// membuat endpoint terkait merespons 501 not_implemented.
  final Future<List<Map<String, dynamic>>> Function()? jobsProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  createJob;
  final Future<Map<String, dynamic>?> Function(
    String id,
    Map<String, dynamic> body,
  )?
  updateJob;
  final Future<bool> Function(String id)? deleteJob;
  final Future<Map<String, dynamic>?> Function(String id)? runJobNow;
  final Future<Map<String, dynamic>?> Function(String id, bool paused)?
  pauseJob;

  /// Security Center callback (GUI-P1-10). Callback null membuat endpoint
  /// terkait merespons 501 not_implemented.
  final Future<Map<String, dynamic>> Function()? securityProvider;

  /// Audit query browser callback (GUI-P1-11). Menerima filter ternormalisasi
  /// (tool/session/risk/verdict string, taint bool, since/until DateTime,
  /// limit/offset int) — callback null membuat GET /v1/audit merespons 501.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> filters)?
  auditQueryProvider;

  /// Artifacts browser callbacks (GUI-P2-04, read-only). Masing-masing
  /// null membuat endpoint terkait merespons 501 not_implemented.
  final Future<Map<String, dynamic>> Function(String dir)?
  artifactsListProvider;
  final Future<Map<String, dynamic>> Function(String path)?
  artifactsReadProvider;
  final Future<Map<String, dynamic>> Function(String path)?
  artifactsDiffProvider;

  /// Run-inspector callback (GUI-P2-04, read-only): snapshot {active, recent,
  /// truncated} — callback null membuat GET /v1/runs merespons 501.
  final Future<Map<String, dynamic>> Function()? runsProvider;

  /// Memory Explorer callbacks (GUI-P1-12): kurasi MEMORY.md/USER.md
  /// (read + replace dengan anggaran), entri berlapis (list/add/delete),
  /// dan sumber RAG per dokumen — callback null membuat endpoint terkait
  /// merespons 501 not_implemented.
  final Future<Map<String, dynamic>> Function()? memoryCuratedProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  memoryCuratedSetProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> filters)?
  memoryLayersProvider;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  memoryLayerAddProvider;
  final Future<bool> Function(String id)? memoryLayerDeleteProvider;
  final Future<Map<String, dynamic>> Function()? memoryRagProvider;

  HttpServer? _server;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  int get boundPort => _server?.port ?? port;
  final _wsClients = <WebSocket>{};

  /// WebSocket event schema version (P2-6). Increment when event structure changes.
  static const _wsSchemaVersion = '1.0';
  int _wsEventCounter = 0;

  /// Bounded idempotency cache for POST /v1/messages.
  static const _idempotencyLimit = 256;
  final _idempotencyCache = <String, Future<Map<String, dynamic>>>{};

  Future<void> start() async {
    _server = await HttpServer.bind(host, port);
    _server!.listen(_handle);
    _eventSubscription = eventStream?.listen((event) {
      // Flutter chat uses the same persisted approval ID as the admin page.
      if (event['type'] == 'approval.pending') {
        final tool = event['tool'] ?? 'tool';
        broadcast({
          'type': 'confirm',
          'id': event['id'],
          'prompt': 'Izinkan $tool? ${event['args'] ?? ''}',
          'approval': event,
        });
      }
      broadcast({'type': 'event', 'event': event});
    });
  }

  Future<void> stop() async {
    await _eventSubscription?.cancel();
    for (final ws in _wsClients.toList()) {
      await ws.close();
    }
    await _server?.close(force: true);
  }

  bool _auth(HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    if (h.startsWith('Bearer ') &&
        _constantTimeEquals(h.substring(7), authToken)) {
      return true;
    }
    return _uiCookieAuthorized(req);
  }

  /// Same-origin web UI session (Jalur A fase 2): browser menerima cookie
  /// HttpOnly + SameSite=Strict saat memuat index UI; API menerima cookie
  /// ini sebagai pengganti Bearer sehingga pengguna tidak perlu memasukkan
  /// token di lokal. Permintaan cross-site ditolak dua lapis: browser tidak
  /// mengirim cookie SameSite=Strict, dan header `Origin` yang ada wajib
  /// cocok dengan host yang diizinkan. Host allowlist + bind loopback tetap
  /// jadi lapis pertama.
  bool _uiCookieAuthorized(HttpRequest req) {
    final cookies = req.headers.value(HttpHeaders.cookieHeader);
    if (cookies == null) return false;
    for (final part in cookies.split(';')) {
      final trimmed = part.trim();
      if (!trimmed.startsWith('$_uiCookieName=')) continue;
      final value = trimmed.substring(_uiCookieName.length + 1);
      if (_constantTimeEquals(value, _uiSecret)) {
        final origin = req.headers.value('origin');
        if (origin != null && !_originAllowed(origin)) return false;
        return true;
      }
    }
    return false;
  }

  bool _originAllowed(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    const loopback = {'127.0.0.1', 'localhost', '::1'};
    return loopback.contains(host) || host == this.host.toLowerCase();
  }

  /// Constant-time token comparison (B-08).
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < b.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Short-lived one-time tickets for WebSocket auth (B-08): browsers cannot
  /// set headers on WebSocket, so the UI exchanges its Bearer token for a
  /// 30-second single-use ticket via POST /v1/auth/ticket.
  static const _ticketTtl = Duration(seconds: 30);
  final _tickets = <String, DateTime>{};

  /// Same-origin UI session cookie (Jalur A fase 2) — lihat
  /// [_uiCookieAuthorized]. 32 byte acak per proses; mati setelah restart
  /// daemon karena nilai lama tidak lagi cocok.
  static const _uiCookieName = 'tiko_web_session';
  static const _uiCookieMaxAge = 86400; // Duration(hours: 24) — const-eval tidak boleh akses properti
  late final String _uiSecret = base64UrlEncode(
    List<int>.generate(32, (_) => _rng.nextInt(256)),
  );

  String _issueTicket() {
    final ticket = base64UrlEncode(
      List<int>.generate(32, (_) => _rng.nextInt(256)),
    );
    _tickets[ticket] = DateTime.now().add(_ticketTtl);
    while (_tickets.length > 256) {
      _tickets.remove(_tickets.keys.first);
    }
    return ticket;
  }

  bool _consumeTicket(String ticket) {
    final exp = _tickets.remove(ticket);
    if (exp == null) return false;
    return DateTime.now().isBefore(exp);
  }

  void _pruneTickets() {
    final now = DateTime.now();
    _tickets.removeWhere((_, exp) => now.isAfter(exp));
  }

  /// Reject requests whose Host header does not match the local bind
  /// (B-08: DNS-rebinding surface).
  bool _hostAllowed(HttpRequest req) {
    final host = (req.headers.value('host') ?? '').toLowerCase();
    if (host.isEmpty) return false;
    final hostname = host.contains(':') && !host.startsWith('[')
        ? host.substring(0, host.lastIndexOf(':'))
        : host;
    const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
    if (loopback.contains(hostname)) return true;
    return hostname == this.host.toLowerCase();
  }

  /// Executes [run] once per [key]; duplicate requests replay the stored
  /// response instead of re-running side effects. Failed runs are evicted
  /// so a retry gets a fresh chance.
  Future<Map<String, dynamic>> _runIdempotent(
    String key,
    Future<Map<String, dynamic>> Function() run,
  ) {
    final inFlight = _idempotencyCache[key];
    if (inFlight != null) return inFlight;
    final started = run();
    _idempotencyCache[key] = started;
    while (_idempotencyCache.length > _idempotencyLimit) {
      _idempotencyCache.remove(_idempotencyCache.keys.first);
    }
    unawaited(
      started.catchError((Object _) {
        _idempotencyCache.remove(key);
        return <String, dynamic>{};
      }),
    );
    return started;
  }

  Future<void> _handle(HttpRequest req) async {
    if (!_hostAllowed(req)) {
      req.response.statusCode = 421;
      await req.response.close();
      return;
    }
    req.response.headers.set(
      'Access-Control-Allow-Headers',
      'Authorization, Content-Type, Idempotency-Key',
    );
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;

    if (path == '/v1/auth/ticket' && req.method == 'POST') {
      if (!_auth(req)) {
        _error(req, 401, 'unauthorized', 'unauthorized');
        return;
      }
      _pruneTickets();
      _json(req, {
        'ticket': _issueTicket(),
        'ttl_seconds': _ticketTtl.inSeconds,
      });
      return;
    }

    // Static UI (no auth for assets — local bind only)
    if (req.method == 'GET' && _isStatic(path)) {
      await _serveStatic(req, path);
      return;
    }

    // Inbound platform webhooks authenticate with HMAC signatures, not
    // with the local bearer token, so they are routed before _auth.
    if (path == '/webhooks/whatsapp' ||
        path == '/webhooks/slack' ||
        path == '/webhooks/teams') {
      final endpoint = webhookEndpoint;
      if (endpoint == null) {
        _error(req, 403, 'forbidden', 'webhook endpoint not configured');
      } else {
        await endpoint.handle(req, path);
      }
      return;
    }

    if (path == '/v1/stream' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ticket = req.uri.queryParameters['ticket'];
      final authorized =
          (ticket != null && _consumeTicket(ticket)) || _auth(req);
      if (!authorized) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _wsClients.add(ws);
      ws.listen(
        (data) async {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            // C4 Chat-UX: permintaan stop kooperatif. Frame cancel diproses
            // lewat callback meskipun ada turn lain pada koneksi yang sama
            // yang sedang berjalan (callback listen tidak saling blokir).
            if (json['type'] == 'cancel') {
              if (onCancelTurn == null) {
                _sendWsEvent(ws, {'type': 'cancel_ack', 'ok': false});
                return;
              }
              final ok = await onCancelTurn!(
                json['session_key'] as String? ?? 'ws:default',
              );
              _sendWsEvent(ws, {'type': 'cancel_ack', 'ok': ok});
              return;
            }
            if (json['type'] == 'confirm_response') {
              final id = json['id'] as String? ?? '';
              final allow = json['allow'] == true;
              final actor = _sanitizeActor(json['actor'] as String?);
              final ok =
                  id.isNotEmpty &&
                  await (decideApproval?.call(id, allow, actor: actor) ??
                      Future.value(false));
              _sendWsEvent(ws, {'type': 'confirm_result', 'id': id, 'ok': ok});
              return;
            }
            final text = json['text'] as String? ?? '';
            final sessionKey = json['session_key'] as String? ?? 'ws:default';
            final userKey = json['user_key'] as String? ?? 'ws';
            if (text.isEmpty) return;
            final attachments = _parseAttachments(json['attachments']);
            _sendWsEvent(ws, {'type': 'typing'});
            final inbound = InboundMessage(
              channel: 'http',
              userKey: userKey,
              sessionKey: sessionKey,
              text: text,
              attachments: attachments,
            );
            final withProgress = onMessageWithProgress;
            final answer = withProgress == null
                ? await onMessage(inbound)
                : await withProgress(
                    inbound,
                    (frame) => _sendWsEvent(ws, frame),
                  );
            _sendWsEvent(ws, {'type': 'text', 'text': answer});
            _sendWsEvent(ws, {'type': 'done'});
            await ws.close();
          } on ApiRequestException catch (e) {
            _sendWsEvent(ws, {'type': 'error', 'message': e.message});
            await ws.close(WebSocketStatus.policyViolation, e.message);
          } catch (e) {
            _sendWsEvent(ws, {'type': 'error', 'message': e.toString()});
            await ws.close(
              WebSocketStatus.internalServerError,
              'request failed',
            );
          }
        },
        onDone: () => _wsClients.remove(ws),
        onError: (_) => _wsClients.remove(ws),
      );
      return;
    }

    if (!_auth(req) && path != '/health') {
      req.response.statusCode = 401;
      req.response.write(
        jsonEncode({
          'ok': false,
          'code': 'unauthorized',
          'error': 'unauthorized',
          'retryable': false,
        }),
      );
      await req.response.close();
      return;
    }

    try {
      if (path == '/health') {
        _json(req, {'ok': true});
      } else if (path == '/v1/status') {
        _json(req, statusProvider?.call() ?? {'ok': true});
      } else if (path == '/v1/sessions' && req.method == 'GET') {
        final sessions =
            await (listSessions?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'sessions': sessions});
      } else if (path.startsWith('/v1/sessions/') &&
          path.endsWith('/messages') &&
          req.method == 'GET') {
        final id = Uri.decodeComponent(
          path.substring(
            '/v1/sessions/'.length,
            path.length - '/messages'.length,
          ),
        );
        if (id.isEmpty ||
            id.contains('/') ||
            id.contains('\\') ||
            id.contains('..')) {
          _error(req, 400, 'invalid_request', 'invalid session id');
          return;
        }
        final api = sessionMessages;
        if (api == null) {
          _error(req, 501, 'not_implemented', 'session history not configured');
          return;
        }
        final q = req.uri.queryParameters;
        final limit = ((int.tryParse(q['limit'] ?? '') ?? 50).clamp(
          1,
          200,
        )).toInt();
        final offset = ((int.tryParse(q['offset'] ?? '') ?? 0).clamp(
          0,
          200,
        )).toInt();
        final messages = await api(id, limit: limit, offset: offset);
        _json(req, {
          'session_id': id,
          'messages': messages,
          'limit': limit,
          'offset': offset,
        });
      } else if (path.startsWith('/v1/sessions/') && req.method == 'DELETE') {
        final id = Uri.decodeComponent(path.substring('/v1/sessions/'.length));
        if (id.isEmpty ||
            id.contains('/') ||
            id.contains('\\') ||
            id.contains('..')) {
          _error(req, 400, 'invalid_request', 'invalid session id');
        } else {
          final ok = await (deleteSession?.call(id) ?? Future.value(false));
          _json(req, {'deleted': ok});
        }
      } else if (path.startsWith('/v1/sessions/') && req.method == 'PATCH') {
        final id = Uri.decodeComponent(path.substring('/v1/sessions/'.length));
        if (id.isEmpty ||
            id.contains('/') ||
            id.contains('\\') ||
            id.contains('..')) {
          _error(req, 400, 'invalid_request', 'invalid session id');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final title = body['title'] as String? ?? '';
        final ok =
            await (renameSession?.call(id, title) ?? Future.value(false));
        if (!ok) {
          _error(
            req,
            404,
            'not_found',
            'session not found or rename unsupported',
          );
        } else {
          _json(req, {'ok': true, 'id': id, 'title': title});
        }
      } else if (path == '/v1/doctor' && req.method == 'GET') {
        final d =
            await (doctorProvider?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'checks': d});
      } else if (path == '/v1/capabilities' && req.method == 'GET') {
        _json(req, capabilitiesProvider?.call() ?? {'ok': true});
      } else if (path == '/v1/events' && req.method == 'GET') {
        _json(req, {'events': eventsProvider?.call() ?? []});
      } else if (path == '/v1/tasks' && req.method == 'GET') {
        final tasks =
            await (tasksProvider?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'tasks': tasks});
      } else if (path == '/v1/logs' && req.method == 'GET') {
        final logs =
            await (logsProvider?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'logs': logs});
      } else if (path.startsWith('/v1/logs/') && req.method == 'GET') {
        final name = Uri.decodeComponent(path.substring('/v1/logs/'.length));
        if (name.isEmpty ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains('..')) {
          _error(req, 400, 'invalid_request', 'invalid log name');
        } else {
          final content =
              await (logContentProvider?.call(name) ??
                  Future<Map<String, dynamic>?>.value(null));
          if (content == null) {
            _error(req, 404, 'not_found', 'log not found');
          } else {
            _json(req, content);
          }
        }
      } else if (path == '/v1/approvals' && req.method == 'GET') {
        final list =
            await (listApprovals?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'approvals': list});
      } else if (path.startsWith('/v1/approvals/') && req.method == 'POST') {
        final id = path.substring('/v1/approvals/'.length).split('/').first;
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final allow = body['approve'] == true || path.endsWith('/approve');
        final actor =
            _sanitizeActor(body['actor'] as String?) ??
            _sanitizeActor(req.headers.value('x-tiko-actor'));
        final ok =
            await (decideApproval?.call(id, allow, actor: actor) ??
                Future.value(false));
        _json(req, {'ok': ok, 'id': id, 'approve': allow});
      } else if (path == '/v1/messages' && req.method == 'POST') {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final text = body['text'] as String? ?? '';
        final sessionKey = body['session_key'] as String? ?? 'http:default';
        final userKey = body['user_key'] as String? ?? 'http';
        final idempotencyKey = req.headers.value('idempotency-key') ?? '';
        List<Attachment> attachments;
        try {
          attachments = _parseAttachments(body['attachments']);
        } on ApiRequestException catch (e) {
          _error(req, e.status, e.code, e.message);
          return;
        }
        final wantStream = body['stream'] == true ||
            (req.headers.value(HttpHeaders.acceptHeader) ?? '')
                .contains('text/event-stream');
        if (wantStream &&
            idempotencyKey.trim().isEmpty &&
            onMessageWithProgress != null) {
          await _streamMessagesSse(
            req,
            InboundMessage(
              channel: 'http',
              userKey: userKey,
              sessionKey: sessionKey,
              text: text,
              attachments: attachments,
            ),
          );
          return;
        }
        if (idempotencyKey.trim().isEmpty) {
          final answer = await onMessage(
            InboundMessage(
              channel: 'http',
              userKey: userKey,
              sessionKey: sessionKey,
              text: text,
              attachments: attachments,
            ),
          );
          _json(req, {'text': answer});
        } else {
          final replayed = _idempotencyCache.containsKey(idempotencyKey);
          final result = await _runIdempotent(idempotencyKey, () async {
            final answer = await onMessage(
              InboundMessage(
                channel: 'http',
                userKey: userKey,
                sessionKey: sessionKey,
                text: text,
                attachments: attachments,
              ),
            );
            return {'text': answer};
          });
          if (replayed) {
            req.response.headers.set('Idempotency-Replayed', 'true');
          }
          final payload = Map<String, dynamic>.from(result);
          if (replayed) {
            payload['idempotent_replay'] = true;
          }
          _json(req, payload);
        }
      } else if (path == '/v1/chat/completions' && req.method == 'POST') {
        // OpenAI-compat endpoint (Hermes-parity P4): expose agent sebagai
        // /v1/chat/completions agar Open WebUI/LibreChat/dll. dapat memakai
        // Tiko. Auth + Host allowlist + bind loopback sama dengan /v1 lain.
        Map<String, dynamic> body;
        try {
          final decoded = jsonDecode(await utf8.decoder.bind(req).join());
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('body harus JSON object');
          }
          body = decoded;
        } on FormatException catch (e) {
          _openaiError(req, 400, 'invalid_request_error', '$e');
          return;
        } catch (e) {
          _openaiError(req, 400, 'invalid_request_error', 'body JSON tidak valid: $e');
          return;
        }
        final messages = body['messages'];
        if (messages is! List || messages.isEmpty) {
          _openaiError(req, 400, 'invalid_request_error',
              'messages wajib array non-kosong');
          return;
        }
        if (messages.length > 100) {
          _openaiError(req, 400, 'invalid_request_error',
              'maksimum 100 per pesan');
          return;
        }
        final prompt = _openaiPrompt(messages);
        if (prompt == null) {
          _openaiError(req, 400, 'invalid_request_error',
              'format messages tidak valid: butuh minimal satu pesan user bercontent teks; role tool/function tidak didukung');
          return;
        }
        if (prompt.length > 400000) {
          _openaiError(req, 400, 'invalid_request_error',
              'prompt terlalu besar: maksimum 400.000 karakter setelah komposisi');
          return;
        }
        final model = (body['model'] as String?)?.trim();
        final sessionKey =
            (body['session_key'] as String?)?.trim().isNotEmpty ?? false
                ? (body['session_key'] as String).trim()
                : 'openai:default';
        final userKey = (body['user_key'] as String?)?.trim().isNotEmpty ?? false
            ? (body['user_key'] as String).trim()
            : 'openai';
        final stream = body['stream'] == true;
        final id = 'chatcmpl-${_openaiId()}';
        final String answer;
        try {
          answer = await onMessage(InboundMessage(
            channel: 'http',
            userKey: userKey,
            sessionKey: sessionKey,
            text: prompt,
            meta: {
              'source': 'openai_compat',
              if (model != null && model.isNotEmpty) 'requested_model': model,
            },
          ));
        } on ApiRequestException catch (e) {
          _openaiError(req, e.status, 'invalid_request_error', e.message);
          return;
        } catch (e) {
          _openaiError(req, 500, 'server_error', '$e');
          return;
        }
        final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final usedModel =
            (model == null || model.isEmpty) ? 'tiko-agent' : model;
        if (stream) {
          req.response.headers.contentType =
              ContentType.parse('text/event-stream');
          req.response.headers.set('Cache-Control', 'no-cache');
          req.response.headers.set('Connection', 'keep-alive');
          void chunk(Map<String, dynamic> payload) {
            req.response.write('data: ${jsonEncode(payload)}\n\n');
          }

          chunk({
            'id': id,
            'object': 'chat.completion.chunk',
            'created': created,
            'model': usedModel,
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': answer},
                'finish_reason': null,
              },
            ],
          });
          chunk({
            'id': id,
            'object': 'chat.completion.chunk',
            'created': created,
            'model': usedModel,
            'choices': [
              {
                'index': 0,
                'delta': {},
                'finish_reason': 'stop',
              },
            ],
          });
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
        } else {
          final promptTokens = (prompt.length / 4).ceil();
          final completionTokens = (answer.length / 4).ceil();
          _json(req, {
            'id': id,
            'object': 'chat.completion',
            'created': created,
            'model': usedModel,
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': answer},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': promptTokens,
              'completion_tokens': completionTokens,
              'total_tokens': promptTokens + completionTokens,
            },
          });
        }
      } else if (path == '/v1/shutdown' && req.method == 'POST') {
        if (onShutdown == null) {
          _error(req, 409, 'conflict', 'shutdown is unavailable');
        } else {
          // Flush the acknowledgement before signaling agentd to close its
          // HttpServer; otherwise the response can be cut off during teardown.
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ok': true}));
          await req.response.close();
          await onShutdown!.call();
        }
      } else if (path == '/v1/ui/actions' && req.method == 'POST') {
        final handler = uiActionHandler;
        if (handler == null) {
          _error(req, 501, 'not_implemented', 'ui actions not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final sessionKey = body['session_key'] as String? ?? '';
        final actionId = body['action_id'] as String? ?? '';
        final rawValues = body['values'];
        final values = rawValues is Map
            ? rawValues.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final surfaceIdRaw = body['surface_id'];
        final surfaceId = surfaceIdRaw is String ? surfaceIdRaw : null;
        if (sessionKey.isEmpty ||
            sessionKey.length > 128 ||
            !_safeActionId.hasMatch(actionId) ||
            (surfaceId != null && !_safeActionId.hasMatch(surfaceId))) {
          _error(req, 400, 'invalid_request', 'invalid ui action request');
          return;
        }
        try {
          final result =
              await handler(sessionKey, actionId, values, surfaceId: surfaceId);
          _json(req, result);
        } on GenUiActionRejected catch (e) {
          _error(req, 400, 'invalid_request', e.message);
        }
      } else if (path == '/v1/surfaces' && req.method == 'GET') {
        final provider = surfacesProvider;
        if (provider == null) {
          _error(req, 501, 'not_implemented', 'a2ui surfaces not configured');
          return;
        }
        final sessionParam = req.uri.queryParameters['session_key'];
        _json(req, {'surfaces': await provider(sessionParam)});
      } else if (path == '/v1/surfaces' && req.method == 'POST') {
        final creator = surfaceCreator;
        if (creator == null) {
          _error(req, 501, 'not_implemented', 'a2ui surfaces not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final doc = await creator(body);
        req.response.statusCode = doc['exists'] == true ? 200 : 201;
        _json(req, doc);
      } else if (path == '/v1/surfaces/catalogs' && req.method == 'GET') {
        _json(req, {
          'version': a2uiVersion,
          'catalogs': [
            for (final id in a2uiAllowedCatalogIds)
              {
                'catalogId': id,
                'components': a2uiAllowedComponents.toList()..sort(),
              },
          ],
        });
      } else if (path.startsWith('/v1/surfaces/') &&
          req.method == 'GET' &&
          !path.contains('/catalogs')) {
        final id =
            Uri.decodeComponent(path.substring('/v1/surfaces/'.length));
        final getter = surfaceGetter;
        if (getter == null) {
          _error(req, 501, 'not_implemented', 'a2ui surfaces not configured');
          return;
        }
        if (!_safeActionId.hasMatch(id)) {
          _error(req, 400, 'invalid_request', 'invalid surface id');
          return;
        }
        final doc = await getter(id);
        if (doc == null) {
          _error(req, 404, 'not_found', 'surface "$id" tidak ditemukan');
          return;
        }
        _json(req, doc);
      } else if (path.startsWith('/v1/surfaces/') &&
          req.method == 'DELETE') {
        final id =
            Uri.decodeComponent(path.substring('/v1/surfaces/'.length));
        final deleter = surfaceDeleter;
        if (deleter == null) {
          _error(req, 501, 'not_implemented', 'a2ui surfaces not configured');
          return;
        }
        if (!_safeActionId.hasMatch(id)) {
          _error(req, 400, 'invalid_request', 'invalid surface id');
          return;
        }
        final ok = await deleter(id);
        if (!ok) {
          _error(req, 404, 'not_found', 'surface "$id" tidak ditemukan');
          return;
        }
        _json(req, {'ok': true, 'id': id});
      } else if (path == '/v1/confirm' && req.method == 'POST') {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final id = body['id'] as String? ?? '';
        final allow = body['allow'] == true;
        final actor =
            _sanitizeActor(body['actor'] as String?) ??
            _sanitizeActor(req.headers.value('x-tiko-actor'));
        final ok =
            id.isNotEmpty &&
            await (decideApproval?.call(id, allow, actor: actor) ??
                Future.value(false));
        _json(req, {'ok': ok, 'id': id, 'approve': allow});
      } else if (path == '/v1/memories' && req.method == 'GET') {
        final mems =
            await (listMemories?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'memories': mems});
      } else if (path.startsWith('/v1/memories/') && req.method == 'DELETE') {
        final id = path.substring('/v1/memories/'.length);
        final ok = await (deleteMemory?.call(id) ?? Future.value(false));
        _json(req, {'deleted': ok});
        // Skill management endpoints (P1-03)
      } else if (path == '/v1/skills' && req.method == 'GET') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final result = await api.listSkills(req);
          _json(req, result);
        }
      } else if (path.startsWith('/v1/skills/') && req.method == 'GET') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final slug = path.substring('/v1/skills/'.length).split('/').first;
          if (path == '/v1/skills/$slug') {
            final result = await api.getSkill(req, slug);
            _json(req, result);
          } else if (path == '/v1/skills/$slug/history') {
            final result = await api.getSkillHistory(req, slug);
            _json(req, result);
          } else if (path == '/v1/skills/$slug/metrics') {
            final result = await api.getSkillMetrics(req, slug);
            _json(req, result);
          } else {
            req.response.statusCode = 404;
            _json(req, {'error': 'not found'});
          }
        }
      } else if (path.startsWith('/v1/skills/') && req.method == 'POST') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final slug = path.substring('/v1/skills/'.length).split('/').first;
          final rest = path.substring('/v1/skills/$slug'.length);
          if (rest == '/feedback') {
            final result = await api.recordFeedback(req, slug);
            _json(req, result);
          } else if (rest == '/evaluate') {
            final result = await api.evaluateSkill(req, slug);
            _json(req, result);
          } else if (rest == '/approve') {
            final result = await api.approveSkill(req, slug);
            _json(req, result);
          } else if (rest == '/rollback') {
            final result = await api.rollbackSkill(req, slug);
            _json(req, result);
          } else {
            req.response.statusCode = 404;
            _json(req, {'error': 'not found'});
          }
        }
      } else if (path.startsWith('/v1/sessions/') &&
          req.method == 'POST' &&
          path.endsWith('/feedback')) {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final sessionId = path
              .substring(
                '/v1/sessions/'.length,
                path.length - '/feedback'.length,
              )
              .trim();
          if (sessionId.isEmpty || sessionId.contains('/')) {
            req.response.statusCode = 400;
            _json(req, {'error': 'invalid session id'});
          } else {
            final result = await api.recordSessionFeedback(req, sessionId);
            _json(req, result);
          }
        }
        // Bot manager endpoints (GUI-P1-04)
      } else if (path == '/v1/bots' && req.method == 'GET') {
        final bots =
            await (listBots?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot manager not configured',
                )));
        _json(req, {'bots': bots});
      } else if (path == '/v1/bots' && req.method == 'POST') {
        if (createBot == null) {
          _error(req, 501, 'not_implemented', 'bot manager not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateBotPayload(body, forCreate: true);
        final profile = await createBot!(body);
        req.response.statusCode = 201;
        _json(req, profile);
      } else if (path == '/v1/bots/bindings' && req.method == 'GET') {
        final bindings =
            await (listBotBindings?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot manager not configured',
                )));
        _json(req, {'bindings': bindings});
      } else if (path.startsWith('/v1/bots/') &&
          req.method == 'GET' &&
          !path.endsWith('/bind') &&
          !path.endsWith('/unbind')) {
        final id = path.substring('/v1/bots/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid bot id');
          return;
        }
        final profile =
            await (getBot?.call(id) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot manager not configured',
                )));
        if (profile == null) {
          _error(req, 404, 'not_found', 'bot not found');
        } else {
          _json(req, profile);
        }
      } else if (path.startsWith('/v1/bots/') && req.method == 'PATCH') {
        if (updateBot == null) {
          _error(req, 501, 'not_implemented', 'bot manager not configured');
          return;
        }
        final id = path.substring('/v1/bots/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid bot id');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateBotPayload(body, forCreate: false);
        final updated = await updateBot!(id, body);
        if (updated == null) {
          _error(req, 404, 'not_found', 'bot not found');
        } else {
          _json(req, updated);
        }
      } else if (path.startsWith('/v1/bots/') && req.method == 'DELETE') {
        if (deleteBot == null) {
          _error(req, 501, 'not_implemented', 'bot manager not configured');
          return;
        }
        final id = path.substring('/v1/bots/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid bot id');
          return;
        }
        final ok = await deleteBot!(id);
        if (!ok) {
          _error(req, 404, 'not_found', 'bot not found');
        } else {
          _json(req, {'deleted': true});
        }
      } else if (path.startsWith('/v1/bots/') &&
          req.method == 'POST' &&
          (path.endsWith('/bind') || path.endsWith('/unbind'))) {
        final bind = path.endsWith('/bind');
        final id = path.substring(
          '/v1/bots/'.length,
          path.length - (bind ? '/bind'.length : '/unbind'.length),
        );
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid bot id');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final sessionId = body['session_id'];
        if (sessionId is! String || sessionId.trim().isEmpty) {
          _error(req, 400, 'invalid_request', 'session_id wajib diisi');
          return;
        }
        final ok = bind
            ? await (bindBot?.call(id, sessionId.trim()) ??
                  (throw ApiRequestException(
                    501,
                    'not_implemented',
                    'bot manager not configured',
                  )))
            : await (unbindBot?.call(id, sessionId.trim()) ??
                  (throw ApiRequestException(
                    501,
                    'not_implemented',
                    'bot manager not configured',
                  )));
        if (!ok) {
          _error(req, 404, 'not_found', 'bot or binding not found');
        } else {
          _json(req, {'ok': true, 'bound': bind});
        }
        // Fase C — bot team endpoints
      } else if (path == '/v1/teams' && req.method == 'GET') {
        final teams =
            await (teamsProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot team manager not configured',
                )));
        _json(req, {'teams': teams});
      } else if (path == '/v1/teams' && req.method == 'POST') {
        if (createTeam == null) {
          _error(req, 501, 'not_implemented', 'bot team manager not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateTeamPayload(body, forCreate: true);
        final doc = await createTeam!(body);
        req.response.statusCode = 201;
        _json(req, doc);
      } else if (path == '/v1/teams/runs' && req.method == 'GET') {
        final runs =
            await (teamRunsProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot team manager not configured',
                )));
        _json(req, {'runs': runs});
      } else if (path == '/v1/teams/run' && req.method == 'POST') {
        if (teamRunStarter == null) {
          _error(req, 501, 'not_implemented', 'bot team manager not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final goal = (body['goal'] as String?)?.trim() ?? '';
        if (goal.isEmpty) {
          _error(req, 400, 'invalid_request', 'goal wajib diisi');
          return;
        }
        final concurrencyRaw = body['max_concurrency'];
        if (concurrencyRaw != null &&
            (concurrencyRaw is! int || concurrencyRaw < 1 || concurrencyRaw > 8)) {
          _error(req, 400, 'invalid_request', 'max_concurrency harus 1..8');
          return;
        }
        _json(req, await teamRunStarter!(body));
      } else if (path.startsWith('/v1/teams/') && req.method == 'GET') {
        final id = path.substring('/v1/teams/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid team id');
          return;
        }
        final doc =
            await (getTeam?.call(id) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'bot team manager not configured',
                )));
        if (doc == null) {
          _error(req, 404, 'not_found', 'team not found');
        } else {
          _json(req, doc);
        }
      } else if (path.startsWith('/v1/teams/') &&
          (req.method == 'PUT' || req.method == 'PATCH')) {
        if (updateTeam == null) {
          _error(req, 501, 'not_implemented', 'bot team manager not configured');
          return;
        }
        final id = path.substring('/v1/teams/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid team id');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateTeamPayload(body, forCreate: false);
        final updated = await updateTeam!(id, body);
        if (updated == null) {
          _error(req, 404, 'not_found', 'team not found');
        } else {
          _json(req, updated);
        }
      } else if (path.startsWith('/v1/teams/') && req.method == 'DELETE') {
        if (deleteTeam == null) {
          _error(req, 501, 'not_implemented', 'bot team manager not configured');
          return;
        }
        final id = path.substring('/v1/teams/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid team id');
          return;
        }
        final ok = await deleteTeam!(id);
        if (!ok) {
          _error(req, 404, 'not_found', 'team not found');
        } else {
          _json(req, {'ok': true, 'id': id, 'deleted': true});
        }
        // Provider & model manager endpoints (GUI-P1-05)
      } else if (path == '/v1/providers' && req.method == 'GET') {
        final snapshot =
            await (providersProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'provider manager not configured',
                )));
        _json(req, snapshot);
      } else if (req.method == 'GET' &&
          path.startsWith('/v1/providers/') &&
          path.endsWith('/models')) {
        final providerId = path.substring(
          '/v1/providers/'.length,
          path.length - '/models'.length,
        );
        if (providerId.isEmpty || providerId.contains('/')) {
          _error(req, 404, 'not_found', 'endpoint tidak ditemukan');
          return;
        }
        if (providerModels == null) {
          _error(
            req,
            501,
            'not_implemented',
            'provider manager not configured',
          );
          return;
        }
        try {
          _json(req, await providerModels!(providerId));
        } on StateError catch (e) {
          _error(req, 404, 'not_found', '${e.message}');
        }
      } else if (path == '/v1/providers/session' && req.method == 'POST') {
        if (sessionProviderSetter == null) {
          _error(
            req,
            501,
            'not_implemented',
            'provider manager not configured',
          );
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final sessionId = body['session_id'];
        final provider = body['provider'];
        final model = body['model'];
        if (model != null && model is! String) {
          _error(req, 400, 'invalid_request', 'model harus berupa string');
          return;
        }
        if (sessionId is! String || sessionId.trim().isEmpty) {
          _error(req, 400, 'invalid_request', 'session_id wajib diisi');
          return;
        }
        if (provider is! String || provider.trim().isEmpty) {
          _error(
            req,
            400,
            'invalid_request',
            'provider wajib diisi (id atau "default")',
          );
          return;
        }
        final modelArg = (model as String?)?.trim();
        final ok = await sessionProviderSetter!(
          sessionId.trim(),
          provider.trim(),
          (modelArg == null || modelArg.isEmpty) ? null : modelArg,
        );
        if (!ok) {
          _error(req, 404, 'not_found', 'provider not found');
        } else {
          _json(req, {
            'ok': true,
            'session_id': sessionId.trim(),
            'provider': provider.trim(),
            if (model is String && model.trim().isNotEmpty)
              'model': model.trim(),
          });
        }
        // Plugin & tools manager endpoints (GUI-P1-06)
      } else if (path == '/v1/plugins' && req.method == 'GET') {
        final snapshot =
            await (pluginProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'plugin manager not configured',
                )));
        _json(req, snapshot);
      } else if (path == '/v1/plugins/consent' && req.method == 'POST') {
        if (pluginConsentSetter == null) {
          _error(req, 501, 'not_implemented', 'plugin manager not configured');
          return;
        }
        final body = _validatePluginConsentPayload(
          jsonDecode(await utf8.decoder.bind(req).join()),
        );
        final result = await pluginConsentSetter!(
          body['plugin'] as String,
          body['action'] as String,
        );
        if (result['ok'] != true) {
          _error(
            req,
            404,
            'not_found',
            '${result['message'] ?? 'plugin not found'}',
          );
        } else {
          _json(req, {'ok': true, 'message': '${result['message'] ?? ''}'});
        }
      } else if (path == '/v1/hooks' && req.method == 'GET') {
        final snapshot =
            await (hooksSnapshotProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'hooks manager not configured',
                )));
        _json(req, snapshot);
      } else if (path == '/v1/hooks' && req.method == 'POST') {
        if (hookAddProvider == null) {
          _error(req, 501, 'not_implemented', 'hooks manager not configured');
          return;
        }
        final rule = _validateHookRulePayload(
          jsonDecode(await utf8.decoder.bind(req).join()),
        );
        final result = await hookAddProvider!(rule);
        _json(req, {'ok': true, ...result});
      } else if (path == '/v1/hooks/test' && req.method == 'POST') {
        if (hookTestProvider == null) {
          _error(req, 501, 'not_implemented', 'hooks manager not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join()) as Map? ??
                const {};
        final rawIndex = body['index'];
        if (rawIndex is! int) {
          _error(req, 400, 'invalid_request', 'index wajib integer');
          return;
        }
        final result = await hookTestProvider!(rawIndex);
        _json(req, {'ok': true, ...result});
      } else if (_hookIndexRe.hasMatch(path) && req.method == 'PATCH') {
        if (hookUpdateProvider == null) {
          _error(req, 501, 'not_implemented', 'hooks manager not configured');
          return;
        }
        final index = _parseHookIndex(path);
        final rule = _validateHookRulePayload(
          jsonDecode(await utf8.decoder.bind(req).join()),
        );
        final result = await hookUpdateProvider!(index, rule);
        _json(req, {'ok': true, ...result});
      } else if (_hookIndexRe.hasMatch(path) && req.method == 'DELETE') {
        if (hookDeleteProvider == null) {
          _error(req, 501, 'not_implemented', 'hooks manager not configured');
          return;
        }
        final index = _parseHookIndex(path);
        final result = await hookDeleteProvider!(index);
        _json(req, {'ok': true, ...result});
      } else if (path == '/v1/channels' && req.method == 'GET') {
        final snapshot =
            await (channelsProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'channels status not configured',
                )));
        _json(req, snapshot);
        // Security Center endpoint (GUI-P1-10, read-only)
      } else if (path == '/v1/security' && req.method == 'GET') {
        final snapshot =
            await (securityProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'security center not configured',
                )));
        _json(req, snapshot);
        // Audit query browser endpoint (GUI-P1-11, read-only; filter via
        // query string tool/session/risk/verdict/taint/since/until/limit/offset)
      } else if (path == '/v1/audit' && req.method == 'GET') {
        final result =
            await (auditQueryProvider?.call(
                  _parseAuditQuery(req.uri.queryParameters),
                ) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'audit query not configured',
                )));
        _json(req, result);
        // Artifacts browser endpoints (GUI-P2-04, read-only; path/divalidasi
        // PathSafety di runtime — fail-closed untuk path di luar workspace)
      } else if (path == '/v1/artifacts' && req.method == 'GET') {
        final dir = _parseArtifactsPath(
          req.uri.queryParameters['dir'],
          allowEmpty: true,
          field: 'dir',
        );
        final result =
            await (artifactsListProvider?.call(dir) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'artifacts not configured',
                )));
        _json(req, result);
      } else if (path == '/v1/artifacts/read' && req.method == 'GET') {
        final filePath = _parseArtifactsPath(
          req.uri.queryParameters['path'],
          field: 'path',
        );
        final result =
            await (artifactsReadProvider?.call(filePath) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'artifacts not configured',
                )));
        _json(req, result);
      } else if (path == '/v1/artifacts/diff' && req.method == 'GET') {
        final filePath = _parseArtifactsPath(
          req.uri.queryParameters['path'],
          field: 'path',
        );
        final result =
            await (artifactsDiffProvider?.call(filePath) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'artifacts not configured',
                )));
        _json(req, result);
        // Run-inspector endpoint (GUI-P2-04, read-only): live + recent turns.
      } else if (path == '/v1/runs' && req.method == 'GET') {
        final result =
            await (runsProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'run inspector not configured',
                )));
        _json(req, result);
        // Memory Explorer endpoints (GUI-P1-12): kurasi, lapisan, RAG.
      } else if (path == '/v1/memory/curated' && req.method == 'GET') {
        final result =
            await (memoryCuratedProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        _json(req, result);
      } else if (path == '/v1/memory/curated' && req.method == 'PATCH') {
        final body = _validateMemoryCuratedPatch(
          jsonDecode(await utf8.decoder.bind(req).join()),
        );
        final result =
            await (memoryCuratedSetProvider?.call(body) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        _json(req, result);
      } else if (path == '/v1/memory/layers' && req.method == 'GET') {
        final result =
            await (memoryLayersProvider?.call(
                  _parseMemoryLayersQuery(req.uri.queryParameters),
                ) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        _json(req, result);
      } else if (path == '/v1/memory/layers' && req.method == 'POST') {
        final body = _validateMemoryLayerPayload(
          jsonDecode(await utf8.decoder.bind(req).join()),
        );
        final result =
            await (memoryLayerAddProvider?.call(body) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        req.response.statusCode = 201;
        _json(req, result);
      } else if (path.startsWith('/v1/memory/layers/') &&
          req.method == 'DELETE') {
        final id = Uri.decodeComponent(
          path.substring('/v1/memory/layers/'.length),
        );
        if (id.isEmpty) {
          _error(req, 400, 'invalid_request', 'id wajib diisi');
          return;
        }
        final ok =
            await (memoryLayerDeleteProvider?.call(id) ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        if (!ok) {
          _error(req, 404, 'not_found', 'entri berlapis tidak ditemukan: $id');
          return;
        }
        _json(req, {'ok': true, 'id': id});
      } else if (path == '/v1/memory/rag' && req.method == 'GET') {
        final result =
            await (memoryRagProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'memory explorer not configured',
                )));
        _json(req, result);
        // Automation / cron CRUD endpoints (GUI-P1-09)
      } else if (path == '/v1/research/runs' && req.method == 'GET') {
        final runs = await (researchRunsProvider?.call() ??
            (throw ApiRequestException(
              501,
              'not_implemented',
              'research runner not configured',
            )));
        _json(req, {'runs': runs});
      } else if (path.startsWith('/v1/research/runs/') && req.method == 'GET') {
        final id = path.substring('/v1/research/runs/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid run id');
          return;
        }
        final entry = await (researchRunGetter?.call(id) ??
            (throw ApiRequestException(
              501,
              'not_implemented',
              'research runner not configured',
            )));
        if (entry == null) {
          _error(req, 404, 'not_found', 'run not found');
        } else {
          _json(req, entry);
        }
      } else if (path == '/v1/research/run' && req.method == 'POST') {
        if (researchStarter == null) {
          _error(req, 501, 'not_implemented', 'research runner not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final question = (body['question'] as String?)?.trim() ?? '';
        if (question.isEmpty) {
          _error(req, 400, 'invalid_request', 'question wajib diisi');
          return;
        }
        final concurrencyRaw = body['max_concurrency'];
        if (concurrencyRaw != null &&
            (concurrencyRaw is! int ||
                concurrencyRaw < 1 ||
                concurrencyRaw > 4)) {
          _error(req, 400, 'invalid_request', 'max_concurrency harus 1..4');
          return;
        }
        _json(req, await researchStarter!(body));
      } else if (path == '/v1/jobs' && req.method == 'GET') {
        final jobs =
            await (jobsProvider?.call() ??
                (throw ApiRequestException(
                  501,
                  'not_implemented',
                  'scheduler not configured',
                )));
        _json(req, {'jobs': jobs});
      } else if (path == '/v1/jobs' && req.method == 'POST') {
        if (createJob == null) {
          _error(req, 501, 'not_implemented', 'scheduler not configured');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateJobPayload(body, forCreate: true);
        final job = await createJob!(body);
        req.response.statusCode = 201;
        _json(req, job);
      } else if (path.startsWith('/v1/jobs/') && req.method == 'PATCH') {
        if (updateJob == null) {
          _error(req, 501, 'not_implemented', 'scheduler not configured');
          return;
        }
        final id = path.substring('/v1/jobs/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid job id');
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        _validateJobPayload(body, forCreate: false);
        final updated = await updateJob!(id, body);
        if (updated == null) {
          _error(req, 404, 'not_found', 'job not found');
        } else {
          _json(req, updated);
        }
      } else if (path.startsWith('/v1/jobs/') && req.method == 'DELETE') {
        if (deleteJob == null) {
          _error(req, 501, 'not_implemented', 'scheduler not configured');
          return;
        }
        final id = path.substring('/v1/jobs/'.length);
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid job id');
          return;
        }
        final ok = await deleteJob!(id);
        if (!ok) {
          _error(req, 404, 'not_found', 'job not found');
        } else {
          _json(req, {'deleted': true});
        }
      } else if (path.startsWith('/v1/jobs/') &&
          req.method == 'POST' &&
          (path.endsWith('/pause') || path.endsWith('/resume'))) {
        if (pauseJob == null) {
          _error(req, 501, 'not_implemented', 'scheduler not configured');
          return;
        }
        final id = path.substring(
          '/v1/jobs/'.length,
          path.length - (path.endsWith('/pause') ? '/pause' : '/resume').length,
        );
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid job id');
          return;
        }
        final job = await pauseJob!(id, path.endsWith('/pause'));
        if (job == null) {
          _error(req, 404, 'not_found', 'job not found');
        } else {
          _json(req, job);
        }
      } else if (path.startsWith('/v1/jobs/') &&
          req.method == 'POST' &&
          path.endsWith('/run')) {
        if (runJobNow == null) {
          _error(req, 501, 'not_implemented', 'scheduler not configured');
          return;
        }
        final id = path.substring(
          '/v1/jobs/'.length,
          path.length - '/run'.length,
        );
        if (id.isEmpty || id.contains('/')) {
          _error(req, 400, 'invalid_request', 'invalid job id');
          return;
        }
        final job = await runJobNow!(id);
        if (job == null) {
          _error(req, 404, 'not_found', 'job not found or busy');
        } else {
          _json(req, job);
        }
      } else if (path == '/v1/smart-home' && req.method == 'GET') {
        if (smartHomeProviders == null) {
          _error(req, 501, 'not_implemented', 'smart-home not configured');
          return;
        }
        _json(req, {'providers': await smartHomeProviders!()});
      } else if (path == '/v1/smart-home/devices' && req.method == 'GET') {
        if (smartHomeDevices == null) {
          _error(req, 501, 'not_implemented', 'smart-home not configured');
          return;
        }
        var provider = req.uri.queryParameters['provider']?.trim();
        if (provider != null && provider.isEmpty) provider = null;
        try {
          _json(req, {'devices': await smartHomeDevices!(provider)});
        } on ApiRequestException {
          rethrow;
        } on ArgumentError catch (e) {
          _error(req, 400, 'invalid_request', '$e');
        } catch (e) {
          _error(req, 502, 'upstream_error', '$e', retryable: true);
        }
      } else if (path.startsWith('/v1/smart-home/devices/') &&
          req.method == 'GET') {
        if (smartHomeDevice == null) {
          _error(req, 501, 'not_implemented', 'smart-home not configured');
          return;
        }
        final parts = path.substring('/v1/smart-home/devices/'.length)
            .split('/');
        if (parts.length != 2 ||
            parts[0].isEmpty ||
            parts[1].isEmpty) {
          _error(req, 400, 'invalid_request',
              'format: /v1/smart-home/devices/{provider}/{device_id}');
          return;
        }
        final provider = Uri.decodeComponent(parts[0]);
        final deviceId = Uri.decodeComponent(parts[1]);
        try {
          final device = await smartHomeDevice!(provider, deviceId);
          if (device == null) {
            _error(req, 404, 'not_found', 'provider tidak dikenal: $provider');
          } else {
            _json(req, device);
          }
        } on ApiRequestException {
          rethrow;
        } on ArgumentError catch (e) {
          _error(req, 400, 'invalid_request', '$e');
        } catch (e) {
          _error(req, 502, 'upstream_error', '$e', retryable: true);
        }
      } else if (path.startsWith('/v1/smart-home/devices/') &&
          req.method == 'POST' &&
          path.endsWith('/execute')) {
        if (smartHomeExecute == null) {
          _error(req, 501, 'not_implemented', 'smart-home not configured');
          return;
        }
        final middle = path.substring(
          '/v1/smart-home/devices/'.length,
          path.length - '/execute'.length,
        );
        final parts = middle.split('/');
        if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
          _error(req, 400, 'invalid_request',
              'format: /v1/smart-home/devices/{provider}/{device_id}/execute');
          return;
        }
        final provider = Uri.decodeComponent(parts[0]);
        final deviceId = Uri.decodeComponent(parts[1]);
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        if (body is! Map || body.isEmpty) {
          _error(req, 400, 'invalid_request', 'command wajib objek non-kosong');
          return;
        }
        final command = <String, dynamic>{
          for (final e in body.entries) e.key.toString(): e.value,
        };
        try {
          _json(
            req,
            await smartHomeExecute!(provider, deviceId, command),
          );
        } on ApiRequestException {
          rethrow;
        } on ArgumentError catch (e) {
          _error(req, 400, 'invalid_request', '$e');
        } catch (e) {
          _error(req, 502, 'upstream_error', '$e', retryable: true);
        }
      } else {
        _error(req, 404, 'not_found', 'not found');
      }
    } on ApiRequestException catch (e) {
      _error(req, e.status, e.code, e.message);
    } catch (e) {
      _error(req, 500, 'server', e.toString(), retryable: true);
    }
  }

  /// Error model typed (GUI-P0-03): setiap error membawa `code` standar
  /// (unauthorized/forbidden/not_found/invalid_request/not_implemented/
  /// conflict/rate_limited/server) dan `retryable`. Kunci `error` dengan pesan
  /// yang sama dipertahankan agar klien lama tetap kompatibel.
  void _error(
    HttpRequest req,
    int status,
    String code,
    String message, {
    bool retryable = false,
  }) {
    req.response.statusCode = status;
    _json(req, {
      'ok': false,
      'code': code,
      'error': message,
      'retryable': retryable,
    });
  }

  /// Static assets serve from [webRoot] as a directory tree hosting the
  /// compiled Flutter Web client (main.dart.js, assets/, canvaskit/,
  /// flutter.js) as the only web UI (Jalur A fase 3: dashboard vanilla
  /// apps/agentd/web dihapus). API namespaces, health, and webhooks stay
  /// excluded; assets remain unauthenticated but protected by the loopback
  /// bind and the Host allowlist above.
  bool _isStatic(String path) {
    return path != '/health' &&
        !path.startsWith('/v1/') &&
        !path.startsWith('/webhooks/');
  }

  static String _staticContentType(String rel) {
    final ext = rel.contains('.') ? rel.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'html':
        return 'text/html; charset=utf-8';
      case 'js':
      case 'mjs':
        return 'application/javascript; charset=utf-8';
      case 'css':
        return 'text/css; charset=utf-8';
      case 'json':
        return 'application/json; charset=utf-8';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'ico':
        return 'image/x-icon';
      case 'webp':
        return 'image/webp';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'ttf':
        return 'font/ttf';
      case 'wasm':
        return 'application/wasm';
      case 'txt':
        return 'text/plain; charset=utf-8';
      case 'map':
        return 'application/json; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _serveStatic(HttpRequest req, String path) async {
    final root = webRoot;
    if (root == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final rel = path == '/' ? 'index.html' : path.substring(1);
    final List<String> segments;
    try {
      segments = rel
          .split('/')
          .map(Uri.decodeComponent)
          .toList();
    } on FormatException {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final file = File(
      p.joinAll([root, ...segments]),
    );
    if (!await file.exists()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.headers.contentType =
        ContentType.parse(_staticContentType(rel));
    req.response.headers.set('X-Content-Type-Options', 'nosniff');
    req.response.headers.set('Cache-Control', 'no-cache');
    if (rel == 'index.html') {
      req.response.headers.set(
        HttpHeaders.setCookieHeader,
        '$_uiCookieName=$_uiSecret; HttpOnly; SameSite=Strict; '
            'Path=/; Max-Age=$_uiCookieMaxAge',
      );
    }
    await req.response.addStream(file.openRead());
    await req.response.close();
  }

  void _json(HttpRequest req, Object data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  void broadcast(Map<String, dynamic> event) {
    final eventWithMetadata = <String, dynamic>{
      'event_id': ++_wsEventCounter,
      'schema_version': _wsSchemaVersion,
      ...event,
    };
    final payload = jsonEncode(eventWithMetadata);
    for (final ws in _wsClients) {
      ws.add(payload);
    }
  }

  /// Send a WebSocket event to a single connection with metadata (P2-6).
  void _sendWsEvent(WebSocket ws, Map<String, dynamic> event) {
    final eventWithMetadata = <String, dynamic>{
      'event_id': ++_wsEventCounter,
      'schema_version': _wsSchemaVersion,
      ...event,
    };
    ws.add(jsonEncode(eventWithMetadata));
  }

  /// Hermes-P5: progress live untuk POST `/v1/messages` via Server-Sent
  /// Events. Frame `chat.status`/`chat.toolStart`/`chat.tool`/`chat.delta`
  /// sama dengan jalur WS `/v1/stream`, lalu frame `text` (jawaban final)
  /// dan `done`. Klien tanpa stream tetap memakai jalur JSON sinkron.
  /// Jalur ini tidak memakai idempotency-key (respons streaming tidak dapat
  /// direplay dari cache). Pembatalan turn tetap via WS `{type: cancel}`.
  Future<void> _streamMessagesSse(
    HttpRequest req,
    InboundMessage m,
  ) async {
    final res = req.response;
    res.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream');
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    res.headers.set('X-Accel-Buffering', 'no');
    // dart:io: saat flush() masih berjalan sink "bound to a stream" — tulis
    // berikutnya yang dipanggil sinkron (typedef progress `void Function`)
    // akan melempar Bad state. Semua write+flush diantrekan dalam rantai
    // future yang berjalan berurutan; close() menunggu rantai selesai.
    Future<void> writeChain = Future.value();
    void sendFrame(Map<String, dynamic> frame) {
      writeChain = writeChain.then((_) {
        res.write('data: ${jsonEncode(frame)}\n\n');
        return res.flush();
      }).catchError((_) {});
    }

    Future<void> drainFrames() async {
      await writeChain;
    }

    sendFrame({
      'type': 'chat.status',
      'state': 'running',
      'session': m.sessionKey,
    });
    String answer;
    try {
      answer = await onMessageWithProgress!(m, sendFrame);
    } on ApiRequestException catch (e) {
      sendFrame({'type': 'error', 'message': e.message, 'code': e.code});
      await drainFrames();
      await res.close().catchError((_) {});
      return;
    } catch (e) {
      sendFrame({'type': 'error', 'message': e.toString()});
      await drainFrames();
      await res.close().catchError((_) {});
      return;
    }
    sendFrame({'type': 'text', 'text': answer});
    sendFrame({'type': 'done', 'session': m.sessionKey});
    await drainFrames();
    await res.close().catchError((_) {});
  }
}
