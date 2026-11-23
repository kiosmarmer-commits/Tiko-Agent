import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('katalog resep toolchain (F8.4)', () {
    test('setiap resep punya jalur provisioning (apt ATAU manual)', () {
      for (final r in kToolchainRecipes) {
        final provisionable =
            r.installableViaApt || (r.manualHint != null && r.manualHint!.trim().isNotEmpty);
        expect(provisionable, isTrue,
            reason: 'resep ${r.bin} harus punya aptPackages atau manualHint');
      }
    });

    test('setiap biner interpreter registry inti punya resep', () {
      final bins = kToolchainRecipes.map((r) => r.bin).toSet();
      for (final bin in ['python3', 'node', 'go', 'javac', 'gcc', 'g++', 'rustc', 'dart']) {
        expect(bins.contains(bin), isTrue, reason: 'resep $bin hilang');
      }
    });

    test('setiap biner interpreter registry F8.3b punya resep', () {
      final bins = kToolchainRecipes.map((r) => r.bin).toSet();
      for (final spec in LanguageRegistry.specs) {
        if (spec.name == 'brainfuck') continue;
        final bin = spec.interpreter;
        if (bin == null) continue;
        expect(bins.contains(bin), isTrue, reason: 'resep $bin (${spec.name}) hilang');
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
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
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
      expect(aptBins.contains('python3'), isFalse,
          reason: 'python3 ada di PATH mock, tidak boleh masuk plan');
      expect(aptBins.contains('gcc'), isTrue,
          reason: 'gcc tidak ada di PATH mock, tetap masuk plan');
      dir.deleteSync(recursive: true);
    });

    test('direktori PATH dengan titik dua diparsing semua segmen', () {
      final dirA = Directory.systemTemp
          .createTempSync('tiko_tc_a_');
      final dirB = Directory.systemTemp
          .createTempSync('tiko_tc_b_');
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
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
      final cmd = plan.aptCommand(asRoot: false);
      expect(cmd.first, 'sudo');
      expect(cmd.contains('apt-get'), isTrue);
      expect(cmd.contains('install'), isTrue);
      expect(cmd.contains('-y'), isTrue);
      expect(cmd.length, greaterThan(4));
    });

    test('tanpa sudo bila asRoot', () {
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
      final cmd = plan.aptCommand(asRoot: true);
      expect(cmd.first, 'apt-get');
    });

    test('iapakah tanpa duplikasi paket antar resep', () {
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
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
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
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
      final plan = buildToolchainPlan(environment: const {'PATH': '/nonexistent-tiko-8f2'});
      final result = await applyToolchainPlan(
        plan,
        confirm: (_) async => true,
        dryRun: true,
      );
      expect(result.success, isTrue);
      expect(result.ran, isFalse);
      expect(result.message, contains('apt-get'));
    });
  });
}
