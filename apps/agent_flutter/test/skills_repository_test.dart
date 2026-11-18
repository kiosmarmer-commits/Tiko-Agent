import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Skills Manager (GUI-P1-03) di atas fake agentd: lifecycle gate
/// evaluate/approve/rollback, feedback telemetry, dan error model typed.
void main() {
  group('GUI-P1-03: repository skills', () {
    late _ApiServer fake;
    late AgentApiClient client;
    late HttpAgentRepository repo;

    setUp(() async {
      fake = _ApiServer();
      client = AgentApiClient(baseUrl: await fake.start(), token: 't');
      repo = HttpAgentRepository(client);
    });

    tearDown(() async {
      client.close();
      await fake.close();
    });

    test('skills() mengembalikan List<SkillItem> dengan metrics ledger',
        () async {
      final skills = await repo.skills();
      expect(skills.single.slug, 'catatan-keuangan');
      expect(skills.single.status, 'approved');
      expect(skills.single.positive, 7);
      expect(skills.single.negative, 2);
      expect(skills.single.uses, 12);
      expect(skills.single.feedbackAllowed, isTrue);
    });

    test('skillFeedback() mengirim positif(bool) dan mencatat ke gate',
        () async {
      final ok = await repo.skillFeedback('catatan-keuangan', true);
      expect(ok, isTrue);
      expect(fake.lastFeedbackSlug, 'catatan-keuangan');
      expect(fake.lastFeedbackBody['positive'], isTrue);
    });

    test('feedback ke skill draft ditolak backend (error di payload 200)',
        () async {
      fake.nextFeedbackError =
          'skill netral is draft; feedback applies to active skills only';
      try {
        await repo.skillFeedback('netral', true);
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.invalidRequest);
        expect(e.message, contains('is draft'));
      }
    });

    test('evaluateSkill() mengembalikan SkillGateOutcome (scan + golden)',
        () async {
      final outcome = await repo.evaluateSkill('catatan-keuangan');
      expect(outcome.ok, isTrue);
      expect(outcome.stage, 'evaluate');
      expect(outcome.findings, isEmpty);
    });

    test('approveSkill() gagal gate mengembalikan findings tanpa ok', () async {
      final outcome = await repo.approveSkill('rapat');
      expect(outcome.ok, isFalse);
      expect(outcome.findings, contains('golden gagal'));
      expect(outcome.message, 'golden rubric belum lulus');
    });

    test('rollbackSkill() mengembalikan outcome ok', () async {
      final outcome = await repo.rollbackSkill('catatan-keuangan');
      expect(outcome.ok, isTrue);
      expect(outcome.stage, 'rollback-draft');
    });

    test('skillHistory() mengembalikan riwayat gate ledger', () async {
      final history = await repo.skillHistory('catatan-keuangan');
      expect(history.single.action, 'approved');
      expect(history.single.actor, 'api');
      expect(history.single.at, '2026-11-18T09:00:00Z');
    });

    test('skill tidak dikirim via query: bearer tetap di header', () async {
      await repo.skills();
      expect(fake.lastAuthHeader, 'Bearer t');
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  Map<String, dynamic> lastFeedbackBody = {};
  String lastFeedbackSlug = '';
  String lastAuthHeader = '';
  String? nextFeedbackError;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/skills')) lastAuthHeader = auth;

        if (path == '/v1/skills' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'skills': [
              {
                'slug': 'catatan-keuangan',
                'name': 'Catatan Keuangan',
                'description': 'Membuat catatan pemasukan/pengeluaran.',
                'triggers': ['catat'],
                'tools': ['files'],
                'version': 3,
                'status': 'approved',
                'uses': 12,
                'successes': 11,
                'approved_by': 'api',
                'metrics': {
                  'uses': 12,
                  'positive': 7,
                  'negative': 2,
                },
              },
            ],
          }));
        } else if (path.endsWith('/feedback') &&
            path.startsWith('/v1/skills/') &&
            method == 'POST') {
          final raw = await utf8.decoder.bind(req).join();
          lastFeedbackSlug = path
              .substring('/v1/skills/'.length, path.length - '/feedback'.length);
          lastFeedbackBody =
              Map<String, dynamic>.from(jsonDecode(raw) as Map);
          if (nextFeedbackError != null) {
            req.response.write(jsonEncode(<String, dynamic>{
              'error': nextFeedbackError,
            }));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{
              'slug': lastFeedbackSlug,
              'recorded': true,
              'positive': true,
              'metrics': <String, dynamic>{},
            }));
          }
        } else if (path == '/v1/skills/catatan-keuangan/evaluate' &&
            method == 'POST') {
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'slug': 'catatan-keuangan',
            'stage': 'evaluate',
            'findings': <String>[],
            'golden_score': 1.0,
            'golden_total': 1.0,
            'message': 'lulus',
          }));
        } else if (path == '/v1/skills/rapat/approve' && method == 'POST') {
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'slug': 'rapat',
            'stage': 'evaluate',
            'findings': ['golden gagal'],
            'golden_score': 0.0,
            'golden_total': 2.0,
            'message': 'golden rubric belum lulus',
          }));
        } else if (path == '/v1/skills/catatan-keuangan/rollback' &&
            method == 'POST') {
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'slug': 'catatan-keuangan',
            'stage': 'rollback-draft',
            'findings': <String>[],
          }));
        } else if (path == '/v1/skills/catatan-keuangan/history' &&
            method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'slug': 'catatan-keuangan',
            'history': [
              {
                'slug': 'catatan-keuangan',
                'action': 'approved',
                'actor': 'api',
                'fingerprint': 'abc',
                'at': '2026-11-18T09:00:00Z',
                'reason': 'golden lulus',
              },
            ],
          }));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'not found',
            'retryable': false,
          }));
        }
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
