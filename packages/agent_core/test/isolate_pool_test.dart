import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('isolate pool runs function', () async {
    final pool = IsolatePool(maxWorkers: 2);
    final r = await pool.run((s) => s.toUpperCase(), 'hi');
    expect(r, 'HI');
  });
}
