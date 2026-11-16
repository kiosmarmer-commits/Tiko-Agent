import 'dart:async';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Scripted IMAP server channel: replays queued server lines and records
/// every client command.
class FakeImapChannel implements ImapChannel {
  FakeImapChannel();

  final List<String> commands = [];
  final _pending = <String>[];
  final _waiter = <Completer<void>>[];

  void queue(String line) {
    _pending.add(line);
    for (final w in _waiter) {
      if (!w.isCompleted) w.complete();
    }
    _waiter.clear();
  }

  /// Akses massal ke antrean baris server (sama dengan queue per baris
  /// sebelum koneksi dibaca).
  List<String> get script => _pending;

  @override
  Future<void> writeLine(String line) async => commands.add(line);

  @override
  Future<String> readLine() async {
    while (_pending.isEmpty) {
      final c = Completer<void>();
      _waiter.add(c);
      await c.future;
    }
    return _pending.removeAt(0);
  }

  @override
  Future<String> readLiteral(int bytes) async {
    while (_pending.isEmpty) {
      final c = Completer<void>();
      _waiter.add(c);
      await c.future;
    }
    return _pending.removeAt(0).substring(0, bytes);
  }

  @override
  void destroy() {}
}

Future<(FakeImapChannel, List<ImapEmail>)> _runPoll({
  required Set<String> allowSenders,
  required List<String> script,
}) async {
  final channel = FakeImapChannel();
  for (final line in script) {
    channel.queue(line);
  }
  final poller = ImapPoller(
    host: 'imap.test',
    username: 'bot@test.id',
    password: 'secret',
    allowSenders: allowSenders,
    channelFactory: () => channel,
  );
  final got = <ImapEmail>[];
  final sub = poller.emails.listen(got.add);
  final count = await poller.pollOnce();
  await sub.cancel();
  await poller.stop();
  expect(got, hasLength(count));
  return (channel, got);
}

