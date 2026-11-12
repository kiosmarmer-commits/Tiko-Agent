import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('acquire, konflik, dan re-acquire owner sama', () {
    final m = LeaseManager();
    expect(
      m.acquire('file:src/a.dart', 'A', const Duration(minutes: 10)),
      isTrue,
    );
    expect(
      m.acquire('file:src/a.dart', 'B', const Duration(minutes: 10)),
      isFalse,
    );
    expect(
      m.acquire('file:src/a.dart', 'A', const Duration(minutes: 10)),
      isTrue,
    );
  });

  test('release hanya oleh owner', () {
    final m = LeaseManager();
    m.acquire('port:8080', 'A', const Duration(minutes: 10));
    expect(m.release('port:8080', 'B'), isFalse);
    expect(m.release('port:8080', 'A'), isTrue);
    expect(m.acquire('port:8080', 'B', const Duration(minutes: 1)), isTrue);
  });

  test('lease kedaluwarsa bisa direbut owner lain', () {
    final m = LeaseManager();
    m.acquire('db:app', 'A', Duration.zero);
    expect(m.acquire('db:app', 'B', const Duration(minutes: 1)), isTrue);
  });

  test('list terurut dan menandai kedaluwarsa', () {
    final m = LeaseManager();
    m.acquire('file:a.go', 'A', const Duration(minutes: 10));
    m.acquire('port:9000', 'B', Duration.zero);
    final items = m.list();
    expect(items.length, 2);
    expect(items.first.resource, 'file:a.go');
    expect(items.first.expired, isFalse);
    expect(items.last.resource, 'port:9000');
    expect(items.last.expired, isTrue);
  });
}
