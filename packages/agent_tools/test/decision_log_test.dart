import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: '.',
      );

  test('DecisionLog mencatat dan memfilter', () {
    final log = DecisionLog();
    final e = log.record('pakai sqlite', 'tanpa server terpisah', []);
    expect(e.id, equals('d-1'));
    log.record('skip UI', 'di luar cakupan', ['flutter', 'cli']);
    expect(log.length, equals(2));
    expect(log.search('sqlite'), hasLength(1));
    expect(log.search('').length, equals(2));
    expect(log.search('tidak ada'), isEmpty);
  });

  test('record_decision menolak input tidak valid', () async {
    final log = DecisionLog();
    final res = await RecordDecisionTool(log: log).run({
      'decision': '',
      'rationale': 'x',
    }, ctx());
    expect(res.isError, isTrue);
    expect(log.length, equals(0));
  });

  test('why menampilkan keputusan beserta alasan', () async {
    final log = DecisionLog();
    await RecordDecisionTool(log: log).run({
      'decision': 'pakai sqlite',
      'rationale': 'tanpa server terpisah',
      'alternatives': ['mysql'],
    }, ctx());
    final res = await WhyTool(log: log).run({'query': 'sqlite'}, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('pakai sqlite'));
    expect(res.content, contains('tanpa server terpisah'));
    expect(res.content, contains('mysql'));
    final empty = await WhyTool(log: DecisionLog()).run({}, ctx());
    expect(empty.isError, isTrue);
  });
}
