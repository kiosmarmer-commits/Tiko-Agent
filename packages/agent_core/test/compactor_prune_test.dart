import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

AgentContext _ctxWithToolResults(List<String> contents) {
  final messages = <ChatMessage>[
    const ChatMessage(role: 'user', content: 'kerjakan'),
  ];
  for (var i = 0; i < contents.length; i++) {
    messages.add(
      ChatMessage(
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall(id: 'c$i', name: 'read_file', args: const {})],
      ),
    );
    messages.add(
      ChatMessage(
        role: 'tool',
        content: contents[i],
        toolCallId: 'c$i',
        name: 'read_file',
      ),
    );
  }
  final session = Session(id: 's', channel: 'cli', userKey: 'u');
  return AgentContext(messages: messages, tools: const [], session: session);
}

void main() {
  test('prune mengganti hasil tool besar (kecuali keep-last) dengan stub', () {
    final compactor = Compactor(maxToolResultChars: 100);
    final big = 'x' * 500;
    final ctx = _ctxWithToolResults([big, big, big, 'kecil']);
    final out = compactor.pruneToolResults(ctx);

    final toolMsgs = out.messages.where((m) => m.role == 'tool').toList();
    expect(toolMsgs, hasLength(4));
    // Dua hasil terakhir tetap panas.
    expect(toolMsgs[2].content, big);
    expect(toolMsgs[3].content, 'kecil');
    // Hasil lama jadi stub + bisa di-recall.
    expect(toolMsgs[0].content, startsWith('[pruned] tool_result'));
    expect(toolMsgs[1].content, startsWith('[pruned] tool_result'));
    final stats = compactor.lastPrune!;
    expect(stats.pruned, isTrue);
    expect(stats.pruneCount, 2);
    expect(stats.charsAfter, lessThan(stats.charsBefore));
  });

  test('konten asli hasil prune bisa di-recall lewat key stub', () {
    final compactor = Compactor(maxToolResultChars: 10);
    final ctx = _ctxWithToolResults(['a' * 200, 'b' * 200, 'c' * 200]);
    final out = compactor.pruneToolResults(ctx);
    final stub =
        out.messages.firstWhere((m) => m.content.startsWith('[pruned]'));
    final key = RegExp(r'\(prune-(\d+),').firstMatch(stub.content)!.group(1)!;
    expect(compactor.recallToolResult('prune-$key'), 'a' * 200);
  });

  test('hasil tool yang masih panas tidak pernah di-prune', () {
    final compactor = Compactor(maxToolResultChars: 100);
    final ctx = _ctxWithToolResults(['x' * 500, 'y' * 500]);
    final out = compactor.pruneToolResults(ctx);
    expect(compactor.lastPrune, isNull);
    // keepLastToolResults default 2 → keduanya masih panas.
    for (final m in out.messages.where((m) => m.role == 'tool')) {
      expect(m.content, isNot(startsWith('[pruned]')));
    }
  });

  test('prune tidak berlaku dua kali pada stub yang sudah ada', () {
    final compactor = Compactor(maxToolResultChars: 10);
    final ctx = _ctxWithToolResults(['a' * 200, 'b' * 200, 'c' * 200]);
    final once = compactor.pruneToolResults(ctx);
    final count1 =
        once.messages.where((m) => m.content.startsWith('[pruned]')).length;
    expect(count1, greaterThan(0));
    final twice = compactor.pruneToolResults(once);
    final count2 =
        twice.messages.where((m) => m.content.startsWith('[pruned]')).length;
    expect(count2, count1);
  });

  test('arsip LRU membatasi jumlah entri recall', () {
    final compactor = Compactor(
      maxToolResultChars: 10,
      maxArchivedToolResults: 3,
    );
    for (var round = 0; round < 5; round++) {
      final ctx = _ctxWithToolResults(List.filled(3, '${round}a' * 200));
      compactor.pruneToolResults(ctx);
    }
    expect(compactor.archivedToolResultKeys.length, 3);
  });

  test('disable lewat flag mematikan prune', () {
    final compactor = Compactor(
      maxToolResultChars: 10,
      pruneToolResultsEnabled: false,
    );
    final ctx = _ctxWithToolResults(['a' * 200, 'b' * 200, 'c' * 200]);
    final out = compactor.pruneToolResults(ctx);
    expect(compactor.lastPrune, isNull);
    expect(out.messages.any((m) => m.content.startsWith('[pruned]')), isFalse);
  });
}
