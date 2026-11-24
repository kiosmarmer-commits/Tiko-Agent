import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tiko_tui/tiko_tui.dart';

/// TUI-P3: progress live saat turn berjalan — spinner "Thinking…", label
/// tool dari [TuiProgress.status], dan cancel Ctrl-C (0x03) via
/// [TuiSession.onCancelKey].
void main() {
  test('spinner menampilkan label dari progress.status selama turn berjalan',
      () async {
    final out = StringBuffer();
    TuiProgress? active;
    final input = StreamController<List<int>>();
    final session = TuiSession(
      handler: (inputArg) async {
        expect(inputArg, 'hai');
        active?.status('tool read_file…');
        await Future<void>.delayed(const Duration(milliseconds: 350));
        return TuiOutcome(['selesai: $inputArg']);
      },
      onTurnStart: (p) => active = p,
      prompt: 'you> ',
      out: out,
      inputStream: input.stream,
    );
    unawaited(session.run());
    input.add(utf8.encode('hai'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    input.add([0x0D]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    input.add([0x04]);
    await input.close();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(out.toString(), contains('read_file…'));
    expect(out.toString(), contains('Thinking…'));
    expect(out.toString(), contains('selesai: hai'));
    expect(out.toString(), contains('\x1B[2K\r'));
  });

  test('Ctrl-C saat turn berjalan memanggil onCancelKey (idempoten)', () async {
    final out = StringBuffer();
    var cancelCalls = 0;
    TuiProgress? active;
    final input = StreamController<List<int>>();
    final session = TuiSession(
      handler: (inputArg) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return TuiOutcome(['respon:$inputArg']);
      },
      onTurnStart: (p) => active = p,
      onCancelKey: () => cancelCalls++,
      prompt: 'you> ',
      out: out,
      inputStream: input.stream,
    );
    unawaited(session.run());
    input.add(utf8.encode('kerja'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    input.add([0x0D]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    input.add([0x03]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    input.add([0x04]);
    await input.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(cancelCalls, 1);
    expect(active?.cancelNotified ?? false, isTrue);
    expect(out.toString(), contains('dibatalkan'));
    expect(out.toString(), contains('respon:kerja'));
  });

  test('ESC (0x1B) juga membatalkan turn', () async {
    var cancelCalls = 0;
    final out = StringBuffer();
    final input = StreamController<List<int>>();
    final session = TuiSession(
      handler: (inputArg) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return const TuiOutcome(['ok']);
      },
      onCancelKey: () => cancelCalls++,
      prompt: 'you> ',
      out: out,
      inputStream: input.stream,
    );
    unawaited(session.run());
    input.add(utf8.encode('x'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    input.add([0x0D]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    input.add([0x1B]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    input.add([0x04]);
    await input.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cancelCalls, 1);
  });

  test('input biasa yang diketik selama turn dibuang (tidak merusak editor)',
      () async {
    final out = StringBuffer();
    final input = StreamController<List<int>>();
    final session = TuiSession(
      handler: (inputArg) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return TuiOutcome(['pertama:$inputArg']);
      },
      prompt: 'you> ',
      out: out,
      inputStream: input.stream,
    );
    unawaited(session.run());
    input.add(utf8.encode('satu'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    input.add([0x0D]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // diketik selama progress: dibuang, tidak bocor ke editor berikutnya.
    input.add(utf8.encode('dua'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    input.add([0x04]);
    await input.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(out.toString(), contains('pertama:satu'));
    expect(out.toString(), isNot(contains('dua')));
  });

  test('line mode: tanpa spinner, handler tetap menerima input polos', () async {
    final out = StringBuffer();
    final session = TuiSession(
      handler: (input) async {
        if (input == '/quit') return const TuiOutcome([], exit: true);
        return TuiOutcome(['balas $input']);
      },
      out: out,
      forceLineMode: true,
      scriptedLines: ['cek'],
    );
    await session.run();
    expect(out.toString(), isNot(contains('Thinking…')));
    expect(out.toString(), contains('balas cek'));
  });
}
