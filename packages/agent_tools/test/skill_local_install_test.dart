import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const _skillMd = '''
---
name: halo lokal
description: Skill uji install lokal (E3).
triggers: ["halo"]
tools: []
version: 1
status: approved
---
## Langkah
- Balas salam dengan sopaan ramah.
''';

void main() {
  late Directory temp;
  late Directory skillsDir;
  late SkillLocalInstaller installer;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_sli_');
    skillsDir = Directory('${temp.path}/skills')..createSync(recursive: true);
    installer = SkillLocalInstaller(skillsDirectory: skillsDir.path);
  });

  tearDown(() async => temp.delete(recursive: true));

  test('install dari berkas markdown: status dipaksa draft + sha256 dicatat',
      () async {
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(_skillMd);
    final r = await installer.install(src.path);
    expect(r.slug, 'halo-lokal');
    expect(r.source, 'markdown');
    expect(r.sha256, sha256.convert(src.readAsBytesSync()).toString());

    final persisted = File(r.path).readAsStringSync();
    expect(persisted, contains('status: draft'));
    expect(persisted, contains('sha256: ${r.sha256}'));
  });

  test('install dari direktori berisi SKILL.md', () async {
    final src = Directory('${temp.path}/halo-lokal')..createSync();
    File('${src.path}/SKILL.md').writeAsStringSync(_skillMd);
    final r = await installer.install(src.path);
    expect(r.source, 'directory');
    expect(r.slug, 'halo-lokal');
    expect(File(r.path).existsSync(), isTrue);
  });

  test('install dari paket JSON tiko-skill-package (export D5)', () async {
    final skill = Skill(
      slug: 'paket-uji',
      name: 'paket uji',
      description: 'Skill untuk paket export D5.',
      body: '## Langkah\n- Lakukan sesuatu.',
      triggers: const ['paket'],
    );
    final pkg = SkillPackage.fromSkill(skill, instanceId: 'inst-1');
    final src = File('${temp.path}/paket-uji.json')
      ..writeAsStringSync(pkg.toJsonString());
    final r = await installer.install(src.path);
    expect(r.source, 'package');
    expect(r.slug, 'paket-uji');
    final persisted = File(r.path).readAsStringSync();
    expect(persisted, contains('status: draft'));
    expect(persisted, contains('name: paket uji'));
  });

  test('verifikasi SHA-256: cocok lolos, mismatch ditolak fail-closed',
      () async {
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(_skillMd);
    final digest = sha256.convert(src.readAsBytesSync()).toString();

    final ok = await installer.install(src.path, expectedSha256: digest);
    expect(ok.sha256, digest);

    // Hapus hasil install pertama agar collision tidak mengganggu.
    Directory('${skillsDir.path}/halo-lokal').deleteSync(recursive: true);

    expect(
      () => installer.install(src.path, expectedSha256: '0' * 64),
      throwsA(isA<SkillLocalInstallException>()),
    );
    // Tidak ada file yang tertulis setelah mismatch.
    expect(Directory('${skillsDir.path}/halo-lokal').existsSync(), isFalse);
  });

  test('collision: direktori tujuan yang sudah ada tidak pernah ditimpa',
      () async {
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(_skillMd);
    await installer.install(src.path);
    final existing =
        File('${skillsDir.path}/halo-lokal/SKILL.md').readAsStringSync();

    final src2 = File('${temp.path}/SKILL2.md')
      ..writeAsStringSync(_skillMd.replaceAll('uji install', 'uji LAIN'));
    expect(
      () => installer.install(src2.path),
      throwsA(isA<SkillLocalInstallException>()),
    );
    expect(
      File('${skillsDir.path}/halo-lokal/SKILL.md').readAsStringSync(),
      existing,
      reason: 'isi lama tidak boleh berubah',
    );
  });

  test('skill dengan rahasia ditolak (fail-closed)', () async {
    final malicious = _skillMd.replaceFirst(
      'Balas salam',
      'Gunakan api_key = sk-abcdef1234567890abcdef lalu Balas salam',
    );
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(malicious);
    expect(
      () => installer.install(src.path),
      throwsA(isA<SkillLocalInstallException>()),
    );
    expect(Directory('${skillsDir.path}/halo-lokal').existsSync(), isFalse);
  });

  test('sumber tidak ada / direktori tanpa SKILL.md / bukan frontmatter',
      () async {
    expect(
      () => installer.install('${temp.path}/tak-ada.md'),
      throwsA(isA<SkillLocalInstallException>()),
    );
    final emptyDir = Directory('${temp.path}/kosong')..createSync();
    expect(
      () => installer.install(emptyDir.path),
      throwsA(isA<SkillLocalInstallException>()),
    );
    final noFm = File('${temp.path}/plain.md')..writeAsStringSync('tanpa fm');
    expect(
      () => installer.install(noFm.path),
      throwsA(isA<SkillLocalInstallException>()),
    );
  });

  test('onChanged dipanggil; kegagalan onChanged tidak menggagalkan install',
      () async {
    var called = 0;
    final failing = SkillLocalInstaller(
      skillsDirectory: skillsDir.path,
      onChanged: (_) async => throw StateError('hot-reload mati'),
    );
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(_skillMd);
    final r = await failing.install(src.path);
    expect(r.slug, 'halo-lokal');

    final ok = SkillLocalInstaller(
      skillsDirectory: skillsDir.parent.path,
      onChanged: (_) async => called++,
    );
    final src2 = File('${temp.path}/SKILL3.md')
      ..writeAsStringSync(_skillMd.replaceAll('halo lokal', 'halo kedua'));
    await ok.install(src2.path);
    expect(called, 1);
  });

  test('sha256 frontmatter tidak diduplikasi bila sudah ada', () async {
    final withSha = _skillMd.replaceFirst(
      'version: 1',
      'version: 1\nsha256: deadbeef',
    );
    final src = File('${temp.path}/SKILL.md')..writeAsStringSync(withSha);
    final r = await installer.install(src.path);
    final persisted = File(r.path).readAsStringSync();
    expect('deadbeef'.allMatches(persisted).length, 1);
    expect(persisted.contains(r.sha256), isFalse,
        reason: 'sha256 lama tidak ditimpa diam-diam');
  });
}
