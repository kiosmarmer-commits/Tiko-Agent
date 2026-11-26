import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late Directory dataDir;
  late ToolContext ctx;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tiko_semidx_ws_');
    dataDir = Directory.systemTemp.createTempSync('tiko_semidx_data_');
    Directory('${workspace.path}/lib/src').createSync(recursive: true);
    File('${workspace.path}/lib/src/payment_gateway.dart').writeAsStringSync('''
// Sistem pembayaran lokal.
class PaymentGateway {
  int retry(String id) {
    return 1;
  }
}
''');
    File('${workspace.path}/lib/src/inventory_service.dart').writeAsStringSync('''
class InventoryService {
  List<String> listItems() {
    return ['a', 'b'];
  }
}
''');
    ctx = ToolContext(
      session: Session(id: 's-s22', channel: 'cli', userKey: 'u1'),
      workspacePath: workspace.path,
    );
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
    dataDir.deleteSync(recursive: true);
  });

  SemanticCodeIndexer indexer({CodeEmbedder? embedder, int maxChunks = 6000}) =>
      SemanticCodeIndexer(
        workspaceRoot: workspace.path,
        dataDir: dataDir.path,
        embedder: embedder,
        maxChunks: maxChunks,
      );

  test('HashingCodeEmbedder deterministik dan mirip semantik-lexikal', () async {
    const emb = HashingCodeEmbedder();
    final a = await emb('class PaymentGateway retry');
    final b = await emb('class PaymentGateway retry ');
    final c = await emb('completely unrelated pineapple spaceship');
    expect(a.length, 256);
    expect(a, equals(b));
    double dot(List<double> x, List<double> y) {
      var s = 0.0;
      for (var i = 0; i < x.length; i++) {
        s += x[i] * y[i];
      }
      return s;
    }

    expect(dot(a, a), closeTo(1.0, 1e-9));
    expect(dot(a, b), greaterThan(dot(a, c)));
  });

  test('refresh membangun indeks persisten dan status melapor', () async {
    final ix = indexer();
    final stats = await ix.refresh();
    expect(stats['files'], greaterThanOrEqualTo(2));
    expect(stats['chunks'], greaterThanOrEqualTo(2));
    expect(stats['partial'], isFalse);
    expect(stats['embedder'], contains('hashing-256'));
    expect(File(ix.indexFilePath).existsSync(), isTrue);
    final meta = jsonDecode(
        File(ix.indexFilePath).readAsLinesSync().first) as Map<String, dynamic>;
    expect(meta['t'], 'meta');
    expect((meta['chunks'] as num).toInt(), stats['chunks']);

    final st = await ix.status(deep: true);
    expect(st['files'], greaterThanOrEqualTo(2));
    expect(st['stale_files'], 0);
  });

  test('refresh inkremental: file berubah di-embed ulang, file hilang dipangkas',
      () async {
    var embedCalls = 0;
    Future<List<double>> counting(String text) async {
      embedCalls++;
      return const HashingCodeEmbedder().call(text);
    }

    final ix = indexer(embedder: counting);
    await ix.refresh();
    final firstCalls = embedCalls;
    expect(firstCalls, greaterThanOrEqualTo(2));

    final stats2 = await ix.refresh();
    expect(stats2['reused_files'], greaterThanOrEqualTo(2));
    expect(stats2['reembedded_files'], 0);
    expect(embedCalls, firstCalls);

    File('${workspace.path}/lib/src/payment_gateway.dart')
        .writeAsStringSync('''
class PaymentGateway {
  int refund(String id) {
    return 2;
  }
}
''');
    File('${workspace.path}/lib/src/inventory_service.dart').deleteSync();
    final stats3 = await ix.refresh();
    expect(stats3['partial'], isFalse);
    expect(stats3['reused_files'], 0);
    expect(stats3['reembedded_files'], 1);
    final st = await ix.status();
    expect(st['files'], 1);
  });

  test('search hybrid menemukan chunk relevan; prefix path & limit bekerja',
      () async {
    final ix = indexer();
    await ix.refresh();
    final hits = await ix.search('payment gateway retry');
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.relPath, contains('payment_gateway'));
    expect(hits.first.hybrid, isTrue);

    final limited = await ix.search('payment gateway', limit: 1);
    expect(limited.length, 1);

    final filtered = await ix.search('payment retry', pathPrefix: 'lib/src');
    expect(filtered, isNotEmpty);
    final outside =
        await ix.search('payment retry', pathPrefix: 'nonexistent_dir');
    expect(outside, isEmpty);
  });

  test('query dim mismatch terhadap indeks turun ke BM25 (fail-soft jujur)',
      () async {
    var dim = 8;
    Future<List<double>> providerEmbed(String text) async =>
        List.filled(dim, 0.1);
    final builtIx = indexer(embedder: providerEmbed);
    final built = await builtIx.refresh();
    expect(built['embedder'], 'provider (memory.embed)');
    expect(built['dim'], 8);

    // Instansi baru membaca indeks persisten (dim 8) tapi embedder provider
    // kini mengembalikan dim 12 — cosine diabaikan, hasil tetap lewat BM25.
    dim = 12;
    final queryIx = indexer(embedder: providerEmbed);
    final hits = await queryIx.search('payment gateway retry');
    expect(hits, isNotEmpty);
    expect(hits.first.hybrid, isFalse);
  });

  test('tool code_semantic: search/status/invalid query', () async {
    final tool = SemanticCodeSearchTool(indexer: indexer());

    final invalid = await tool.run({'query': ''}, ctx);
    expect(invalid.isError, isTrue);

    final status = await tool.run({'query': 'x', 'mode': 'status'}, ctx);
    expect(status.isError, isFalse);
    expect(status.content, contains('code_semantic status'));

    final search = await tool.run({'query': 'payment gateway retry'}, ctx);
    expect(search.isError, isFalse);
    expect(search.content, contains('payment_gateway.dart'));

    final rebuild = await tool.run({'query': 'x', 'mode': 'rebuild'}, ctx);
    expect(rebuild.isError, isFalse);
    expect(rebuild.content, contains('rebuild'));
  });

  test('path di luar workspace ditolak (fail-closed)', () async {
    final tool = SemanticCodeSearchTool(indexer: indexer());
    final res = await tool.run({'query': 'x', 'path': '../../etc'}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('maxChunks membatasi ukuran indeks (partial jujur)', () async {
    for (var i = 0; i < 6; i++) {
      Directory('${workspace.path}/lib/src/m$i').createSync(recursive: true);
      File('${workspace.path}/lib/src/m$i/mod_$i.dart').writeAsStringSync('''
class Module$i {
  int value$i() => $i;
}
''');
    }
    final ix = indexer(maxChunks: 3);
    final stats = await ix.refresh();
    expect(stats['chunks'], 3);
    expect(stats['files'], 3);
    expect(stats['partial'], isTrue);
  });
}
