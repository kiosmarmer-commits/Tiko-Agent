import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_presets.dart';

/// Satu kandidat provider hasil deteksi otomatis (Hermes-parity onboarding):
/// data murni tanpa I/O, cukup untuk wizard menampilkan label + alasan.
class OnboardingSuggestion {
  const OnboardingSuggestion({
    required this.providerType,
    required this.label,
    required this.reason,
    this.apiKeyEnvVar,
  });

  /// id preset (mis. `openai`) atau tipe bawaan (`mock`, `ollama_native`).
  final String providerType;
  final String label;
  final String reason;

  /// Env var API key yang terdeteksi bila sumber deteksi adalah env.
  final String? apiKeyEnvVar;
}

/// Hasil probe koneksi per provider: sekaligus test connection dan live
/// model discovery (seluruh probe selesai dalam satu GET).
class ProbeOutcome {
  const ProbeOutcome({
    required this.ok,
    required this.detail,
    this.models = const [],
    this.probed = true,
  });

  final bool ok;

  /// Ringkasan manusiawi untuk wizard ("200 OK — 3 model", dsb.).
  final String detail;

  /// Daftar model live; kosong bila gagal atau endpoint tidak menyediakan.
  final List<String> models;

  /// false untuk tipe yang tidak dapat diprobe (bedrock, azure_openai).
  final bool probed;
}

/// Fondasi onboarding wizard (Hermes S10): deteksi provider dari env,
/// probe daemon lokal (Ollama), test connection + live model discovery
/// per provider, dan rekomendasi mode keamanan. HTTP di-inject supaya
/// semua jalur testable tanpa jaringan nyata.
abstract final class OnboardingProbe {
  /// Pemetaan env var → kandidat provider, berurutan prioritas.
  /// Dua var untuk tipe yang sama tidak menghasilkan duplikat.
  static const List<({String envVar, String type, String label})> envMappings = [
    (envVar: 'OPENAI_API_KEY', type: 'openai', label: 'OpenAI'),
    (envVar: 'ANTHROPIC_API_KEY', type: 'anthropic', label: 'Anthropic'),
    (envVar: 'GEMINI_API_KEY', type: 'gemini', label: 'Google Gemini'),
    (envVar: 'GOOGLE_API_KEY', type: 'gemini', label: 'Google Gemini'),
    (envVar: 'DEEPSEEK_API_KEY', type: 'deepseek', label: 'DeepSeek'),
    (envVar: 'OPENROUTER_API_KEY', type: 'openrouter', label: 'OpenRouter'),
    (envVar: 'MISTRAL_API_KEY', type: 'mistral', label: 'Mistral'),
    (envVar: 'GROQ_API_KEY', type: 'groq', label: 'Groq'),
    (envVar: 'XAI_API_KEY', type: 'xai', label: 'xAI'),
    (envVar: 'TOGETHER_API_KEY', type: 'together', label: 'Together'),
    (envVar: 'FIREWORKS_API_KEY', type: 'fireworks', label: 'Fireworks'),
    (envVar: 'NVIDIA_API_KEY', type: 'nvidia', label: 'NVIDIA'),
    (envVar: 'HF_TOKEN', type: 'huggingface', label: 'Hugging Face'),
  ];

  /// Deteksi murni dari [env] (umumnya Platform.environment). Bila dua
  /// var dipetakan ke tipe sama, yang pertama dalam urutan [envMappings]
  /// menang (reason menyebut var pertama).
  static List<OnboardingSuggestion> detectFromEnv(Map<String, String> env) {
    final seen = <String>{};
    final suggestions = <OnboardingSuggestion>[];
    for (final m in envMappings) {
      if (env.containsKey(m.envVar) && (env[m.envVar] ?? '').isNotEmpty) {
        if (seen.add(m.type)) {
          suggestions.add(OnboardingSuggestion(
            providerType: m.type,
            label: m.label,
            reason: 'env ${m.envVar} terdeteksi',
            apiKeyEnvVar: m.envVar,
          ));
        }
      }
    }
    return suggestions;
  }

  /// Base URL default untuk [providerType]: preset bila ada, lalu fallback.
  static String defaultBaseUrl(String providerType) {
    if (providerType == 'ollama_native' || providerType == 'mock') {
      return 'http://127.0.0.1:11434';
    }
    return findProviderPreset(providerType)?.baseUrl ?? '';
  }

