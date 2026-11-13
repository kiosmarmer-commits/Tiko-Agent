import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One polled email message.
class ImapEmail {
  const ImapEmail({
    required this.sequence,
    required this.from,
    required this.subject,
    required this.body,
  });

  final int sequence;
  final String from;
  final String subject;
  final String body;
}

/// Byte-accurate transport channel for [ImapPoller]. Production wraps a
/// [SecureSocket]; tests inject a scripted fake. [readLine] returns one
/// CRLF-terminated line; [readLiteral] reads exactly [bytes] raw bytes that
/// follow an IMAP `{n}` literal marker.
abstract class ImapChannel {
  Future<void> writeLine(String line);
  Future<String> readLine();
  Future<String> readLiteral(int bytes);
  void destroy();
}

/// TLS-only IMAP channel (implicit TLS, the standard port 993 transport).
class IoImapChannel implements ImapChannel {
  IoImapChannel._(this._socket, this._responseTimeout);

  final SecureSocket _socket;
  final Duration _responseTimeout;
  final _buffer = <int>[];
  final _waiter = <Completer<void>>[];

  static Future<IoImapChannel> connect(
    String host,
    int port,
    Duration responseTimeout,
  ) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
      onBadCertificate: (_) => false,
    );
    return IoImapChannel._(socket, responseTimeout).._subscribe();
  }

  void _subscribe() {
    _socket.listen(_feed, onDone: () {
      for (final w in _waiter) {
        if (!w.isCompleted) w.complete();
      }
      _waiter.clear();
    });
  }

  void _feed(List<int> data) {
    _buffer.addAll(data);
    for (final w in _waiter) {
      if (!w.isCompleted) w.complete();
    }
    _waiter.clear();
  }

  Future<void> _waitForData() {
    if (_buffer.isNotEmpty) return Future<void>.value();
    final c = Completer<void>();
    _waiter.add(c);
    return c.future.timeout(_responseTimeout, onTimeout: () {
      _waiter.remove(c);
      throw TimeoutException('IMAP response timed out');
    });
  }

  int _findCrlf() {
    for (var i = 0; i + 1 < _buffer.length; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10) return i;
    }
    return -1;
  }

  @override
  Future<void> writeLine(String line) async {
    _socket.add(utf8.encode('$line\r\n'));
    await _socket.flush();
  }

  @override
  Future<String> readLine() async {
    while (_findCrlf() < 0) {
      await _waitForData();
    }
    final end = _findCrlf();
    final line = utf8.decode(_buffer.sublist(0, end), allowMalformed: true);
    _buffer.removeRange(0, end + 2);
    return line;
  }

  @override
  Future<String> readLiteral(int bytes) async {
    while (_buffer.length < bytes) {
      await _waitForData();
    }
    final raw = _buffer.sublist(0, bytes);
    _buffer.removeRange(0, bytes);
    return utf8.decode(raw, allowMalformed: true);
  }

  @override
  void destroy() => _socket.destroy();
}

/// One parsed FETCH response body.
class _FetchedBody {
  const _FetchedBody({required this.headers, required this.body});
  final String headers;
  final String body;
}

/// Minimal IMAP4rev1 poll client for inbound email. Each poll opens a fresh
/// TLS connection, LOGIN, SELECT, SEARCH UNSEEN, FETCH (BODY.PEEK[]), emits
/// allowed senders, then marks messages `\Seen` so nothing is re-emitted.
///
/// Deliberately minimal by design: no MIME multipart tree walking (the raw
/// text part is used as-is after transfer-encoding decode), no IDLE, no
/// partial fetches. TLS is mandatory; plaintext connections are refused.
class ImapPoller {
  ImapPoller({
    required this.host,
    required this.username,
    required this.password,
    this.port = 993,
    this.mailbox = 'INBOX',
    this.allowSenders = const {},
    this.pollInterval = const Duration(seconds: 60),
    this.responseTimeout = const Duration(seconds: 20),
    this.maxMessageBytes = 524288,
    this.maxPerPoll = 10,
    ImapChannel Function()? channelFactory,
    void Function(String detail)? onError,
  })  : assert(maxMessageBytes > 0),
        assert(maxPerPoll > 0),
        _channelFactory = channelFactory,
        _onError = onError;

  final String host;
  final int port;
  final String username;
  final String password;
  final String mailbox;
  final Set<String> allowSenders;
  final Duration pollInterval;
  final Duration responseTimeout;
  final int maxMessageBytes;
  final int maxPerPoll;
  final ImapChannel Function()? _channelFactory;
  final void Function(String detail)? _onError;

