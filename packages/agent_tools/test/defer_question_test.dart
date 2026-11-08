import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: '.',
      );

  test('store mencatat, menjawab, dan memfilter terbuka', () {
    final store = DeferredQuestionStore();
    final a = store.add('s1', 'pakai DB mana?', ['mysql', 'sqlite']);
    store.add('s1', 'format output?', []);
    expect(a, equals('q-1'));
    expect(store.answer(a, 'sqlite'), isTrue);
    expect(store.answer('q-9', 'x'), isFalse);
    expect(store.openFor('s1').map((q) => q.id), equals(['q-2']));
    expect(store.openFor('s2'), isEmpty);
    expect(store.total, equals(2));
  });

  test('defer_question menolak pertanyaan kosong', () async {
    final res = await DeferQuestionTool(store: DeferredQuestionStore())
        .run({'question': ' '}, ctx());
    expect(res.isError, isTrue);
  });

  test('defer_question mencatat, list, lalu terjawab', () async {
    final store = DeferredQuestionStore();
    final res = await DeferQuestionTool(store: store).run({
      'question': 'Pakai bahasa apa?',
      'options': ['id', 'en'],
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('q-1'));
    final listed = await ListDeferredTool(store: store).run({}, ctx());
    expect(listed.content, contains('Pakai bahasa apa?'));
    expect(listed.content, contains('id / en'));
    final answered = await AnswerDeferredTool(store: store).run({
      'id': 'q-1',
      'answer': 'id',
    }, ctx());
    expect(answered.isError, isFalse);
    final after = await ListDeferredTool(store: store).run({}, ctx());
    expect(after.isError, isTrue);
  });

  test('answer_deferred menolak ID yang tidak dikenal', () async {
    final res = await AnswerDeferredTool(store: DeferredQuestionStore())
        .run({'id': 'q-9', 'answer': 'x'}, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('q-9'));
  });
}