  /// Probe daemon Ollama lokal (Hermes-parity deteksi `localhost:11434`).
  /// Kandidat non-null + daftar model live bila daemon merespons.
  static Future<(OnboardingSuggestion, List<String>)?> probeLocalOllama({
    String baseUrl = 'http://127.0.0.1:11434',
    http.Client? client,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final outcome = await probe(
      providerType: 'ollama_native',
      baseUrl: baseUrl,
      client: client,
      timeout: timeout,
    );
    if (!outcome.ok) return null;
    return (
      OnboardingSuggestion(
        providerType: 'ollama_native',
        label: 'Ollama lokal',
        reason: 'daemon $baseUrl merespons',
      ),
      outcome.models,
    );
  }

  /// Test connection + live model discovery dalam satu panggilan.
  /// Fail-open: gagal dikembalikan sebagai [ProbeOutcome] `ok:false`
  /// dengan detail penyebab, tidak pernah throw untuk masalah jaringan.
  static Future<ProbeOutcome> probe({
    required String providerType,
    String? baseUrl,
    String? apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (providerType == 'mock' || providerType == 'ollama' || providerType == 'ollama_native') {
      if (providerType == 'mock') {
        return const ProbeOutcome(ok: true, detail: 'provider mock: selalu tersedia');
      }
      final base = _trimSlash(baseUrl ?? 'http://127.0.0.1:11434');
      return _getJson(
        client: client,
        timeout: timeout,
        uri: Uri.parse('$base/api/tags'),
        headers: const {'accept': 'application/json'},
        okDetail: (models) => 'daemon Ollama merespons — ${models.length} model',
        failContext: 'Ollama $base',
      );
    }
    if (providerType == 'azure_openai' || providerType == 'bedrock') {
      return ProbeOutcome(
        ok: true,
        detail: 'probe otomatis tidak tersedia untuk $providerType; '
            'konfigurasi tetap divalidasi saat runtime',
        probed: false,
      );
    }
    final base = _trimSlash(baseUrl ?? defaultBaseUrl(providerType));
    if (base.isEmpty) {
      return ProbeOutcome(ok: false, detail: 'base URL tidak diketahui untuk $providerType');
    }
    if (providerType == 'anthropic') {
      return _getJson(
        client: client,
        timeout: timeout,
        uri: Uri.parse('$base/v1/models'),
        headers: {
          'x-api-key': apiKey ?? '',
          'anthropic-version': '2023-06-01',
          'accept': 'application/json',
        },
        okDetail: (models) => 'Anthropic merespons — ${models.length} model',
        failContext: 'Anthropic $base',
        unauthorizedHint: 'periksa ANTHROPIC_API_KEY',
      );
    }
    return _getJson(
      client: client,
      timeout: timeout,
      uri: Uri.parse('$base/models'),
      headers: {
        if (apiKey != null && apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
        'accept': 'application/json',
      },
      okDetail: (models) => 'endpoint merespons — ${models.length} model',
      failContext: '$providerType $base',
      unauthorizedHint: 'periksa API key provider ini',
    );
  }

  static Future<ProbeOutcome> _getJson({
    required http.Client? client,
    required Duration timeout,
    required Uri uri,
    required Map<String, String> headers,
    required String Function(List<String> models) okDetail,
    required String failContext,
    String? unauthorizedHint,
  }) async {
    final owned = client ?? http.Client();
    try {
      final res = await owned.get(uri, headers: headers).timeout(timeout);
      if (res.statusCode >= 400) {
        final hint = unauthorizedHint == null ? '' : ' — $unauthorizedHint';
        return ProbeOutcome(
          ok: false,
          detail: 'HTTP ${res.statusCode} dari $failContext$hint',
        );
      }
      var models = const <String>[];
      try {
        final json = res.body.isEmpty ? null : jsonDecode(res.body);
        models = parseModelList(json);
      } catch (_) {
        models = const [];
      }
      return ProbeOutcome(ok: true, detail: okDetail(models), models: models);
    } on TimeoutException {
      return ProbeOutcome(ok: false, detail: 'timeout menghubungi $failContext');
    } catch (error) {
      return ProbeOutcome(ok: false, detail: 'gagal menghubungi $failContext: $error');
    } finally {
      if (client == null) owned.close();
    }
  }

  /// Dua bentuk daftar model yang umum: OpenAI-compat `data[].id`
  /// dan Ollama `/api/tags` `models[].name` (mis. `qwen2.5:3b`).
  static List<String> parseModelList(dynamic json) {
    if (json is! Map) return const [];
    final data = json['data'] as List<dynamic>?;
    if (data != null) {
      return [
        for (final e in data)
          if (e is Map && e['id'] is String) e['id'] as String,
      ];
    }
    final tags = json['models'] as List<dynamic>?;
    return [
      for (final e in tags ?? const [])
        if (e is Map && e['name'] is String) e['name'] as String,
    ];
  }

  static String _trimSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  /// Rekomendasi mode keamanan: runtime lokal (mock / Ollama) aman untuk
  /// `auto`; endpoint cloud (API key dikirim keluar) lebih bijak `guided`.
  static String recommendSecurityMode(String providerType) =>
      (providerType == 'mock' || providerType == 'ollama_native' || providerType == 'ollama')
          ? 'auto'
          : 'guided';
}
