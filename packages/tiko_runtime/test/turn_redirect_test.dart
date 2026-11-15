import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('interruptAndWait: menunggu lock lepas lalu siap', () async {
    final coordinator = TurnRedirectCoordinator(pollInterval: const Duration(milliseconds: 1));
    var busy = true;
    var cancelled = false;
    final ready = await coordinator.interruptAndWait(
      cancelActive: () => cancelled = true,
      isBusy: () {
        if (cancelled) busy = false;
        return busy;
      },
    );
    expect(cancelled, isTrue);
    expect(ready, isTrue);
  });

  test('interruptAndWait: timeout mengembalikan false saat turn bandel',
      () async {
    final coordinator = TurnRedirectCoordinator(
      waitTimeout: const Duration(milliseconds: 80),
      pollInterval: const Duration(milliseconds: 5),
    );
    var cancelled = false;
    final ready = await coordinator.interruptAndWait(
      cancelActive: () => cancelled = true,
      isBusy: () => true,
    );
    expect(cancelled, isTrue);
    expect(ready, isFalse);
  });

  test('interruptAndWait: tanpa cancel pun selesai saat lock cepat lepas',
      () async {
    final coordinator = TurnRedirectCoordinator(pollInterval: const Duration(milliseconds: 1));
    var polls = 0;
    final ready = await coordinator.interruptAndWait(
      cancelActive: () {},
      isBusy: () { polls++; return polls < 3; },
    );
    expect(ready, isTrue);
    expect(polls, 4);
  });
}
