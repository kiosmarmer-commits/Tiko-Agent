import 'package:agent_flutter/ui/status_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ringkasan routing memuat tiers, kesehatan, dan server MCP', () {
    final s = RoutingSummary.fromStatus(const {
      'routing': {
        'default': 'mock',
        'tiers': {'1': 'kecil', '3': 'besar'},
        'providers': ['mock', 'kecil', 'besar'],
        'health': {
          'mock': {'failures': 0, 'open': false},
          'besar': {'failures': 3, 'open': true, 'last_error': 'down'},
        },
      },
      'mcp': {
        'servers': [
          {
            'id': 'helper',
            'type': 'stdio',
            'enabled': true,
            'risk': 'high',
            'command': 'node',
          },
          {
            'id': 'remote',
            'type': 'http',
            'enabled': false,
            'risk': 'high',
            'url': 'http://127.0.0.1:9000/mcp',
          },
        ],
      },
    });

    expect(s.defaultProvider, 'mock');
    expect(s.tiers, {'1': 'kecil', '3': 'besar'});
    expect(s.providerForTier('1'), 'kecil');
    expect(s.providerForTier('2'), 'mock');
    expect(s.providers, ['mock', 'kecil', 'besar']);
    expect(s.health['besar']!['open'], isTrue);
    expect(s.health['mock']!['failures'], 0);
    expect(s.mcpServers.length, 2);
    expect(s.mcpServers.first['id'], 'helper');
    expect(s.mcpServers.last['url'], 'http://127.0.0.1:9000/mcp');
  });

  test('payload tanpa routing atau mcp menghasilkan ringkasan kosong', () {
    final s = RoutingSummary.fromStatus(null);

    expect(s.defaultProvider, '—');
    expect(s.tiers, isEmpty);
    expect(s.providers, isEmpty);
    expect(s.health, isEmpty);
    expect(s.mcpServers, isEmpty);
  });
}
