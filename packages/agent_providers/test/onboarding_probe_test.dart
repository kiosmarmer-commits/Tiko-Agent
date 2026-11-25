import 'dart:convert';
import 'dart:io';

import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('Deteksi provider dari env', () {
    test('kosong bila tidak ada env var yang dikenal', () {
      expect(OnboardingProbe.detectFromEnv({}), isEmpty);
    });

    test('memetakan env var ke kandidat berlabel dan alasan', () {
      final list = OnboardingProbe.detectFromEnv({
        'ANTHROPIC_API_KEY': 'sk-ant',
        'DEEPSEEK_API_KEY': 'sk-x',
      });
      expect(list, hasLength(2));
      expect(list[0].providerType, 'anthropic');
      expect(list[0].label, 'Anthropic');
      expect(list[0].reason, contains('ANTHROPIC_API_KEY'));
      expect(list[0].apiKeyEnvVar, 'ANTHROPIC_API_KEY');
      expect(list[1].providerType, 'deepseek');
    });

    test('dedupe dua env var untuk tipe yang sama', () {
      final list = OnboardingProbe.detectFromEnv({
        'GEMINI_API_KEY': 'a',
        'GOOGLE_API_KEY': 'b',
      });
      expect(list, hasLength(1));
      expect(list.single.reason, contains('GEMINI_API_KEY'));
    });

    test('nilai kosong diabaikan', () {
      expect(OnboardingProbe.detectFromEnv({'OPENAI_API_KEY': ''}), isEmpty);
    });
  });

  group('probe koneksi + discovery model', () {
    test('mock selalu OK tanpa jaringan', () async {
      final out = await OnboardingProbe.probe(providerType: 'mock');
      expect(out.ok, isTrue);
      expect(out.probed, isTrue);
      expect(out.models, isEmpty);
    });

    test('azure_openai dan bedrock ditandai tidak-diprobe tapi oke', () async {
      for (final type in ['azure_openai', 'bedrock']) {
        final out = await OnboardingProbe.probe(providerType: type);
        expect(out.ok, isTrue, reason: type);
        expect(out.probed, isFalse, reason: type);
      }
    });

    test('openai-compat memakai Authorization Bearer dan baca data[].id', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final client = MockClient((req) async {
        capturedUri = req.url;
        capturedHeaders = req.headers;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-4o-mini'},
              {'id': 'gpt-4.1'},
            ],
          }),
          200,
        );
      });
      final out = await OnboardingProbe.probe(
        providerType: 'openai',
        apiKey: 'sk-test',
        client: client,
      );
      expect(out.ok, isTrue);
      expect(out.detail, contains('2 model'));
      expect(out.models, ['gpt-4o-mini', 'gpt-4.1']);
      expect(capturedUri.toString(), 'https://api.openai.com/v1/models');
      expect(capturedHeaders!['authorization'], 'Bearer sk-test');
    });

    test('anthropic memakai x-api-key + anthropic-version di /v1/models', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://api.anthropic.com/v1/models');
        expect(req.headers['x-api-key'], 'sk-ant');
        expect(req.headers['anthropic-version'], '2023-06-01');
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-sonnet-4-20250514'},
            ],
          }),
          200,
        );
      });
      final out = await OnboardingProbe.probe(
        providerType: 'anthropic',
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-ant',
        client: client,
      );
      expect(out.ok, isTrue);
      expect(out.models, ['claude-sonnet-4-20250514']);
    });

    test('HTTP 401 gagal dengan saran periksa API key', () async {
      final client = MockClient((req) async => http.Response('nope', 401));
      final out = await OnboardingProbe.probe(
        providerType: 'openai',
        apiKey: 'wrong',
        client: client,
      );
      expect(out.ok, isFalse);
      expect(out.detail, contains('401'));
      expect(out.detail, contains('API key'));
    });

    test('ollama probe /api/tags membaca models[].name', () async {
      Uri? capturedUri;
      final client = MockClient((req) async {
        capturedUri = req.url;
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'qwen2.5:3b'},
            ],
          }),
          200,
        );
      });
      final local = await OnboardingProbe.probeLocalOllama(
        baseUrl: 'http://127.0.0.1:11434',
        client: client,
      );
      expect(capturedUri.toString(), 'http://127.0.0.1:11434/api/tags');
      expect(local, isNotNull);
      expect(local!.$1.providerType, 'ollama_native');
      expect(local.$2, ['qwen2.5:3b']);
    });

    test('daemon ollama mati → probeLocalOllama null tanpa throw', () async {
      final client = MockClient((req) async => http.Response('err', 500));
      final local = await OnboardingProbe.probeLocalOllama(client: client);
      expect(local, isNull);
    });

    test('koneksinya error → gagal fail-open dengan detail', () async {
      final client = MockClient(
        (req) async => throw const SocketException('koneksi ditolak'),
      );
      final out = await OnboardingProbe.probe(
        providerType: 'deepseek',
        client: client,
      );
      expect(out.ok, isFalse);
      expect(out.models, isEmpty);
    });
  });

  test('rekomendasi security mode: lokal auto, cloud guided', () {
    expect(OnboardingProbe.recommendSecurityMode('mock'), 'auto');
    expect(OnboardingProbe.recommendSecurityMode('ollama_native'), 'auto');
    expect(OnboardingProbe.recommendSecurityMode('openai'), 'guided');
    expect(OnboardingProbe.recommendSecurityMode('anthropic'), 'guided');
    expect(OnboardingProbe.recommendSecurityMode('deepseek'), 'guided');
  });
}
