import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'text_split.dart';

/// Signal gateway via a [signal-cli](https://github.com/AsamK/signal-cli)
/// JSON-RPC daemon (e.g. `signal-cli daemon --http ...` or `signal-cli-rest-api`).
///
/// Fail-closed: no default localhost URL — the operator must point
/// [rpcUrl] at a trusted daemon explicitly. Only senders in [allowedSenders]
/// (phone numbers or UUIDs) produce inbound messages.
class SignalGateway implements Gateway {
  SignalGateway({
    required this.rpcUrl,
    required this.account,
    required this.allowedSenders,
    this.client,
    this.pollTimeoutSec = 25,
  })  : assert(rpcUrl.startsWith('http://') || rpcUrl.startsWith('https://'),
            'rpcUrl harus http(s)'),
        assert(allowedSenders.isNotEmpty, 'allowedSenders wajib diisi');

  /// Base URL of the signal-cli JSON-RPC daemon.
  final String rpcUrl;
  final String account;
  final Set<String> allowedSenders;
  final http.Client? client;
  final int pollTimeoutSec;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _seenTimestamps = <int>{};
  bool _running = false;
  int _idCounter = 0;

  @override
  String get channel => 'signal';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  http.Client get _client => client ?? http.Client();

  Uri get _endpoint => Uri.parse(rpcUrl);

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params) async {
    _idCounter += 1;
    final res = await _client
        .post(
          _endpoint,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': _idCounter,
            'method': method,
            'params': params,
          }),
        )
        .timeout(Duration(seconds: pollTimeoutSec + 10));
    final map = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (map is! Map<String, dynamic>) {
      throw StateError('signal rpc: respons bukan objek');
    }
    final err = map['error'];
    if (err != null) {
      throw StateError('signal rpc error: ${jsonEncode(err)}');
    }
    return map;
  }

  /// Start the receive-polling loop.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_pollLoop());
  }

  Future<void> stop() async {
    _running = false;
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final map = await _rpc('receive', {
          'account': account,
          'timeout': pollTimeoutSec,
        });
        final result = map['result'];
        if (result is List) {
          for (final envelope in result) {
            if (envelope is Map<String, dynamic>) _handleEnvelope(envelope);
          }
        }
      } catch (_) {
        if (_running) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  void _handleEnvelope(Map<String, dynamic> envelope) {
    final source = envelope['envelope'] is Map
        ? (envelope['envelope'] as Map)['source']?.toString() ?? ''
        : envelope['source']?.toString() ?? '';
    if (source.isEmpty || !allowedSenders.contains(source)) return;
    final dm = (envelope['envelope'] is Map
            ? (envelope['envelope'] as Map)['dataMessage']
            : envelope['dataMessage']) as Map<String, dynamic>?;
    if (dm == null) return;
    final text = dm['message']?.toString() ?? '';
    if (text.trim().isEmpty) return;
    final ts = dm['timestamp'] is int ? dm['timestamp'] as int : 0;
    if (ts != 0 && !_seenTimestamps.add(ts)) return;
    if (_seenTimestamps.length > 4096) _seenTimestamps.clear();
    _inbound.add(InboundMessage(
      channel: channel,
      userKey: source,
      sessionKey: 'signal:$source',
      text: text,
      meta: {'timestamp': dm['timestamp']},
    ));
  }

  String? _recipientFromSession(String sessionKey) {
    if (!sessionKey.startsWith('signal:')) return null;
    final recipient = sessionKey.substring('signal:'.length);
    return recipient.isEmpty ? null : recipient;
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final recipient = _recipientFromSession(m.sessionKey);
    if (recipient == null) {
      throw ArgumentError('sessionKey signal tidak valid: ${m.sessionKey}');
    }
    for (final part in splitMessage(m.text)) {
      await _rpc('send', {
        'account': account,
        'recipient': recipient,
        'message': part,
      });
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    final recipient = _recipientFromSession(sessionKey);
    if (recipient == null) return;
    try {
      await _rpc('sendTyping', {
        'account': account,
        'recipient': recipient,
      });
    } catch (_) {
      // Typing indicator is best-effort.
    }
  }

  @override
  Future<void> close() async {
    _running = false;
    await _inbound.close();
  }
}
