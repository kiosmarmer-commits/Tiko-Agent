import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _FixedProvider extends LlmProvider {
  _FixedProvider(this.pid);
  final String pid;
  @override
  String get id => pid;
  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: false);
  @override
  Stream<LlmEvent> chat(ChatRequest req) => const Stream.empty();
}

Session _session(String id) =>
    Session(id: id, channel: 'cli', userKey: 'local');

void main() {
  test('preferredProviderId memaksa provider dipilih', () async {
    final router = Router(
      providers: {
        'alpha': _FixedProvider('alpha'),
        'beta': _FixedProvider('beta'),
      },
      defaultProviderId: 'alpha',
    );
    final session = _session('s1');
    final d1 = await router.route('halo', session);
    expect(d1.providerId, 'alpha');
    final d2 = await router.route(
      'halo',
      session,
      preferredProviderId: 'beta',
    );
    expect(d2.providerId, 'beta');
  });

  test('preferredProviderId tidak dikenal jatuh ke preferensi normal',
      () async {
    final router = Router(
      providers: {'alpha': _FixedProvider('alpha')},
      defaultProviderId: 'alpha',
    );
    final d = await router.route(
      'halo',
      _session('s1'),
      preferredProviderId: 'tidak-ada',
    );
    expect(d.providerId, 'alpha');
  });
}
