import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Builder config dari daftar provider chat (P6): value = property yaml
/// (tanpa indentasi), key urutan dipertahankan.
String _cfg(Map<String, String> chatProps) {
  final b = StringBuffer('providers:\n  default_chat: primary\n  chat:\n');
  chatProps.forEach((id, props) {
    b.writeln('    $id:');
    for (final line in props.split('\n')) {
      if (line.trim().isEmpty) continue;
      b.writeln('      $line');
    }
  });
  return b.toString();
}

void main() {
  group('P6 — kontrol routing per provider (weight/cost)', () {
    test('tanpa weight/cost: perilaku lama (default, lalu urutan config)', () {
      final (cfg, issues) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock',
        'beta': 'type: mock',
        'gamma': 'type: mock',
        'delta': 'type: mock\nenabled: false',
      }));
      expect(issues.where((i) => i.fatal), isEmpty);
      expect(
        cfg.fallbackChainIds('primary'),
        ['primary', 'alpha', 'beta', 'gamma'],
      );
    });

    test('weight menaikkan posisi fallback (desc)', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock',
        'beta': 'type: mock\nweight: 5',
      }));
      final chain = cfg.fallbackChainIds('primary');
      expect(chain.first, 'primary');
      expect(chain.indexOf('beta'), lessThan(chain.indexOf('alpha')));
    });

    test('weight sama → cost lebih murah dulu (asc)', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\ncost: 0.8',
        'beta': 'type: mock\ncost: 0.2',
      }));
      final chain = cfg.fallbackChainIds('primary');
      expect(chain.indexOf('beta'), lessThan(chain.indexOf('alpha')));
    });

    test('weight menang atas cost', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\nweight: 3\ncost: 9.0',
        'beta': 'type: mock\nweight: 1\ncost: 0.1',
      }));
      final chain = cfg.fallbackChainIds('primary');
      expect(chain.indexOf('alpha'), lessThan(chain.indexOf('beta')));
    });

    test('provider disabled tidak pernah masuk chain', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\nweight: 99\nenabled: false',
        'beta': 'type: mock',
      }));
      expect(cfg.fallbackChainIds('primary'), ['primary', 'beta']);
    });

    test('tie total: urutan config dipertahankan (sort stabil via index)', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\nweight: 2',
        'beta': 'type: mock\nweight: 2',
      }));
      final chain = cfg.fallbackChainIds('primary');
      expect(chain.indexOf('alpha'), lessThan(chain.indexOf('beta')));
    });

    test('weight/cost invalid → issue non-fatal, nilai diabaikan', () {
      final (cfg, issues) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\nweight: "lima"\ncost: -1',
        'beta': 'type: mock',
      }));
      expect(issues.where((i) => i.fatal), isEmpty);
      expect(
        issues.any((i) => i.path == 'providers.chat.alpha.weight'),
        isTrue,
      );
      expect(
        issues.any((i) => i.path == 'providers.chat.alpha.cost'),
        isTrue,
      );
      expect(cfg.fallbackChainIds('primary').first, 'primary');
    });

    test('primary tetap di depan meski weight-nya paling kecil', () {
      final (cfg, _) = TikoConfig.parse(_cfg({
        'primary': 'type: mock\nweight: 0',
        'alpha': 'type: mock\nweight: 100',
      }));
      expect(cfg.fallbackChainIds('primary').first, 'primary');
    });

    test('cost int diterima (konversi ke double)', () {
      final (cfg, issues) = TikoConfig.parse(_cfg({
        'primary': 'type: mock',
        'alpha': 'type: mock\ncost: 1',
        'beta': 'type: mock\ncost: 0.5',
      }));
      expect(issues.where((i) => i.fatal), isEmpty);
      final chain = cfg.fallbackChainIds('primary');
      expect(chain.indexOf('beta'), lessThan(chain.indexOf('alpha')));
    });
  });
}
