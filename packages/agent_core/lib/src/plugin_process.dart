import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_system.dart';

/// Plugin **out-of-process** (rekomendasi #5): plugin pihak ketiga berjalan
/// sebagai proses OS terpisah dan berkomunikasi lewat stdin/stdout dengan
/// protokol JSON per baris. Isolasi proses OS menjaga host tetap hidup dan
/// memori host tetap terlindungi meski plugin crash atau hang.
///
/// Protokol (satu objek JSON per baris):
/// - host → child: `{"op":"hello","name":...}` saat init; lalu
///   `{"op":"hook","hook":"<nama>","input":...}` per panggilan hook.
/// - child → host: `{"ok":true}` untuk hello; untuk hook:
///   `{"verdict":"allow"}` / `{"verdict":"deny","reason":...}` /
///   `{"verdict":"modify","args":{...}}` (beforeToolCall) atau `{"ok":true}`
///   untuk hook tanpa verdict.
///
/// Containment: setiap panggilan hook dibatasi [hookTimeout]; child yang
/// keluar/crash membuat plugin "dead" — panggilan hook berikutnya melempar
/// [StateError] yang dicatat registry sebagai [PluginEvent] tanpa
/// menggagalkan agent loop.
class ProcessPlugin extends Plugin {
  ProcessPlugin({
    required String name,
    required this.command,
    this.args = const [],
    this.workingDirectory,
    this.hookTimeout = const Duration(seconds: 10),
  }) : _name = name;

  final String _name;
  final String command;
  final List<String> args;
  final String? workingDirectory;
  final Duration hookTimeout;

  Process? _process;
  StreamIterator<String>? _replies;
  IOSink? _stdin;
  bool _dead = false;

  @override
  String get name => _name;

  bool get isAlive => !_dead && _process != null;

  Future<void> _send(Map<String, dynamic> message) async {
    _stdin?.writeln(jsonEncode(message));
    await _stdin?.flush();
  }

  Future<Map<String, dynamic>> _receive() async {
    final it = _replies;
    bool has;
    try {
      has = it != null && await it.moveNext().timeout(hookTimeout);
    } on TimeoutException {
      throw StateError('plugin "$_name" tidak merespons (timeout)');
    }
    if (!has) {
      throw StateError('plugin "$_name" keluar tanpa jawaban');
    }
    return jsonDecode(it.current) as Map<String, dynamic>;
  }

  @override
  Future<void> init() async {
    final process = await Process.start(
      command,
      args,
      workingDirectory: workingDirectory,
    );
    _process = process;
    _stdin = process.stdin;
    _replies = StreamIterator<String>(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    process.stderr.drain<void>().ignore();
    unawaited(
      process.exitCode.then((_) {
        _dead = true;
      }),
    );
    await _send({'op': 'hello', 'name': _name});
    final reply = await _receive();
    if (reply['ok'] != true) {
      throw StateError('handshake plugin "$_name" gagal: $reply');
    }
  }

  @override
  Future<void> dispose() async {
    final process = _process;
    _dead = true;
    _process = null;
    _stdin = null;
    _replies = null;
    if (process != null) {
      process.kill();
      unawaited(process.exitCode);
    }
  }

  void _ensureAlive() {
    if (_dead) {
      throw StateError('plugin "$_name" sudah keluar (crash atau dispose)');
    }
  }

  @override
  Future<HookVerdict> beforeToolCall(ToolHookInput input) async {
    _ensureAlive();
    await _send({
      'op': 'hook',
      'hook': 'beforeToolCall',
      'input': {
        'tool': input.toolName,
        'args': input.args,
        'session': input.sessionId,
      },
    });
    final reply = await _receive();
    switch (reply['verdict']) {
      case 'deny':
        return HookVerdict.deny(
          reason: reply['reason']?.toString() ?? 'ditolak plugin $_name',
        );
      case 'modify':
        final args = reply['args'];
        if (args is Map<String, dynamic>) {
          return HookVerdict.modify(args);
        }
        return const HookVerdict.allow();
      default:
        return const HookVerdict.allow();
    }
  }

  Future<void> _simpleHook(
    String hook, [
    Map<String, dynamic>? payload,
  ]) async {
    _ensureAlive();
    await _send({'op': 'hook', 'hook': hook, if (payload != null) ...payload});
    await _receive();
  }

  @override
  Future<void> afterToolCall(
    ToolHookInput input,
    String result,
    bool isError,
  ) =>
      _simpleHook('afterToolCall', {
        'tool': input.toolName,
        'result': result,
        'is_error': isError,
      });

  @override
  Future<void> onSessionStart(String sessionId) =>
      _simpleHook('onSessionStart', {'session': sessionId});

  @override
  Future<void> onSessionEnd(String sessionId) =>
      _simpleHook('onSessionEnd', {'session': sessionId});

  @override
  Future<void> onMessage(String sessionId, String text,
          {required bool fromUser}) =>
      _simpleHook('onMessage', {
        'session': sessionId,
        'text': text,
        'from_user': fromUser,
      });
}