void main() {
  test('polls unseen message, emits, and marks Seen', () async {
    final raw =
        'From: Andi <andi@kirim.test>\r\n'
        'Subject: Laporan harian\r\n'
        'Content-Transfer-Encoding: 8bit\r\n'
        '\r\n'
        'Halo, ini isinya.\r\n';
    final (channel, emails) = await _runPoll(
      allowSenders: {'andi@kirim.test'},
      script: [
        'a1 OK logged in',
        '* FLAGS (\\Seen)',
        'a2 OK [READ-WRITE] selected',
        '* SEARCH 3',
        'a3 OK done',
        '* 3 FETCH (BODY[] {${raw.length}}',
        raw,
        ')',
        'a4 OK stored',
        'a5 OK bye',
        'a6 OK bye',
      ],
    );
    expect(emails.single.from, 'andi@kirim.test');
    expect(emails.single.subject, 'Laporan harian');
    expect(emails.single.body.trim(), 'Halo, ini isinya.');
    expect(
      channel.commands,
      containsAllInOrder([
        contains('LOGIN "bot@test.id" "secret"'),
        contains('SELECT "INBOX"'),
        contains('SEARCH UNSEEN'),
        contains('FETCH 3 (BODY.PEEK[])'),
        contains('STORE 3 +FLAGS.SILENT (\\Seen)'),
        contains('LOGOUT'),
      ]),
    );
  });

  test('message from non-allowed sender is marked Seen but not emitted',
      () async {
    final raw =
        'From: spammer@evil.test\r\n'
        'Subject: spam\r\n'
        '\r\n'
        'beli sekarang\r\n';
    final (channel, emails) = await _runPoll(
      allowSenders: {'andi@kirim.test'},
      script: [
        'a1 OK logged in',
        'a2 OK selected',
        '* SEARCH 1',
        'a3 OK done',
        '* 1 FETCH (BODY[] {${raw.length}}',
        raw,
        ')',
        'a4 OK stored',
        'a5 OK bye',
        'a6 OK bye',
      ],
    );
    expect(emails, isEmpty);
    expect(
      channel.commands.where((c) => c.contains('STORE')),
      hasLength(1),
    );
  });

  test('LOGIN failure surfaces as StateError', () async {
    final channel = FakeImapChannel()..queue('a1 NO authentication failed');
    final poller = ImapPoller(
      host: 'imap.test',
      username: 'bot@test.id',
      password: 'wrong',
      allowSenders: const {'a@b.c'},
      channelFactory: () => channel,
    );
    await expectLater(poller.pollOnce(), throwsStateError);
    await poller.stop();
  });

  test('RFC 2047 Q-encoded subject and base64 body are decoded', () {
    final raw = 'From: =?UTF-8?Q?Budi_Santoso?= <budi@x.test>\r\n'
        'Subject: =?UTF-8?Q?Laporan_Q3_=E2=80=94_final?=\r\n'
        'Content-Transfer-Encoding: base64\r\n'
        '\r\n'
        'SGFsbyBzZWx1cnVoLCBpbmkgYmFkYW4gdGVzLg==\r\n';
    final msg = ImapPoller.parseMessage(1, raw);
    expect(msg.from, 'budi@x.test');
    expect(msg.subject, 'Laporan Q3 — final');
    expect(msg.body, 'Halo seluruh, ini badan tes.');
  });

  test('quoted-printable body is decoded and header folding unfolds', () {
    final raw = 'From: budi@x.test\r\n'
        'Subject: panjang\r\n'
        ' yang dilipat\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n'
        '\r\n'
        'Kulit manggis=\r\n'
        ' manis sekali.\r\n';
    final msg = ImapPoller.parseMessage(2, raw);
    expect(msg.body.trim(), 'Kulit manggis manis sekali.');
  });

  test('SEARCH with no unseen messages emits nothing', () async {
    final (channel, emails) = await _runPoll(
      allowSenders: {'a@b.c'},
      script: [
        'a1 OK logged in',
        'a2 OK selected',
        '* SEARCH',
        'a3 OK done',
        'a4 OK bye',
      ],
    );
    expect(emails, isEmpty);
    expect(channel.commands.where((c) => c.contains('FETCH')), isEmpty);
  });

  test('Message-ID header diparse ke ImapEmail.messageId', () {
    final raw = 'From: a@b.c\r\n'
        'Message-ID: <abc-123@x.test>\r\n'
        'Subject: s\r\n'
        '\r\n'
        'badan\r\n';
    final msg = ImapPoller.parseMessage(1, raw);
    expect(msg.messageId, '<abc-123@x.test>');
  });

  test('allowlist kosong fail-closed: tidak ada yang diemisi', () async {
    final raw = 'From: andi@kirim.test\r\n'
        'Subject: hi\r\n'
        '\r\n'
        'isi\r\n';
    final (channel, emails) = await _runPoll(
      allowSenders: const {},
      script: [
        'a1 OK logged in',
        'a2 OK selected',
        '* SEARCH 1',
        'a3 OK done',
        '* 1 FETCH (BODY[] {${raw.length}}',
        raw,
        ')',
        'a4 OK stored',
        'a5 OK bye',
        'a6 OK bye',
      ],
    );
    expect(emails, isEmpty,
        reason: 'allowlist kosong berarti tidak ada pengirim diizinkan '
            '(fail-closed), bukan izinkan semua');
    // Pesan tetap ditandai \Seen agar tidak diproses ulang.
    expect(channel.commands.where((c) => c.contains('STORE')), hasLength(1));
  });

  test('anti-replay: Message-ID sama yang muncul lagi sebagai UNSEEN '
      'hanya diemisi sekali', () async {
    final raw = 'From: andi@kirim.test\r\n'
        'Message-ID: <replay-1@kirim.test>\r\n'
        'Subject: penting\r\n'
        '\r\n'
        'isi pesan\r\n';
    List<String> script() => [
          'a1 OK logged in',
          'a2 OK selected',
          '* SEARCH 1',
          'a3 OK done',
          '* 1 FETCH (BODY[] {${raw.length}}',
          raw,
          ')',
          'a4 OK stored',
          'a5 OK bye',
          'a6 OK bye',
        ];
    // Dua poll berbeda menyajikan pesan yang sama sebagai UNSEEN —
    // mensimulasikan replay / flag yang dibuka ulang klien lain.
    final c1 = FakeImapChannel()..script.addAll(script());
    final c2 = FakeImapChannel()..script.addAll(script());
    final channels = [c1, c2].iterator;
    final poller = ImapPoller(
      host: 'imap.test',
      username: 'bot@test.id',
      password: 'secret',
      allowSenders: const {'andi@kirim.test'},
      channelFactory: () {
        channels.moveNext();
        return channels.current;
      },
    );
    final got = <ImapEmail>[];
    final sub = poller.emails.listen(got.add);
    expect(await poller.pollOnce(), 1);
    expect(await poller.pollOnce(), 0,
        reason: 'Message-ID yang sudah pernah diemisi tidak boleh '
            'diemisi ulang (anti-replay)');
    await sub.cancel();
    await poller.stop();
    expect(got, hasLength(1));
    expect(got.single.messageId, '<replay-1@kirim.test>');
  });

  test('lifecycle: poll gagal tidak mematikan loop, stop() menyelesaikan done',
      () async {
    final raw = 'From: andi@kirim.test\r\n'
        'Subject: sukses\r\n'
        '\r\n'
        'isi\r\n';
    final bad = FakeImapChannel()..queue('a1 NO login failed');
    final good = FakeImapChannel()
      ..script.addAll([
        'a1 OK logged in',
        'a2 OK selected',
        '* SEARCH 1',
        'a3 OK done',
        '* 1 FETCH (BODY[] {${raw.length}}',
        raw,
        ')',
        'a4 OK stored',
        'a5 OK bye',
        'a6 OK bye',
      ]);
    final channels = [bad, good].iterator;
    final errors = <String>[];
    final poller = ImapPoller(
      host: 'imap.test',
      username: 'bot@test.id',
      password: 'secret',
      allowSenders: const {'andi@kirim.test'},
      pollInterval: const Duration(milliseconds: 10),
      channelFactory: () {
        channels.moveNext();
        return channels.current;
      },
      onError: errors.add,
    );
    final firstEmail = poller.emails.first
        .timeout(const Duration(seconds: 5), onTimeout: () => throw TimeoutException('tidak ada email dari poll kedua'));
    poller.start();
    final email = await firstEmail;
    expect(email.subject, 'sukses');

    await poller.stop();
    await poller.done;
    expect(errors, hasLength(1),
        reason: 'kegagalan poll pertama dilaporkan via onError');
    expect(errors.single, contains('imap poll gagal'));

    // stop() idempotent.
    await poller.stop();
  });
}
