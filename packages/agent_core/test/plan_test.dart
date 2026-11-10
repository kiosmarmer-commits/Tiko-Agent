import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('plan parse steps', () {
    final steps = PlanExecute.parseStepsForTest(
      '1. Baca file\n2. Analisis\n3. Jawab',
      6,
    );
    expect(steps, hasLength(3));
    expect(steps.first, contains('Baca'));
  });
}
