// Hermes fase-10: checkpoints (`agent/checkpoints/*`) + context breakdown
// (`agent/context_breakdown.py`) — snapshot pra-mutasi, restore `/undo`,
// jail path workspace, batas ukuran, dan breakdown jendela konteks.
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('FileCheckpoint roundtrip', () {
    test('toJson/fromJson mempertahankan isi (base64)', () {
      final cp = FileCheckpoint(
        id: 'cp-1-1',
        relPath: 'notes/a.md',
        existed: true,
        content: 'isi lama\nbaris 2',
        at: DateTime.now().toUtc(),
        reason: 'write_file',
      );
      final back = FileCheckpoint.fromJson(cp.toJson());
      expect(back, isNotNull);
      expect(back!.relPath, 'notes/a.md');
      expect(back.existed, isTrue);
      expect(back.content, 'isi lama\nbaris 2');
    });

    test('fromJson ketat pada data korup', () {
      expect(FileCheckpoint.fromJson(null), isNull);
      expect(FileCheckpoint.fromJson('x'), isNull);
      expect(FileCheckpoint.fromJson({'id': 'x'}), isNull);
      // existed=true tanpa base64 valid → null.
      expect(
        FileCheckpoint.fromJson({
          'id': 'cp-1',
          'path': 'a.md',
          'existed': true,
          'content_base64': '!!!bukan-base64!!!',
          'at': '2026-01-01T00:00:00Z',
          'reason': 'write_file',
        }),
        isNull,
      );
    });
  });

  group('CheckpointStore', () {
    late Directory ws;

    setUp(() async {
      ws = await Directory.systemTemp.createTemp('tiko_cp_test');
      await Directory('${ws.path}/src').create();
      await File('${ws.path}/src/a.txt').writeAsString('isi lama');
    });

    tearDown(() async {
      try {
        await ws.delete(recursive: true);
      } catch (_) {}
    });

    test('snapshot file yang ada → restore mengembalikan isi lama', () {
      final store = CheckpointStore();
      final cp = store.snapshotFile(
        ws.path,
        'src/a.txt',
        reason: 'write_file',
      );
      expect(cp, isNotNull);
      expect(cp!.existed, isTrue);
      expect(cp.content, 'isi lama');
      File('${ws.path}/src/a.txt').writeAsStringSync('DIOVERWRITE');
      final (restored, failed) = store.restore(ws.path, [cp]);
      expect(failed, isEmpty);
      expect(restored, ['src/a.txt']);
      expect(File('${ws.path}/src/a.txt').readAsStringSync(), 'isi lama');
    });

    test('snapshot file baru → restore menghapus file', () {
      final store = CheckpointStore();
      final cp = store.snapshotFile(
        ws.path,
        'src/baru.txt',
        reason: 'write_file',
      );
      expect(cp, isNotNull);
      expect(cp!.existed, isFalse);
      File('${ws.path}/src/baru.txt').writeAsStringSync('ADA');
      final (restored, failed) = store.restore(ws.path, [cp]);
      expect(failed, isEmpty);
      expect(restored, ['src/baru.txt']);
      expect(File('${ws.path}/src/baru.txt').existsSync(), isFalse);
    });

    test('restore membuat parent dir bila hilang', () {
      final store = CheckpointStore();
      final f = File('${ws.path}/deep/nest/x.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('v1');
      final cp = store.snapshotFile(ws.path, 'deep/nest/x.txt', reason: 'w');
      expect(cp, isNotNull);
      expect(cp!.existed, isTrue);
      f.writeAsStringSync('v2');
      Directory('${ws.path}/deep').deleteSync(recursive: true);
      final (restored, failed) = store.restore(ws.path, [cp]);
      expect(failed, isEmpty);
      expect(restored, ['deep/nest/x.txt']);
      expect(File('${ws.path}/deep/nest/x.txt').readAsStringSync(), 'v1');
    });

    test('path jail: absolut, escape `..`, kosong → null', () {
      final store = CheckpointStore();
      expect(store.snapshotFile(ws.path, null, reason: 'w'), isNull);
      expect(store.snapshotFile(ws.path, '', reason: 'w'), isNull);
      expect(
        store.snapshotFile(ws.path, '/etc/passwd', reason: 'w'),
        isNull,
      );
      expect(
        store.snapshotFile(ws.path, '../escape.txt', reason: 'w'),
        isNull,
      );
      expect(
        store.snapshotFile(ws.path, 'src/../../escape.txt', reason: 'w'),
        isNull,
      );
      // Restore juga tervalidasi jail — checkpoint jahat tidak lolos.
      final evil = FileCheckpoint(
        id: 'cp-evil',
        relPath: '../evil.txt',
        existed: false,
        at: DateTime.now().toUtc(),
        reason: 'write_file',
      );
      final (restored, failed) = store.restore(ws.path, [evil]);
      expect(restored, isEmpty);
      expect(failed, ['../evil.txt']);
      expect(File('${ws.parent.path}/evil.txt').existsSync(), isFalse);
    });

    test('oversize → null snapshot (fail-open)', () {
      final store = CheckpointStore(maxFileBytes: 8);
      File('${ws.path}/src/a.txt').writeAsStringSync('0123456789');
      expect(store.snapshotFile(ws.path, 'src/a.txt', reason: 'w'), isNull);
      // Ukuran tepat batas masih di-snapshot.
      File('${ws.path}/src/a.txt').writeAsStringSync('01234567');
      expect(store.snapshotFile(ws.path, 'src/a.txt', reason: 'w'), isNotNull);
    });

    test('snapshotBatch: cap maxBatchFiles, filter path null', () {
      final store = CheckpointStore(maxBatchFiles: 2);
      final batch = store.snapshotBatch(ws.path, [
        ('write_file', 'src/a.txt'),
        ('write_file', null),
        ('write_file', 'src/b.txt'),
        ('write_file', 'src/c.txt'),
      ]);
      expect(batch.length, 2, reason: 'cap 2 file per batch');
      expect(batch.map((c) => c.relPath), contains('src/a.txt'));
    });

    test('id checkpoint unik antar snapshot', () {
      final store = CheckpointStore();
      final a = store.snapshotFile(ws.path, 'src/a.txt', reason: 'w');
      final b = store.snapshotFile(ws.path, 'src/a.txt', reason: 'w');
      expect(a!.id, isNot(b!.id));
    });
  });

  group('ContextBreakdown (Hermes context_breakdown.py)', () {
    test('kategori: system, tools, percakapan; gambar pada harga C7', () {
      final desc = 'y' * 80;
      final ctx = AgentContext(
        systemPrompt: 'x' * 400,
        tools: [
          ToolSpec(
            name: 'write_file',
            description: desc,
            inputSchema: const {},
          ),
        ],
        messages: [
          ChatMessage(role: 'user', content: 'z' * 400),
          const ChatMessage(
            role: 'assistant',
            content: '',
            toolCalls: [ToolCall(id: 'abc123', name: 'write_file', args: {})],
          ),
        ],
        session: Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      final r = ContextBreakdown.compute(ctx, imageCost: 1000);
      expect(r.systemPromptTokens, 100);
      // name 10 + desc 80 + schema '{}' 2 chars ~/ 4.
      expect(r.toolDefinitionsTokens, ('write_file'.length + desc.length + 2) ~/ 4);
      expect(r.conversationTokens, (400 + 'abc123' 'write_file'.length) ~/ 4);
      expect(r.imageTokens, 0);
      expect(r.totalTokens, greaterThan(0));
      expect(r.anchored, isFalse);
    });

    test('anchored: total memakai usage nyata bila anchor fresh', () {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final ctx = AgentContext(
        systemPrompt: 'sys',
        tools: const [],
        messages: [m1],
        session: Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      final anchor = UsageAnchor.capture(
        500,
        30,
        ctx.toRequest().messages,
      )!;
      final r = ContextBreakdown.compute(ctx, anchor: anchor);
      expect(r.anchored, isTrue);
      expect(r.totalTokens, 530);
      // Anchor basah terhadap transcript lain → fallback estimasi.
      final ctxOther = AgentContext(
        systemPrompt: 'sys',
        tools: const [],
        messages: [const ChatMessage(role: 'user', content: 'lain')],
        session: Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      final r2 = ContextBreakdown.compute(ctxOther, anchor: anchor);
      expect(r2.anchored, isFalse);
    });

    test('formatLines: row nol opsional dihilangkan, conversation selalu', () {
      final zero = ContextBreakdownResult(
        systemPromptTokens: 0,
        toolDefinitionsTokens: 0,
        conversationTokens: 0,
        imageTokens: 0,
        totalTokens: 0,
        anchored: false,
      );
      final lines = ContextBreakdown.formatLines(zero);
      expect(lines, hasLength(3), reason: 'system + conversation + total');
      expect(lines.join('\n'), contains('percakapan: 0 token'));
      expect(lines.join('\n'), isNot(contains('skema tool')));
      expect(lines.join('\n'), isNot(contains('gambar:')));
      final withTool = ContextBreakdownResult(
        systemPromptTokens: 10,
        toolDefinitionsTokens: 20,
        conversationTokens: 30,
        imageTokens: 40,
        totalTokens: 100,
        anchored: true,
      );
      final lines2 = ContextBreakdown.formatLines(withTool);
      expect(lines2.join('\n'), contains('skema tool: 20 token'));
      expect(lines2.join('\n'), contains('gambar: 40 token'));
      expect(lines2.join('\n'), contains('anchored usage provider'));
    });

    test('toJson: row nol opsional hilang; fromJson default aman', () {
      final zero = ContextBreakdownResult(
        systemPromptTokens: 0,
        toolDefinitionsTokens: 0,
        conversationTokens: 5,
        imageTokens: 0,
        totalTokens: 5,
        anchored: false,
      );
      expect(zero.toJson().containsKey('tool_definitions_tokens'), isFalse);
      expect(zero.toJson().containsKey('image_tokens'), isFalse);
      final back = ContextBreakdownResult.fromJson(zero.toJson());
      expect(back!.conversationTokens, 5);
      expect(ContextBreakdownResult.fromJson(null), isNull);
      expect(ContextBreakdownResult.fromJson('x'), isNull);
    });
  });

  group('AgentLoop checkpoint wiring', () {
    test('turn dengan write_file → checkpoint pra-mutasi + /undo restore',
        () async {
      final ws = await Directory.systemTemp.createTemp('tiko_cp_loop');
      final replies = <String>[];
      final loop = AgentLoop(
        router: Router(
          providers: {'w': _WriteLlm()},
          defaultProviderId: 'w',
        ),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: _WritingExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
        workspacePath: ws.path,
        checkpointStore: CheckpointStore(),
      );
      final session = Session(id: 's10', channel: 'cli', userKey: 'u1');
      try {
        await loop.handle(
          const InboundMessage(
            channel: 'cli',
            userKey: 'u1',
            sessionKey: 'cli:u1',
            text: 'tulis laporan',
          ),
          session,
        );
        expect(File('${ws.path}/laporan.txt').readAsStringSync(), 'versi 1');
        final cps = loop.lastTurnCheckpoints;
        expect(cps, hasLength(1), reason: '1 call mutatif → 1 checkpoint');
        expect(cps.first.relPath, 'laporan.txt');
        expect(cps.first.reason, 'write_file');
        // Undo: file ditulis turn ini (existed=false) → dihapus kembali.
        final (restored, failed) = loop.checkpointStore!.restore(
          ws.path,
          cps,
        );
        expect(failed, isEmpty);
        expect(restored, ['laporan.txt']);
        expect(File('${ws.path}/laporan.txt').existsSync(), isFalse);
        // Breakdown konteks tersedia setelah turn.
        expect(loop.lastContextBreakdown, isNotNull);
        expect(loop.lastContextBreakdown!.totalTokens, greaterThan(0));
      } finally {
        await ws.delete(recursive: true);
      }
    });
  });
}

/// Executor yang benar-benar menulis file (mensimulasikan write_file).
class _WritingExecutor implements ToolExecutor {
  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    final rel = call.args['path'] as String?;
    if (rel == null) {
      return ToolResult(callId: call.id, content: 'path wajib', isError: true);
    }
    try {
      File('${ctx.workspacePath}/$rel').writeAsStringSync(
        '${call.args['content'] ?? 'ditulis oleh agent'}',
      );
      return ToolResult(callId: call.id, content: 'ok');
    } catch (e) {
      return ToolResult(callId: call.id, content: '$e', isError: true);
    }
  }
}

/// Provider scripted: request pertama tool call write_file, kedua jawaban
/// akhir (pola _UsageLlm fase-9).
class _WriteLlm implements LlmProvider {
  int callCount = 0;

  @override
  String get id => 'w';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: true);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    callCount++;
    if (callCount == 1) {
      yield const LlmToolCall(
        ToolCall(
          id: 'c1',
          name: 'write_file',
          args: {'path': 'laporan.txt', 'content': 'versi 1'},
        ),
      );
      yield const LlmDone(finishReason: 'tool_calls');
      return;
    }
    yield const LlmTextDelta('selesai');
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

