import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('unreadable lock is not automatically deleted', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_lock_');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/tiko.lock';
    await File(path).writeAsString('{incomplete');

    final lock = RuntimeLock(path);
    await expectLater(
      lock.acquire(profile: 'default', version: tikoVersion),
      throwsA(isA<StateError>()),
    );
    expect(await File(path).readAsString(), '{incomplete');
  });

  test('a valid lock owned by the current process is never replaced', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_lock_');
    addTearDown(() => temp.delete(recursive: true));
    final lock = RuntimeLock('${temp.path}/tiko.lock');
    await lock.acquire(profile: 'default', version: tikoVersion);
    addTearDown(lock.release);

    await expectLater(
      lock.acquire(profile: 'default', version: tikoVersion),
      throwsA(isA<LockHeldException>()),
    );
  });
}
