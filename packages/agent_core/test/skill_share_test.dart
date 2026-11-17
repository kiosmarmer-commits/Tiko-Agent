import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

Skill _makeSkill({
  String slug = 'deploy-checklist',
  String body = '1. Validasi config.\n2. Deploy.\n3. Cek health.',
  int uses = 10,
  int successes = 8,
}) {
  final skill = Skill(
    slug: slug,
    name: 'Deploy Checklist',
    description: 'Prosedur deploy produksi yang aman',
    body: body,
    triggers: ['deploy produksi'],
    tools: const ['shell'],
    version: 2,
    uses: uses,
    successes: successes,
  );
  skill.status = SkillStatus.approved;
  skill.approvedBy = 'alice';
  skill.goldenScore = 4;
  skill.goldenTotal = 5;
  return skill;
}

DateTime fixedTime(int h) => DateTime.utc(2026, 11, 17, h);

void main() {
  group('SkillPackage', () {
    test('fromSkill: redaksi fail-closed pada konten berbahaya', () {
      final secretSkill = _makeSkill(
        body: 'Gunakan API key: api_key: sk-abcdefghijklmnopqrstuvwx',
      );
      expect(
        () => SkillPackage.fromSkill(secretSkill, clock: fixedTime(1)),
        throwsA(isA<SkillPackageException>()),
      );
    });

    test('fromSkill: trust & path mesin TIDAK ikut diekspor', () {
      final pkg = SkillPackage.fromSkill(
        _makeSkill(),
        instanceId: 'hp-budi',
        clock: fixedTime(1),
      );
      final json = pkg.toJson();
      final skillJson = json['skill'] as Map<String, dynamic>;
      expect(json['format'], 'tiko-skill-package');
      expect(json['format_version'], 1);
      expect(json['instance_id'], 'hp-budi');
      expect(skillJson.containsKey('status'), isFalse,
          reason: 'status tidak ikut (trust direset saat import)');
      expect(skillJson.containsKey('approved_by'), isFalse);
      expect(skillJson.containsKey('path'), isFalse);
      expect(skillJson.containsKey('sha256'), isFalse);
      expect((skillJson['metrics'] as Map)['uses'], 10);
    });

    test('round-trip: export → parse → toSkill (draft, metrik utuh)',
        () async {
      final pkg = SkillPackage.fromSkill(_makeSkill(), clock: fixedTime(1));
      final json = pkg.toJsonString();
      final parsed = SkillPackage.parse(json);
      expect(parsed.slug, 'deploy-checklist');
      expect(parsed.version, 2);
      expect(parsed.metrics!.uses, 10);
      expect(parsed.metrics!.successes, 8);
      final skill = parsed.toSkill();
      expect(skill.status, SkillStatus.draft,
          reason: 'impor selalu draft (trust tidak ikut)');
      expect(skill.approvedBy, isNull);
      expect(skill.uses, 10);
      expect(skill.successes, 8);
      expect(skill.body, contains('Validasi config'));
    });

    test('parse: format/version salah ditolak', () {
      expect(
        () => SkillPackage.parse({'format': 'other', 'format_version': 1}),
        throwsA(isA<SkillPackageException>()),
      );
      expect(
        () => SkillPackage.parse({
              'format': skillPackageFormat,
              'format_version': 99,
              'exported_at': '2026-11-17T00:00:00Z',
              'skill': {},
            }),
        throwsA(isA<SkillPackageException>()),
      );
    });

    test('parse: field wajib hilang / tidak valid ditolak', () {
      Map<String, dynamic> base(Map<String, dynamic> skill) => {
            'format': skillPackageFormat,
            'format_version': 1,
            'exported_at': '2026-11-17T00:00:00Z',
            'skill': skill,
          };
      expect(
        () => SkillPackage.parse(base({
              'slug': 'ok',
              'name': '',
              'description': 'x',
              'body': 'y',
            })),
        throwsA(isA<SkillPackageException>()),
      );
      expect(
        () => SkillPackage.parse(base({
              'slug': 'Bad_Slug!',
              'name': 'n',
              'description': 'x',
              'body': 'y',
            })),
        throwsA(isA<SkillPackageException>()),
      );
      expect(
        () => SkillPackage.parse(base({
              'slug': 'ok',
              'name': 'n',
              'description': 'x',
              'body': 'y',
              'version': 0,
            })),
        throwsA(isA<SkillPackageException>()),
      );
      expect(
        () => SkillPackage.parse('bukan json [[[('),
        throwsA(isA<SkillPackageException>()),
      );
    });

    test('parse: metrik tidak konsisten ditolak (successes > uses)', () {
      expect(
        () => SkillPackage.parse({
              'format': skillPackageFormat,
              'format_version': 1,
              'exported_at': '2026-11-17T00:00:00Z',
              'skill': {
                'slug': 'ok',
                'name': 'n',
                'description': 'x',
                'body': 'y',
                'metrics': {
                  'uses': 5,
                  'successes': 9,
                  'golden_score': 0,
                  'golden_total': 0,
                  'updated_at': '2026-11-17T00:00:00Z',
                },
              },
            }),
        throwsA(isA<SkillPackageException>()),
      );
    });

    test('parse: konten impor berbahaya ditolak (redaksi dua arah)', () {
      expect(
        () => SkillPackage.parse({
              'format': skillPackageFormat,
              'format_version': 1,
              'exported_at': '2026-11-17T00:00:00Z',
              'skill': {
                'slug': 'ok',
                'name': 'n',
                'description': 'x',
                'body': '-----BEGIN RSA PRIVATE KEY-----',
              },
            }),
        throwsA(isA<SkillPackageException>()),
      );
    });
  });

  group('SkillMetricsMerger (LWW-Register)', () {
    test('remote lebih baru → remote menang', () {
      final result = SkillMetricsMerger.merge(
        local: SkillMetricsSnapshot(
          uses: 3, successes: 2,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(1),
        ),
        remote: SkillMetricsSnapshot(
          uses: 50, successes: 45,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(5),
        ),
      );
      expect(result.winner, 'remote');
      expect(result.metrics.uses, 50);
    });

    test('local lebih baru → local menang', () {
      final result = SkillMetricsMerger.merge(
        local: SkillMetricsSnapshot(
          uses: 30, successes: 25,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(9),
        ),
        remote: SkillMetricsSnapshot(
          uses: 50, successes: 45,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(5),
        ),
      );
      expect(result.winner, 'local');
      expect(result.metrics.uses, 30);
    });

    test('timestamp sama → local menang (deterministik, didokumentasikan)',
        () {
      final result = SkillMetricsMerger.merge(
        local: SkillMetricsSnapshot(
          uses: 1, successes: 1,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(3),
        ),
        remote: SkillMetricsSnapshot(
          uses: 2, successes: 2,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(3),
        ),
      );
      expect(result.winner, 'local');
    });

    test('local null (belum ada metrik) → remote menang', () {
      final result = SkillMetricsMerger.merge(
        local: null,
        remote: SkillMetricsSnapshot(
          uses: 7, successes: 6,
          goldenScore: 0, goldenTotal: 0,
          updatedAt: fixedTime(2),
        ),
      );
      expect(result.winner, 'remote');
      expect(result.metrics.uses, 7);
    });
  });

  group('SkillShareTool', () {
    Future<(ToolResult, SkillRegistry, String)> runTool(
      Map<String, dynamic> args, {
      SkillRegistry? registry,
      String? skillsRoot,
    }) async {
      final reg = registry ?? SkillRegistry();
      final tool = SkillShareTool(
        registry: reg,
        skillsRoot: skillsRoot,
        instanceId: 'test-instance',
        clock: () => fixedTime(10),
      );
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: '/tmp',
      );
      return (await tool.run(args, ctx), reg, skillsRoot ?? '');
    }

    test('metadata tool', () {
      final tool = SkillShareTool(registry: SkillRegistry());
      expect(tool.spec.name, 'skill_share');
      expect(tool.spec.risk, 'medium');
    });

    test('export: paket JSON valid, bisa di-parse balik', () async {
      final reg = SkillRegistry()..register(_makeSkill());
      final (result, _, _) = await runTool(
        {'action': 'export', 'slug': 'deploy-checklist'},
        registry: reg,
      );
      expect(result.isError, isFalse);
      final parsed = SkillPackage.parse(result.content);
      expect(parsed.slug, 'deploy-checklist');
      expect(parsed.instanceId, 'test-instance');
    });

    test('export: slug tidak ada → error', () async {
      final (result, _, _) = await runTool(
        {'action': 'export', 'slug': 'nggak-ada'},
      );
      expect(result.isError, isTrue);
    });

    test('export: skill berbahaya → ditolak fail-closed', () async {
      final reg = SkillRegistry()
        ..register(_makeSkill(
          body: 'password: rahasia123 lalu jalankan',
        ));
      final (result, _, _) = await runTool(
        {'action': 'export', 'slug': 'deploy-checklist'},
        registry: reg,
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('tidak layak diekspor'));
    });

    test('import: skill baru terdaftar sebagai draft + persist ke disk',
        () async {
      final root = Directory.systemTemp.createTempSync('tiko-skillshare-');
      addTearDown(() => root.deleteSync(recursive: true));
      final pkg = SkillPackage.fromSkill(_makeSkill(), clock: fixedTime(1));

      final (result, reg, _) = await runTool(
        {'action': 'import', 'package': pkg.toJsonString()},
        skillsRoot: root.path,
      );
      expect(result.isError, isFalse);
      expect(result.content, contains('status=draft'));
      expect(result.content, contains('Tersimpan ke skills/'));

      final imported = reg.get('deploy-checklist');
      expect(imported, isNotNull);
      expect(imported!.status, SkillStatus.draft);
      expect(imported.uses, 10);
      expect(File('${root.path}/deploy-checklist/SKILL.md').existsSync(),
          isTrue);
      // Reload dari disk tetap valid (markdown round-trip).
      final reg2 = SkillRegistry();
      final n = await reg2.loadFromDirectory(root.path);
      expect(n, 1);
    });

    test('import: slug bentrok dengan isi berbeda → error, tanpa timpa',
        () async {
      final root = Directory.systemTemp.createTempSync('tiko-skillshare-');
      addTearDown(() => root.deleteSync(recursive: true));
      final localSkill = _makeSkill(body: 'Konten lokal versi A');
      final reg = SkillRegistry()..register(localSkill);
      final pkg = SkillPackage.fromSkill(
        _makeSkill(body: 'Konten luar versi B'),
        clock: fixedTime(1),
      );

      final (result, reg2, _) = await runTool(
        {'action': 'import', 'package': pkg.toJsonString()},
        registry: reg,
        skillsRoot: root.path,
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('as_slug'));
      expect(reg2.get('deploy-checklist')!.body, 'Konten lokal versi A');
      expect(Directory('${root.path}/deploy-checklist').existsSync(), isFalse);
    });

    test('import: slug bentrok isi sama → merge metrik LWW', () async {
      final localSkill = _makeSkill(uses: 30, successes: 25);
      final reg = SkillRegistry()..register(localSkill);
      // Paket dari instance lain: lebih lama → local menang.
      final pkgOld = SkillPackage.fromSkill(
        _makeSkill(uses: 50, successes: 45),
        clock: fixedTime(1),
      );
      final (r1, reg1, _) = await runTool(
        {'action': 'import', 'package': pkgOld.toJsonString()},
        registry: reg,
      );
      expect(r1.isError, isFalse);
      expect(r1.content, contains('merge LWW → local'));
      expect(reg1.get('deploy-checklist')!.uses, 30);

      // Paket lebih baru → remote menang.
      final pkgNew = SkillPackage.fromSkill(
        _makeSkill(uses: 99, successes: 90),
        clock: fixedTime(20),
      );
      final (r2, reg2, _) = await runTool(
        {'action': 'import', 'package': pkgNew.toJsonString()},
        registry: reg,
      );
      expect(r2.isError, isFalse);
      expect(r2.content, contains('merge LWW → remote'));
      final merged = reg2.get('deploy-checklist')!;
      expect(merged.uses, 99);
      expect(merged.successes, 90);
      expect(merged.status, SkillStatus.approved,
          reason: 'skill yang sudah ada lokal tidak direset statusnya');
    });

    test('import: as_slug menghindari bentrok', () async {
      final reg = SkillRegistry()..register(_makeSkill(body: 'lokal A'));
      final pkg = SkillPackage.fromSkill(
        _makeSkill(body: 'luar B'),
        clock: fixedTime(1),
      );
      final (result, reg2, _) = await runTool(
        {
          'action': 'import',
          'package': pkg.toJsonString(),
          'as_slug': 'deploy-checklist-remote',
        },
        registry: reg,
      );
      expect(result.isError, isFalse);
      expect(reg2.get('deploy-checklist-remote'), isNotNull);
      expect(reg2.get('deploy-checklist-remote')!.body, 'luar B');
      expect(reg2.get('deploy-checklist')!.body, 'lokal A');
    });

    test('import: paket rusak → error jelas', () async {
      final (result, _, _) = await runTool(
        {'action': 'import', 'package': '{bukan json'},
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('SkillPackageException'));
    });

    test('import: package kosong → error', () async {
      final (result, _, _) = await runTool({'action': 'import'});
      expect(result.isError, isTrue);
    });

    test('aksi tidak dikenal → error', () async {
      final (result, _, _) = await runTool({'action': 'sync'});
      expect(result.isError, isTrue);
    });
  });
}
