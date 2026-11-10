import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  final policy = ShellPolicy(
    allowlist: ShellPolicy.fromStringList(['ls', 'pwd', 'echo', 'git status']),
  );

  test('allows git status', () {
    expect(policy.check('git status'), isNull);
  });

  test('denies git push', () {
    expect(policy.check('git push --force'), isNotNull);
  });

  test('denies metacharacters', () {
    expect(policy.check('ls; rm -rf /'), isNotNull);
    expect(policy.check('echo `id`'), isNotNull);
  });

  test('allows ls', () {
    expect(policy.check('ls'), isNull);
  });
}
