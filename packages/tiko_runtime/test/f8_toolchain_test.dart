import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('katalog resep toolchain (F8.4)', () {
    test('setiap resep punya jalur provisioning (apt ATAU manual)', () {
      for (final r in kToolchainRecipes) {
        final provisionable =
            r.installableViaApt ||
            (r.manualHint != null && r.manualHint!.trim().isNotEmpty);
        expect(
          provisionable,
          isTrue,
          reason: 'resep ${r.bin} harus punya aptPackages atau manualHint',
        );
      }
    });

    test('setiap biner interpreter registry inti punya resep', () {
      final bins = kToolchainRecipes.map((r) => r.bin).toSet();
      for (final bin in [
        'python3',
        'node',
        'go',
        'javac',
        'gcc',
        'g++',
        'rustc',
        'dart',
      ]) {
        expect(bins.contains(bin), isTrue, reason: 'resep $bin hilang');
      }
    });

    test('setiap biner interpreter registry F8.3b punya resep', () {
      final bins = kToolchainRecipes.map((r) => r.bin).toSet();
      for (final spec in LanguageRegistry.specs) {
        if (spec.name == 'brainfuck') continue;
        final bin = spec.interpreter;
        if (bin == null) continue;
        expect(
          bins.contains(bin),
          isTrue,
          reason: 'resep $bin (${spec.name}) hilang',
        );
      }
    });

    test('setiap aptPackages tidak kosong bila installableViaApt', () {
      for (final r in kToolchainRecipes) {
        if (r.installableViaApt) {
          expect(r.aptPackages, isNotEmpty, reason: 'resep ${r.bin}');
        }
      }
    });
  });

  group('buildToolchainPlan', () {
    test('PATH kosong -> semua resep missing, terbagi apt vs manual', () {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      expect(plan.empty, isFalse);
      expect(plan.aptInstallable, isNotEmpty);
      expect(plan.manual, isNotEmpty);
      final aptBins = plan.aptInstallable.map((r) => r.bin).toSet();
      expect(aptBins, containsAll(['python3', 'node', 'gcc', 'rustc']));
      final manualBins = plan.manual.map((r) => r.bin).toSet();
      expect(manualBins, containsAll(['dart', 'swift', 'zig', 'pwsh']));
    });

    test('PATH berisi biner mock -> resep tersebut tidak masuk plan', () {
      final dir = Directory.systemTemp.createTempSync('tiko_toolchain_f84_');
      File('${dir.path}/python3').writeAsStringSync('#!/bin/sh\n');
      final plan = buildToolchainPlan(environment: {'PATH': dir.path});
      final aptBins = plan.aptInstallable.map((r) => r.bin).toSet();
      expect(
        aptBins.contains('python3'),
        isFalse,
        reason: 'python3 ada di PATH mock, tidak boleh masuk plan',
      );
      expect(
        aptBins.contains('gcc'),
        isTrue,
        reason: 'gcc tidak ada di PATH mock, tetap masuk plan',
      );
      dir.deleteSync(recursive: true);
    });

    test('direktori PATH dengan titik dua diparsing semua segmen', () {
      final dirA = Directory.systemTemp.createTempSync('tiko_tc_a_');
      final dirB = Directory.systemTemp.createTempSync('tiko_tc_b_');
      File('${dirB.path}/node').writeAsStringSync('#!/bin/sh\n');
      final plan = buildToolchainPlan(
        environment: {'PATH': '${dirA.path}:${dirB.path}'},
      );
      final aptBins = plan.aptInstallable.map((r) => r.bin).toSet();
      expect(aptBins.contains('node'), isFalse);
      expect(aptBins.contains('python3'), isTrue);
      dirA.deleteSync(recursive: true);
      dirB.deleteSync(recursive: true);
    });
  });

  group('ToolchainPlan.aptCommand', () {
    test('group install satu command, sudo bila non-root', () {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      final cmd = plan.aptCommand(asRoot: false);
      expect(cmd.first, 'sudo');
      expect(cmd.contains('apt-get'), isTrue);
      expect(cmd.contains('install'), isTrue);
      expect(cmd.contains('-y'), isTrue);
      expect(cmd.length, greaterThan(4));
    });

    test('tanpa sudo bila asRoot', () {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      final cmd = plan.aptCommand(asRoot: true);
      expect(cmd.first, 'apt-get');
    });

    test('iapakah tanpa duplikasi paket antar resep', () {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      final pkgs = plan.aptCommand(asRoot: true).sublist(3);
      expect(pkgs.toSet().length, pkgs.length, reason: 'paket diduplikasi');
    });
  });

  group('applyToolchainPlan', () {
    test('plan kosong -> success tanpa menjalankan apa pun', () async {
      final result = await applyToolchainPlan(
        const ToolchainPlan(),
        confirm: (_) async => true,
      );
      expect(result.success, isTrue);
      expect(result.ran, isFalse);
    });

    test('confirm=false -> dibatalkan, tidak menjalankan instalasi', () async {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      var asked = false;
      final result = await applyToolchainPlan(
        plan,
        confirm: (_) async {
          asked = true;
          return false;
        },
      );
      expect(asked, isTrue, reason: 'human-in-loop harus ditanya dulu');
      expect(result.success, isFalse);
      expect(result.ran, isFalse);
      expect(result.message, contains('dibatalkan'));
    });

    test('dryRun=true -> mencetak command tanpa menjalankan apt-get', () async {
      final plan = buildToolchainPlan(
        environment: const {'PATH': '/nonexistent-tiko-8f2'},
      );
      final result = await applyToolchainPlan(
        plan,
        confirm: (_) async => true,
        dryRun: true,
      );
      expect(result.success, isTrue);
      expect(result.ran, isFalse);
      expect(result.message, contains('apt-get'));
    });

    test('parseUnavailableAptPackages memparsing pola error apt distro', () {
      final output = [
        "Note, selecting 'gambas3-scripter' instead of 'gambas3-script'",
        'Package smlnj is not available, but is referred to by another package.',
        'E: Unable to locate package gnu-smalltalk',
        'E: Unable to locate package freebasic',
        "E: Package 'smlnj' has no installation candidate",
      ].join('\n');
      final missing = parseUnavailableAptPackages(output);
      expect(missing.toSet(), {'gnu-smalltalk', 'freebasic', 'smlnj'});
    });
    test(
      'probe menemukan semua paket tak tersedia -> instalasi tidak jalan',
      () async {
        const plan = ToolchainPlan(
          aptInstallable: [
            ToolchainRecipe(
              bin: 'gst',
              languages: 'smalltalk',
              aptPackages: ['gnu-smalltalk'],
            ),
            ToolchainRecipe(
              bin: 'fbc',
              languages: 'freebasic',
              aptPackages: ['freebasic'],
            ),
            ToolchainRecipe(
              bin: 'sml',
              languages: 'sml',
              aptPackages: ['smlnj'],
            ),
          ],
        );
        ToolchainProcOut probe(String exe, List<String> args) {
          expect('$exe ${args.join(" ")}', contains('apt-get'));
          expect(args.contains('--dry-run'), isTrue);
          final out = [
            'E: Unable to locate package gnu-smalltalk',
            'E: Unable to locate package freebasic',
            "E: Package 'smlnj' has no installation candidate",
          ].join('\n');
          return ToolchainProcOut(100, out);
        }

        var spawnCalls = 0;
        final result = await applyToolchainPlan(
          plan,
          confirm: (_) async => true,
          procRunner: (exe, args) async => probe(exe, args),
          spawnRunner: (argv) async {
            spawnCalls++;
            return 0;
          },
        );
        expect(
          spawnCalls,
          0,
          reason: 'tidak ada paket tersedia, instalasi tidak boleh jalan',
        );
        expect(result.success, isFalse);
        expect(result.ran, isTrue);
        expect(result.message, contains('gnu-smalltalk'));
        expect(result.message, contains('freebasic'));
        expect(result.message, contains('smlnj'));
      },
    );
    test(
      'probe parsial -> hanya paket tersedia yang dipasang, skipped dilaporkan',
      () async {
        const plan = ToolchainPlan(
          aptInstallable: [
            ToolchainRecipe(
              bin: 'gst',
              languages: 'smalltalk',
              aptPackages: ['gnu-smalltalk'],
            ),
            ToolchainRecipe(
              bin: 'lua',
              languages: 'lua',
              aptPackages: ['lua5.4'],
            ),
          ],
        );
        ToolchainProcOut probe(String exe, List<String> args) {
          return const ToolchainProcOut(
            100,
            'E: Unable to locate package gnu-smalltalk\n',
          );
        }

        final spawnCalls = <List<String>>[];
        final result = await applyToolchainPlan(
          plan,
          confirm: (_) async => true,
          procRunner: (exe, args) async => probe(exe, args),
          spawnRunner: (argv) async {
            spawnCalls.add(argv);
            return 0;
          },
        );
        expect(result.success, isTrue);
        expect(spawnCalls.length, 1, reason: 'batch tunggal tanpa fallback');
        expect(spawnCalls.first.join(' '), contains('lua5.4'));
        expect(spawnCalls.first.join(' '), isNot(contains('gnu-smalltalk')));
        expect(result.message, contains('Dilewati'));
        expect(result.message, contains('gnu-smalltalk'));
      },
    );
    test('batch gagal -> fallback per-paket, paket gagal dilaporkan', () async {
      const plan = ToolchainPlan(
        aptInstallable: [
          ToolchainRecipe(
            bin: 'lua',
            languages: 'lua',
            aptPackages: ['lua5.4'],
          ),
          ToolchainRecipe(
            bin: 'ruby',
            languages: 'ruby',
            aptPackages: ['ruby'],
          ),
          ToolchainRecipe(bin: 'nim', languages: 'nim', aptPackages: ['nim']),
        ],
      );
      final probe = ToolchainProcOut(0, '');
      final spawnCalls = <List<String>>[];
      final result = await applyToolchainPlan(
        plan,
        confirm: (_) async => true,
        procRunner: (exe, args) async => probe,
        spawnRunner: (argv) {
          spawnCalls.add(argv);
          if (argv.length > 5) return Future<int>.value(100);
          final breakPkg = argv.contains('ruby') || argv.contains('nim');
          return Future<int>.value(breakPkg ? 100 : 0);
        },
      );
      final batchCall = spawnCalls.first;
      final perPkg = spawnCalls.skip(1).toList();
      expect(
        batchCall.length,
        greaterThan(5),
        reason: 'panggilan pertama adalah batch lengkap tanpa --dry-run',
      );
      expect(batchCall.contains('--dry-run'), isFalse);
      expect(
        perPkg.length,
        3,
        reason: 'fallback per-paket harus mencoba semua paket tersedia',
      );
      expect(result.success, isFalse);
      expect(result.message, contains('sebagian berhasil'));
      expect(result.message, contains('gagal'));
      expect(result.message, contains('lua5.4'));
    });
    test(
      'probe melempar ProcessException -> lanjut instalasi full list',
      () async {
        const plan = ToolchainPlan(
          aptInstallable: [
            ToolchainRecipe(
              bin: 'lua',
              languages: 'lua',
              aptPackages: ['lua5.4'],
            ),
            ToolchainRecipe(
              bin: 'ruby',
              languages: 'ruby',
              aptPackages: ['ruby'],
            ),
          ],
        );
        final spawnCalls = <List<String>>[];
        final result = await applyToolchainPlan(
          plan,
          confirm: (_) async => true,
          procRunner: (exe, args) async {
            throw const ProcessException('apt-get', ['install'], 'tidak ada');
          },
          spawnRunner: (argv) async {
            spawnCalls.add(argv);
            return 0;
          },
        );
        expect(
          result.success,
          isTrue,
          reason: 'probe gagal bukan alasan memblokir instalasi',
        );
        expect(spawnCalls.length, 1);
        expect(spawnCalls.first.join(' '), contains('lua5.4'));
        expect(spawnCalls.first.join(' '), contains('ruby'));
      },
    );
  });
}
