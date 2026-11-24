import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _FixedProvider extends LlmProvider {
  _FixedProvider(this.pid, {this.callsTools = false});
  final String pid;
  final bool callsTools;
  @override
  String get id => pid;

  @override
  Capabilities get capabilities =>
      Capabilities(toolCalling: callsTools, streaming: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) => const Stream.empty();
}

Session _session(String id) =>
    Session(id: id, channel: 'cli', userKey: 'local');

void main() {
  group('Router cost-aware selection (P6 lanjutan)', () {
    test('tanpa providerCosts: perilaku lama (default provider menang)', () async {
      final router = Router(
        providers: {
          'alpha': _FixedProvider('alpha'),
          'beta': _FixedProvider('beta'),
        },
        defaultProviderId: 'alpha',
      );
      final d = await router.route('halo', _session('s1'));
      expect(d.providerId, 'alpha');
    });

    test('tanpa prefer: provider lebih murah menang atas yang mahal', () async {
      final router = Router(
        providers: {
          'mahal': _FixedProvider('mahal'),
          'murah': _FixedProvider('murah'),
        },
        providerCosts: const {'mahal': 10.0, 'murah': 1.0},
      );
      final d = await router.route('halo', _session('s1'));
      expect(d.providerId, 'murah');
    });

    test('capability menang atas penalti cost (swing maks 0.1)', () async {
      final router = Router(
        providers: {
          'mahal_toolful': _FixedProvider('mahal_toolful', callsTools: true),
          'murah_toolless': _FixedProvider('murah_toolless'),
        },
        providerCosts: const {'mahal_toolful': 100.0, 'murah_toolless': 1.0},
      );
      final d = await router.route(
        'halo',
        _session('s1'),
        preferredTier: 2,
      );
      expect(d.providerId, 'mahal_toolful');
    });

    test('cost sama: tidak ada penalti relatif (netral antar provider)', () async {
      final router = Router(
        providers: {
          'alpha': _FixedProvider('alpha'),
          'beta': _FixedProvider('beta'),
        },
        providerCosts: const {'alpha': 5.0, 'beta': 5.0},
      );
      final d = await router.route('halo', _session('s1'));
      expect(d.providerId, 'alpha');
    });

    test('provider tanpa cost dianggap gratis: menang melawan berbiaya',
        () async {
      final router = Router(
        providers: {
          'berbayar': _FixedProvider('berbayar'),
          'gratis': _FixedProvider('gratis'),
        },
        providerCosts: const {'berbayar': 7.0},
      );
      final d = await router.route('halo', _session('s1'));
      expect(d.providerId, 'gratis');
    });

    test('explain memuat penjelasan penalti cost', () async {
      final router = Router(
        providers: {
          'mahal': _FixedProvider('mahal'),
          'murah': _FixedProvider('murah'),
        },
        providerCosts: const {'mahal': 10.0, 'murah': 1.0},
      );
      final ex = await router.explain('halo', _session('s1'));
      final reason = '${ex['reason']}';
      expect(reason, contains('cost'));
      expect(reason, contains('penalti'));
    });
  });
}
