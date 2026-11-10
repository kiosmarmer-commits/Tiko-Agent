import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('argument fingerprint is stable across map key order', () {
    final left = CapabilityToken.fingerprintArguments({
      'path': 'docs/a.md',
      'options': {'mode': 'append', 'line': 3},
      'content': 'hello',
    });
    final right = CapabilityToken.fingerprintArguments({
      'content': 'hello',
      'options': {'line': 3, 'mode': 'append'},
      'path': 'docs/a.md',
    });
    expect(left, right);
  });

  test('argument fingerprint changes when the approved operation changes', () {
    final approved = CapabilityToken.fingerprintArguments({'path': 'safe.txt'});
    final changed = CapabilityToken.fingerprintArguments({'path': '../secret.txt'});
    expect(approved, isNot(changed));
    expect(
      CapabilityToken.fingerprintArguments({
        'path': 'safe.txt',
        '_capability_id': 'attached-after-approval',
      }),
      approved,
    );
    expect(
      CapabilityToken.fingerprintArguments({
        'path': 'safe.txt',
        'metadata': {'_capability_id': 'user-data'},
      }),
      isNot(CapabilityToken.fingerprintArguments({
        'path': 'safe.txt',
        'metadata': {'_capability_id': 'changed'},
      })),
    );
  });

  test('tokens use long random ids and are single-use in the vault', () {
    final token = CapabilityToken.mint(
      sessionId: 's',
      tool: 'write_file',
      operations: const ['execute'],
      roots: const ['/workspace'],
      arguments: const {'path': 'safe.txt', 'content': 'ok'},
    );
    expect(token.id.length, greaterThanOrEqualTo(32));
    final vault = CapabilityVault()..issue(token);
    expect(vault.take(token.id), same(token));
    expect(vault.take(token.id), isNull);
  });

  test('oversized and unsupported arguments are rejected', () {
    expect(
      () => CapabilityToken.fingerprintArguments({'payload': List<String>.filled(110000, 'x').join()}),
      throwsFormatException,
    );
    expect(
      () => CapabilityToken.fingerprintArguments({'value': Object()}),
      throwsFormatException,
    );
  });
}