  final _emails = StreamController<ImapEmail>.broadcast();
  final _done = Completer<void>();
  bool _running = false;

  /// Emitted for every unseen message from an allowed sender.
  Stream<ImapEmail> get emails => _emails.stream;

  /// Completes when [stop] is called (or never, if the poller runs forever).
  Future<void> get done => _done.future;

  /// Starts the polling loop. Failures of a single poll are reported via
  /// [onError] and never stop the loop.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        await pollOnce();
      } catch (e) {
        _onError?.call('imap poll gagal: $e');
      }
      if (!_running) break;
      await Future<void>.delayed(pollInterval);
    }
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> stop() async {
    _running = false;
    await _done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    await _emails.close();
  }

  /// One full poll cycle. Returns the number of emitted messages.
  Future<int> pollOnce() async {
    final channel = _channelFactory != null
        ? _channelFactory()
        : await IoImapChannel.connect(host, port, responseTimeout);
    var tagN = 0;
    String tag() => 'a${++tagN}';
    var emitted = 0;
    try {
      await _expectOk(channel, tag(), 'LOGIN "$username" "$password"', 'LOGIN');
      await _expectOk(channel, tag(), 'SELECT "$mailbox"', 'SELECT');

      final searchTag = tag();
      await channel.writeLine('$searchTag SEARCH UNSEEN');
      var seqs = <int>[];
      while (true) {
        final line = await channel.readLine();
        if (line.startsWith('$searchTag ')) {
          if (!line.startsWith('$searchTag OK')) {
            throw StateError('IMAP SEARCH failed: $line');
          }
          break;
        }
        final match = RegExp(r'^\* SEARCH (.*)$').firstMatch(line);
        if (match != null) {
          seqs = match
              .group(1)!
              .split(RegExp(r'\s+'))
              .map(int.tryParse)
              .whereType<int>()
              .toList();
        }
      }
      seqs = seqs.take(maxPerPoll).toList();

      for (final seq in seqs) {
        final email = await _fetchMessage(channel, tag(), seq);
        await _expectOk(
          channel,
          tag(),
          'STORE $seq +FLAGS.SILENT (\\Seen)',
          'STORE',
        );
        if (email == null || email.from.isEmpty) continue;
        final allowed = allowSenders.isEmpty ||
            allowSenders.contains(email.from.toLowerCase().trim());
        if (!allowed) continue;
        _emails.add(email);
        emitted++;
      }
      await _expectOk(channel, tag(), 'LOGOUT', 'LOGOUT');
    } finally {
      channel.destroy();
    }
    return emitted;
  }

  Future<void> _expectOk(
    ImapChannel channel,
    String tag,
    String command,
    String operation,
  ) async {
    await channel.writeLine('$tag $command');
    while (true) {
      final line = await channel.readLine();
      if (line.startsWith('$tag ')) {
        if (!line.startsWith('$tag OK')) {
          throw StateError('IMAP $operation failed: $line');
        }
        return;
      }
    }
  }

  Future<ImapEmail?> _fetchMessage(
    ImapChannel channel,
    String tag,
    int sequence,
  ) async {
    await channel.writeLine('$tag FETCH $sequence (BODY.PEEK[])');
    ImapEmail? parsed;
    while (true) {
      var line = await channel.readLine();
      if (line.startsWith('$tag ')) {
        if (!line.startsWith('$tag OK')) {
          throw StateError('IMAP FETCH failed: $line');
        }
        return parsed;
      }
      if (!line.startsWith('* ') || !line.contains('FETCH')) continue;
      String? body;
      while (true) {
        final literal = RegExp(r'\{(\d+)\}\s*$').firstMatch(line);
        if (literal == null) break;
        body = await channel.readLiteral(int.parse(literal.group(1)!));
        line = await channel.readLine();
      }
      if (body != null) parsed = parseMessage(sequence, body);
    }
  }

  static _FetchedBody _splitMessage(String raw) {
    final headersEnd = raw.indexOf('\r\n\r\n');
    final altEnd = raw.indexOf('\n\n');
    final splitAt = headersEnd >= 0 ? headersEnd : (altEnd >= 0 ? altEnd : -1);
    final sepLen = headersEnd >= 0 ? 4 : 2;
    if (splitAt < 0) return _FetchedBody(headers: '', body: raw);
    return _FetchedBody(
      headers: raw.substring(0, splitAt),
      body: raw.substring(splitAt + sepLen),
    );
  }

  /// Parses a full RFC 822 message into from/subject/decoded body.
  static ImapEmail parseMessage(int sequence, String raw) {
    final parts = _splitMessage(raw);
    final headers = parseHeaders(parts.headers);
    final transferEncoding = headers['content-transfer-encoding'] ?? '';
    var body = decodeBody(parts.body, transferEncoding);
    if (utf8.encode(body).length > 524288) {
      body = body.substring(0, 524288);
    }
    final fromHeader = headers['from'] ?? '';
    final from = extractAddress(decodeRfc2047(fromHeader));
    final subject = decodeRfc2047(headers['subject'] ?? '');
    return ImapEmail(
      sequence: sequence,
      from: from,
      subject: subject,
      body: body,
    );
  }

  /// Parses a header block into a lowercase-name map with unfolded values.
  static Map<String, String> parseHeaders(String headers) {
    final map = <String, String>{};
    String? lastKey;
    for (final rawLine in headers.split(RegExp(r'\r?\n'))) {
      if (rawLine.isEmpty) continue;
      if ((rawLine.startsWith(' ') || rawLine.startsWith('\t')) &&
          lastKey != null) {
        map[lastKey] = '${map[lastKey]} ${rawLine.trim()}';
        continue;
      }
      final idx = rawLine.indexOf(':');
      if (idx <= 0) continue;
      lastKey = rawLine.substring(0, idx).trim().toLowerCase();
      map[lastKey] = rawLine.substring(idx + 1).trim();
    }
    return map;
  }

  /// Decodes RFC 2047 encoded-words (`=?charset?B/Q?text?=`) in a header
  /// value. Malformed words are passed through untouched.
  static String decodeRfc2047(String value) {
    final pattern = RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?=');
    return value.replaceAllMapped(pattern, (m) {
      final charset = m.group(1)!.toUpperCase();
      final encoding = m.group(2)!.toUpperCase();
      final text = m.group(3)!;
      List<int> bytes;
      if (encoding == 'B') {
        try {
          bytes = base64.decode(text);
        } on FormatException {
          return m.group(0)!;
        }
      } else {
        final sb = BytesBuilder();
        for (var i = 0; i < text.length; i++) {
          final ch = text[i];
          if (ch == '_') {
            sb.addByte(32);
          } else if (ch == '=' && i + 2 < text.length) {
            final v = int.tryParse(text.substring(i + 1, i + 3), radix: 16);
            if (v == null) {
              sb.add(utf8.encode(ch));
            } else {
              sb.addByte(v);
              i += 2;
            }
          } else {
            sb.add(utf8.encode(ch));
          }
        }
        bytes = sb.takeBytes();
      }
      if (charset == 'UTF-8' || charset == 'US-ASCII') {
        return utf8.decode(bytes, allowMalformed: true);
      }
      return String.fromCharCodes(bytes);
    });
  }

  /// Extracts a bare address from a From header value
  /// (`"Name" <a@b.c>` → `a@b.c`).
  static String extractAddress(String fromHeader) {
    final angle = RegExp(r'<([^>]+)>').firstMatch(fromHeader);
    if (angle != null) return angle.group(1)!.trim();
    return fromHeader.trim();
  }

  /// Decodes a body per its Content-Transfer-Encoding
  /// (base64, quoted-printable, or 7bit/8bit as-is).
  static String decodeBody(String body, String transferEncoding) {
    switch (transferEncoding.toLowerCase().trim()) {
      case 'base64':
        try {
          return utf8.decode(
            base64.decode(body.replaceAll(RegExp(r'\s+'), '')),
            allowMalformed: true,
          );
        } on FormatException {
          return body;
        }
      case 'quoted-printable':
        final sb = BytesBuilder();
        var i = 0;
        final flat = body.replaceAll('=\r\n', '').replaceAll('=\n', '');
        while (i < flat.length) {
          final ch = flat[i];
          if (ch == '=' && i + 2 < flat.length) {
            final v = int.tryParse(flat.substring(i + 1, i + 3), radix: 16);
            if (v != null) {
              sb.addByte(v);
              i += 3;
              continue;
            }
          }
          sb.add(utf8.encode(ch));
          i++;
        }
        return utf8.decode(sb.takeBytes(), allowMalformed: true);
      default:
        return body;
    }
  }
}
