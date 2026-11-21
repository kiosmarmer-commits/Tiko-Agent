import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'event_bus.dart';
import 'tiko_config.dart';

/// Hermes-parity event hooks (P1): menjalankan webhook/script pada titik
/// lifecycle runtime berdasarkan config `hooks:` di agent.yaml.
///
/// Keamanan (fail-closed):
/// - Preferensi dibaca dari config operator; runtime tidak pernah
///   mengeksekusi script di luar workspace (path relatif, tanpa `..` —
///   divalidasi ulang saat fire).
/// - Script dipanggil via `sh <script>` dengan env MINIMAL:
///   `TIKO_EVENT`, `TIKO_EVENT_DATA_JSON`, plus `env:` rule — bukan
///   seluruh environment proses.
/// - Timeout 1..120 detik per rule; kegagalan tidak pernah menggagalkan
///   turn chat (fire-and-forget).
/// - Event `hook.*` hasil sendiri tidak pernah memicu hook (anti-loop).
class HookExecutor {
  HookExecutor({
    required this.events,
    required this.rules,
    required this.workspace,
  });

  final EventBus events;
  final List<HookRuleConfig> rules;
  final String workspace;

  StreamSubscription<TikoEvent>? _sub;
  final Map<String, Map<String, dynamic>> _stats = {};

  void start() {
    _sub ??= events.stream.listen(_onEvent);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  Map<String, dynamic> snapshot() {
    final stats = <String, Map<String, dynamic>>{};
    _stats.forEach((key, value) {
      stats[key] = Map<String, dynamic>.from(value);
    });
    return {
      'rules': <Map<String, dynamic>>[for (final r in rules) r.toJson()],
      'stats': stats,
    };
  }

  void _onEvent(TikoEvent ev) {
    if (ev.type.startsWith('hook.')) return;
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      if (rule.event != '*' && rule.event != ev.type) continue;
      unawaited(_fire(i, rule, ev));
    }
  }

  Future<void> _fire(int index, HookRuleConfig rule, TikoEvent ev) async {
    final targets = <String, Future<void> Function()>{
      if (rule.webhookUrl != null)
        'hooks[$index]:webhook': () => _callWebhook(rule, ev),
      if (rule.script != null)
        'hooks[$index]:script': () => _runScript(rule, ev),
    };
    for (final entry in targets.entries) {
      try {
        await entry.value();
        _record(entry.key, ok: true);
        events.emit('hook.executed', {
          'rule': entry.key,
          'trigger': ev.type,
          'outcome': 'ok',
        });
      } catch (error) {
        final message = '$error';
        _record(entry.key, ok: false, error: message);
        events.emit('hook.executed', {
          'rule': entry.key,
          'trigger': ev.type,
          'outcome': 'error',
          'error': message.length > 300
              ? '${message.substring(0, 300)}…'
              : message,
        });
      }
    }
  }

  void _record(String key, {required bool ok, String? error}) {
    final s = _stats.putIfAbsent(key, () => {
          'fires': 0,
          'failures': 0,
          'last_error': null,
          'last_at': null,
        });
    s['fires'] = (s['fires'] as int) + 1;
    if (!ok) {
      s['failures'] = (s['failures'] as int) + 1;
      s['last_error'] = error;
    }
    s['last_at'] = DateTime.now().toUtc().toIso8601String();
  }

  Future<void> _callWebhook(HookRuleConfig rule, TikoEvent ev) async {
    final client = HttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse(rule.webhookUrl!))
          .timeout(Duration(seconds: rule.timeoutSec));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'event': ev.type,
        'at': ev.at.toIso8601String(),
        'data': ev.data,
      }));
      final res = await req.close().timeout(Duration(seconds: rule.timeoutSec));
      await res.drain<void>();
      if (res.statusCode >= 400) {
        throw StateError('webhook merespons ${res.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _runScript(HookRuleConfig rule, TikoEvent ev) async {
    final scriptPath = rule.script!;
    final workspaceAbs = p.normalize(p.absolute(workspace));
    final abs = p.normalize(p.join(workspaceAbs, scriptPath));
    if (!p.isWithin(workspaceAbs, abs)) {
      throw StateError('path hook di luar workspace: $scriptPath');
    }
    final file = File(abs);
    if (!file.existsSync()) {
      throw StateError('script hook tidak ditemukan: $scriptPath');
    }
    final proc = await Process.start(
      'sh',
      [abs],
      workingDirectory: workspaceAbs,
      environment: {
        // PATH ikut supaya `sh` dan tool dasar script dapat di-resolve;
        // variabel lain dari proses daemon TIDAK disuntikkan.
        'PATH': Platform.environment['PATH'] ?? '',
        'TIKO_EVENT': ev.type,
        'TIKO_EVENT_DATA_JSON': jsonEncode(ev.data),
        ...rule.env,
      },
    );
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    int code;
    try {
      code = await proc.exitCode.timeout(Duration(seconds: rule.timeoutSec));
    } on TimeoutException {
      proc.kill();
      throw StateError('hook melebihi timeout ${rule.timeoutSec}s');
    }
    if (code != 0) {
      throw StateError('script hook exit code $code');
    }
  }
}
