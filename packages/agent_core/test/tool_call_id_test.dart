import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('fallback tool call ids are distinct within one millisecond', () {
    final calls = List.generate(
      200,
      (_) => ToolCall.fromJson({
        'function': {'name': 'calc', 'arguments': '{"a":1}'},
      }),
    );
    expect(calls.map((c) => c.id).toSet(), hasLength(200));
  });

  test('explicit provider ids are preserved', () {
    final call = ToolCall.fromJson({
      'id': 'provider-1',
      'function': {'name': 'calc', 'arguments': '{}'},
    });
    expect(call.id, 'provider-1');
  });
}
