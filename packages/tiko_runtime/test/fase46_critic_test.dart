import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-critic', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

void main() {
  late String workspace;

  setUp(() async {
    workspace = await Directory.systemTemp
        .createTemp('critic_test')
        .then((d) => d.path);
    await Directory('$workspace/lib').create(recursive: true);
    await File('$workspace/lib/util.dart').writeAsString('void util() {}\n');
  });

  tearDown(() async {
    await Directory(workspace).delete(recursive: true);
  });

  test('CRITIC-1: file path yang ada di workspace \u2192 verified', () async {
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: 'Saya menambahkan helper baru di lib/util.dart. Silakan cek.',
      workspaceRoot: workspace,
    );
    final fileFindings = report.findings
        .where((f) => f.kind == 'file_path')
        .toList();
    expect(fileFindings, hasLength(1));
    expect(fileFindings.single.verdict, 'verified');
    expect(report.ok, isTrue);
  });

  test('CRITIC-2: klaim sukses tanpa bukti \u2192 flagged unverified', () async {
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: 'Semua test lulus dan implementasi sudah selesai.',
      workspaceRoot: workspace,
    );
    expect(report.ok, isFalse);
    expect(report.flagged, isNotEmpty);
    expect(report.flagged.first.kind, 'success_assertion');
  });

  test('CRITIC-3: path di luar workspace / tidak ada \u2192 unverified', () async {
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: 'Perubahan ada di file src/tidak_ada.dart.',
      workspaceRoot: workspace,
    );
    expect(report.ok, isFalse);
    expect(report.flagged.first.kind, 'file_path');
  });

  test('CRITIC-4: klaim sukses dengan file valid \u2192 verified', () async {
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: 'Implementasi sudah selesai — helper ditambahkan di '
          'lib/util.dart.',
      workspaceRoot: workspace,
    );
    expect(report.ok, isTrue);
  });

  test('CRITIC-5: mode llm \u2014 judge fail menambah temuan, judge pass tidak',
      () async {
    const criticFail = FinalClaimCritic(
      judge: _judgeFail,
    );
    final reportFail = await criticFail.review(
      answer: 'Semua test lulus.',
      workspaceRoot: workspace,
    );
    expect(reportFail.flagged.any((f) => f.kind == 'llm'), isTrue);

    const criticPass = FinalClaimCritic(
      judge: _judgePass,
    );
    final reportPass = await criticPass.review(
      answer: 'Semua test lulus.',
      workspaceRoot: workspace,
    );
    expect(reportPass.flagged.any((f) => f.kind == 'llm'), isFalse);
  });

  test('CRITIC-6: tool critic \u2014 review manual + markdown laporan', () async {
    final tool = const CriticTool();
    final result = await tool.run(
      {'text': 'Semua test lulus. File lib/util.dart sudah diperbarui.'},
      _ctx(workspace),
    );
    expect(result.isError, isFalse);
    expect(result.content, contains('Critic review'));
  });

  test('CRITIC-7: never-raises \u2014 PathSafety gagal tetap menghasilkan laporan',
      () async {
    const critic = FinalClaimCritic();
    final report = await critic.review(
      answer: 'Konfigurasi sudah selesai dan berhasil.',
      workspaceRoot: '/tidak/ada/root-ini',
    );
    expect(report.ok, isFalse);
    expect(report.findings, isNotEmpty);
  });
}

Future<String?> _judgeFail(String prompt) async => 'VERDICT: fail\nREASON: tidak ada bukti';
Future<String?> _judgePass(String prompt) async => 'VERDICT: pass\nREASON: ok';
