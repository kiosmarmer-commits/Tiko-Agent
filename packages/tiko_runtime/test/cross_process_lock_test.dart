import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('dua acquire konkuren ter-serialisasi: satu holder pada satu waktu',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_xlock_');
    addTearDown(() => temp.delete(recursive: true));
    final lock = CrossProcessLock('${temp.path}/data.json');

    final order = <String>[];
    Future<void> worker(String name) async {
      final ticket = await lock.acquire();
      order.add('$name:in');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      order.add('$name:out');
      await ticket.release();
    }

    await Future.wait([worker('a'), worker('b')]);

    final aIn = order.indexOf('a:in');
    final aOut = order.indexOf('a:out');
    final bIn = order.indexOf('b:in');
    final bOut = order.indexOf('b:out');
    final aFirst = aIn < bIn;
    expect(
      aFirst ? aOut < bIn : bOut < aIn,
      isTrue,
      reason: 'kritis pekerja pertama harus selesai sebelum pekerja kedua '
          'masuk: $order',
    );
  });

  test('lock yang ditinggalkan holder mati di-reclaim setelah staleAfter',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_xlock_stale_');
    addTearDown(() => temp.delete(recursive: true));
    final lockPath = '${temp.path}/data.json.lock';
    final abandoned = File(lockPath);
    await abandoned.writeAsString('');
    // Backdate mtime melampaui staleAfter.
    final old = DateTime.now().subtract(const Duration(minutes: 6));
    await abandoned.setLastModified(old);

    final lock = CrossProcessLock(
      '${temp.path}/data.json',
      timeout: const Duration(seconds: 2),
      staleAfter: const Duration(minutes: 5),
    );
    final ticket = await lock.acquire();
    expect(await abandoned.exists(), isTrue);
    await ticket.release();
    expect(await abandoned.exists(), isFalse);
  });
}
