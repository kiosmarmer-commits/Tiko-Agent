import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// Provider uji: turn 1 memanggil tool (write_file gagal atau sukses), turn 2
/// menjawab final yang mengklaim file berubah.
class _WriteFileProvider implements LlmProvider {
  _WriteFileProvider({required this.path, required this.failTool});

  final String path;
  final bool failTool;
  int _turn = 0;

  @override
  String get id => 'mock-write';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: true, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    _turn++;
    if (_turn == 1) {
      yield LlmToolCall(
        ToolCall(
          id: 'call_w1',
          name: 'write_file',
          args: {'path': path, 'content': 'isi file'},
        ),
      );
      yield const LlmDone(finishReason: 'tool_calls');
    } else {
      yield LlmTextDelta('File $path sudah ditulis dan tersimpan.');
      yield const LlmDone();
    }
  }

  @override
  Future<List<double>> embed(String text) async => List.filled(8, 0.1);
}

class _WriteFileExecutor implements ToolExecutor {
  _WriteFileExecutor({
    required this.fail,
    required this.writeOnSuccess,
    required this.workspacePath,
  });

  final bool fail;
  final bool writeOnSuccess;
  final String workspacePath;

  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    if (!fail && writeOnSuccess && call.name == 'write_file') {
      final rel = call.args['path'].toString();
      final file = File(rel.startsWith('/') ? rel : '$workspacePath/$rel');
      await file.parent.create(recursive: true);
      await file.writeAsString(call.args['content']?.toString() ?? '');
    }
    return ToolResult(
      callId: call.id,
      content: fail ? 'permission denied' : 'ok',
      isError: fail,
      durationMs: 1,
    );
  }
}

AgentLoop _buildLoop({
  required LlmProvider provider,
  required ToolExecutor executor,
  required void Function(String) onReply,
  required String workspace,
}) {
  return AgentLoop(
    router: Router(
      providers: {'mock-write': provider},
      defaultProviderId: 'mock-write',
    ),
    contextBuilder: ContextBuilder(),
    compactor: Compactor(),
    gate: AllowAllGate(),
    executor: executor,
    memory: NoopMemory(),
    reply: (m, text) async => onReply(text),
    workspacePath: workspace,
  );
}

Future<void> _handle(AgentLoop loop, Session session) {
  return loop.handle(
    InboundMessage(
      channel: 'cli',
      userKey: 'user1',
      sessionKey: 'cli:user1',
      text: 'tulis file',
    ),
    session,
  );
}

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_footer_test');
    session = Session(id: 'footer-session', channel: 'cli', userKey: 'user1');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('footer muncul saat klaim mutasi tetapi penulisan gagal', () async {
    final replies = <String>[];
    final provider = _WriteFileProvider(path: 'laporan.md', failTool: true);
    final loop = await _buildLoop(
      provider: provider,
      executor: _WriteFileExecutor(
        fail: true,
        writeOnSuccess: false,
        workspacePath: tmp.path,
      ),
      onReply: replies.add,
      workspace: tmp.path,
    );
    await _handle(loop, session);

    expect(replies, hasLength(1));
    expect(replies.last, contains('[verifikasi mutasi]'));
    expect(
      replies.last,
      contains('laporan.md` diklaim berubah tetapi seluruh percobaan'),
    );
    expect(loop.lastTurnEndReason, 'completed');
    expect(loop.lastTurnEndExplanation, contains('selesai'));
  });

  test('footer peringatkan bila file tidak ada di disk meski tool sukses',
      () async {
    final replies = <String>[];
    final provider = _WriteFileProvider(path: 'hilang.md', failTool: false);
    final loop = await _buildLoop(
      provider: provider,
      executor: _WriteFileExecutor(
        fail: false,
        writeOnSuccess: false,
        workspacePath: tmp.path,
      ),
      onReply: replies.add,
      workspace: tmp.path,
    );
    // Tool "sukses" tapi file sengaja tidak dibuat (simulasi disk lenyap).
    await _handle(loop, session);

    expect(replies.last, contains('[verifikasi mutasi]'));
    expect(replies.last, contains('hilang.md` diklaim tersimpan'));
  });

  test('file benar-benar ada dan diklaim → jawaban polos tanpa footer',
      () async {
    final replies = <String>[];
    final provider = _WriteFileProvider(path: 'ada.md', failTool: false);
    final loop = await _buildLoop(
      provider: provider,
      executor: _WriteFileExecutor(
        fail: false,
        writeOnSuccess: true,
        workspacePath: tmp.path,
      ),
      onReply: replies.add,
      workspace: tmp.path,
    );
    await _handle(loop, session);

    expect(File('${tmp.path}/ada.md').existsSync(), isTrue);
    expect(replies.last, isNot(contains('[verifikasi mutasi]')));
  });

  test('turn-end reason terisi untuk jalur cancel', () async {
    final replies = <String>[];
    final provider = _WriteFileProvider(path: 'x.md', failTool: true);
    final loop = await _buildLoop(
      provider: provider,
      executor: _WriteFileExecutor(
        fail: true,
        writeOnSuccess: false,
        workspacePath: tmp.path,
      ),
      onReply: replies.add,
      workspace: tmp.path,
    );
    final cancel = CancellationToken();
    cancel.cancel();
    await loop.handle(
      InboundMessage(
        channel: 'cli',
        userKey: 'user1',
        sessionKey: 'cli:user1',
        text: 'tulis file',
      ),
      session,
      cancelToken: cancel,
    );
    expect(loop.lastTurnEndReason, 'cancelled');
    expect(loop.lastTurnEndExplanation, isNotNull);
  });
}
