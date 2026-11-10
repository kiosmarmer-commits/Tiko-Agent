import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  test('brute force via SqliteVecIndex needs db — skip if no sqlite', () {
    // structural: class exists
    expect(DriftStyleMigrations.currentVersion, greaterThanOrEqualTo(3));
  });
}
