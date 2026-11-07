import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('session lock exclusive', () {
    final lock = SessionLock();
    expect(lock.tryAcquire('a'), isTrue);
    expect(lock.tryAcquire('a'), isFalse);
    lock.release('a');
    expect(lock.tryAcquire('a'), isTrue);
  });
}
