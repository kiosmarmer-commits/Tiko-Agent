import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_flutter/daemon/desktop_daemon.dart';

void main() {
  group('DesktopDaemon (self-contained bootstrap)', () {
    test('agentHome menghormati TIKO_HOME dan fallback ~', () {
      final home = DesktopDaemon.agentHome(homeOverride: '/tmp/tiko-home-x');
      expect(home, '/tmp/tiko-home-x');
      // Tanpa override: ~/.tiko-agent di bawah HOME/USERPROFILE.
      final fallback = DesktopDaemon.agentHome();
      final userHome = Platform.isWindows
          ? (Platform.environment['USERPROFILE'] ?? '')
          : (Platform.environment['HOME'] ?? '');
      if (userHome.isNotEmpty) {
        expect(fallback, endsWith('.tiko-agent'));
      }
    });

    test('ensureConfig menulis config bootstrap minimal sekali', () {
      final dir = Directory.systemTemp.createTempSync('tiko_daemon_cfg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = DesktopDaemon.ensureConfig(dir.path);
      final f = File(path);
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), contains('default_chat: mock'));
      // Panggilan kedua tidak menimpa (idempotent).
      File(path).writeAsStringSync('providers: {}\n');
      DesktopDaemon.ensureConfig(dir.path);
      expect(f.readAsStringSync(), 'providers: {}\n');
    });

    test('readToken menolak token terlalu pendek dan file hilang', () {
      final dir = Directory.systemTemp.createTempSync('tiko_daemon_tok');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(DesktopDaemon.readToken(dir.path), isNull);
      final dataDir = Directory('${dir.path}/data')..createSync(recursive: true);
      File('${dataDir.path}/api.token').writeAsStringSync('short\n');
      expect(DesktopDaemon.readToken(dir.path), isNull);
      final long = List.filled(32, 'a').join();
      File('${dataDir.path}/api.token').writeAsStringSync('$long\n');
      expect(DesktopDaemon.readToken(dir.path), long);
    });

    test('findAgentdBinary menemukan binary via override', () {
      final dir = Directory.systemTemp.createTempSync('tiko_daemon_bin');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bin = File('${dir.path}/agentd')..writeAsStringSync('#!/bin/sh\n');
      expect(DesktopDaemon.findAgentdBinary(binaryOverride: bin.path), bin.path);
      expect(
        DesktopDaemon.findAgentdBinary(binaryOverride: '${dir.path}/nope'),
        isNull,
      );
    });

    test('health false untuk port mati', () async {
      final ok = await DesktopDaemon.health('http://127.0.0.1:1');
      expect(ok, isFalse);
    });

    test('ensure di platform non-desktop mengembalikan null', () async {
      // Pada runner CI (linux) isDesktopPlatform true, jadi test ini hanya
      // memverifikasi kontrak ketika bukan desktop.
      if (DesktopDaemon.isDesktopPlatform) return;
      expect(await DesktopDaemon.ensure(), isNull);
    });

    test('ensure reuse: daemon mock sehat + token valid', () async {
      if (!DesktopDaemon.isDesktopPlatform) return;
      final dir = Directory.systemTemp.createTempSync('tiko_daemon_reuse');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dataDir = Directory('${dir.path}/data')..createSync(recursive: true);
      final long = List.filled(40, 'b').join();
      File('${dataDir.path}/api.token').writeAsStringSync('$long\n');
      // Mock daemon HTTP di port acak.
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((req) async {
        req.response.write('{"ok":true}');
        await req.response.close();
      });
      final conn = await DesktopDaemon.ensure(
        homeOverride: dir.path,
        baseOverride: 'http://127.0.0.1:${server.port}',
      );
      expect(conn, isNotNull);
      expect(conn!.mode, 'reuse');
      expect(conn.token, long);
    });

    test('ensure gagal graceful tanpa binary (spawn path tidak tersedia)',
        () async {
      if (!DesktopDaemon.isDesktopPlatform) return;
      final dir = Directory.systemTemp.createTempSync('tiko_daemon_nobin');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Port pasti mati + binary override tidak ada → null tanpa throw.
      final conn = await DesktopDaemon.ensure(
        homeOverride: dir.path,
        binaryOverride: '${dir.path}/tidak-ada',
        baseOverride: 'http://127.0.0.1:1',
      );
      expect(conn, isNull);
    });
  });
}
