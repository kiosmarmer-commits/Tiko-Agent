import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_generation.dart';

/// Metadata for one image model in the catalog.
class ImageModelInfo {
  const ImageModelInfo({
    required this.id,
    required this.label,
    required this.provider,
    this.maxWidth = 2048,
  });

  final String id;
  final String label;
  final String provider;
  final int maxWidth;
}

/// Catalog of supported image models (Hermes Agent parity: 11 models).
class ImageModelCatalog {
  const ImageModelCatalog({this.models = defaultModels});

  static const List<ImageModelInfo> defaultModels = [
    ImageModelInfo(
      id: 'fal-ai/flux-2-klein',
      label: 'FLUX 2 Klein',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/flux-2-pro',
      label: 'FLUX 2 Pro',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'openai/gpt-image-1.5',
      label: 'GPT-Image 1.5',
      provider: 'openai',
    ),
    ImageModelInfo(
      id: 'openai/gpt-image-2',
      label: 'GPT-Image 2',
      provider: 'openai',
    ),
    ImageModelInfo(
      id: 'fal-ai/nano-banana-pro',
      label: 'Nano Banana Pro',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/ideogram-v3',
      label: 'Ideogram V3',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/recraft-v4-pro',
      label: 'Recraft V4 Pro',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/qwen-image',
      label: 'Qwen Image',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/z-image-turbo',
      label: 'Z-Image Turbo',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/krea-v2-medium',
      label: 'Krea V2 Medium',
      provider: 'fal',
    ),
    ImageModelInfo(
      id: 'fal-ai/krea-v2-large',
      label: 'Krea V2 Large',
      provider: 'fal',
    ),
  ];

  final List<ImageModelInfo> models;

  ImageModelInfo? byId(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<ImageModelInfo> byProvider(String provider) =>
      models.where((m) => m.provider == provider).toList();

  List<String> ids() => models.map((m) => m.id).toList();
}

/// FAL.ai queue-based image generation.
///
/// Flow: `POST https://queue.fal.run/{model}` returns `status_url` and
/// `response_url`; the status endpoint is polled until `COMPLETED`, then the
/// response URL is fetched and the first `images[].url` is downloaded.
class FalAiImageProvider implements ImageProvider {
  FalAiImageProvider({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://queue.fal.run',
    this.pollInterval = const Duration(milliseconds: 500),
    this.maxPolls = 60,
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration pollInterval;
  final int maxPolls;
  final Duration timeout;

  @override
  String get name => 'fal';

  @override
  Future<List<String>> listModels() async =>
      const ImageModelCatalog().byProvider('fal').map((m) => m.id).toList();

  @override
  Future<ImageGenerationResult> generateImage({
    required String prompt,
    String? model,
    String? negativePrompt,
    int? width,
    int? height,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? style,
    String? outputFormat,
  }) async {
    final started = DateTime.now();
    final modelId = model ?? 'fal-ai/flux-2-klein';
    try {
      final submitted = await _post(
        Uri.parse('$baseUrl/$modelId'),
        {
          'prompt': prompt,
          if (negativePrompt != null) 'negative_prompt': negativePrompt,
          if (width != null) 'image_size': {'width': width, 'height': height},
          if (steps != null) 'num_inference_steps': steps,
          if (guidanceScale != null) 'guidance_scale': guidanceScale,
          if (seed != null) 'seed': seed,
          if (outputFormat != null) 'output_format': outputFormat,
        },
      );
      final statusUrl = submitted['status_url']?.toString();
      final responseUrl = submitted['response_url']?.toString();
      if (statusUrl == null || responseUrl == null) {
        throw StateError('Respons queue FAL.ai tidak berisi status/response URL');
      }
      String status = submitted['status']?.toString() ?? 'IN_QUEUE';
      for (var i = 0; i < maxPolls && status != 'COMPLETED'; i++) {
        await Future<void>.delayed(pollInterval);
        final poll = await _get(Uri.parse(statusUrl));
        status = poll['status']?.toString() ?? '';
      }
      if (status != 'COMPLETED') {
        throw TimeoutException('FAL.ai generation tidak selesai ($status)');
      }
      final payload = await _get(Uri.parse(responseUrl));
      final images = payload['images'] as List<dynamic>? ?? const [];
      if (images.isEmpty) {
        throw StateError('FAL.ai tidak mengembalikan gambar');
      }
      final url = (images.first as Map)['url'].toString();
      final bytes = await _download(Uri.parse(url));
      return ImageGenerationResult(
        success: true,
        imageBytes: bytes,
        model: modelId,
        provider: name,
        width: width,
        height: height,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
    } catch (e) {
      return ImageGenerationResult(
        success: false,
        model: modelId,
        provider: name,
        prompt: prompt,
        error: e.toString(),
        generationTime: DateTime.now().difference(started),
      );
    }
  }

  Future<Map<String, dynamic>> _post(Uri uri, Object body) async {
    final res = await _client
        .post(
          uri,
          headers: {
            'authorization': 'Key $apiKey',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('FAL.ai submit gagal: HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final res = await _client
        .get(uri, headers: {'authorization': 'Key $apiKey'})
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('FAL.ai poll gagal: HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Uint8List> _download(Uri uri) async {
    final res = await _client.get(uri).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Unduhan gambar gagal: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }
}

/// OpenAI Images API (`POST /v1/images/generations`) with `b64_json` or URL
/// responses.
class OpenAiImagesProvider implements ImageProvider {
  OpenAiImagesProvider({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'openai';

  @override
  Future<List<String>> listModels() async =>
      const ImageModelCatalog().byProvider('openai').map((m) => m.id).toList();

  @override
  Future<ImageGenerationResult> generateImage({
    required String prompt,
    String? model,
    String? negativePrompt,
    int? width,
    int? height,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? style,
    String? outputFormat,
  }) async {
    final started = DateTime.now();
    final modelId = model ?? 'openai/gpt-image-1.5';
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl/v1/images/generations'),
            headers: {
              'authorization': 'Bearer $apiKey',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': modelId.split('/').last,
              'prompt': prompt,
              if (width != null && height != null) 'size': '${width}x$height',
              if (outputFormat != null) 'output_format': outputFormat,
            }),
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('OpenAI Images gagal: HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? const [];
      if (data.isEmpty) {
        throw StateError('OpenAI Images tidak mengembalikan gambar');
      }
      final first = data.first as Map<String, dynamic>;
      final b64 = first['b64_json']?.toString();
      final Uint8List bytes;
      if (b64 != null && b64.isNotEmpty) {
        bytes = base64Decode(b64);
      } else {
        final url = first['url']?.toString();
        if (url == null) {
          throw StateError('OpenAI Images tanpa b64_json/url');
        }
        final dl = await _client.get(Uri.parse(url)).timeout(timeout);
        if (dl.statusCode < 200 || dl.statusCode >= 300) {
          throw StateError('Unduhan gambar gagal: HTTP ${dl.statusCode}');
        }
        bytes = dl.bodyBytes;
      }
      return ImageGenerationResult(
        success: true,
        imageBytes: bytes,
        model: modelId,
        provider: name,
        width: width,
        height: height,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
    } catch (e) {
      return ImageGenerationResult(
        success: false,
        model: modelId,
        provider: name,
        prompt: prompt,
        error: e.toString(),
        generationTime: DateTime.now().difference(started),
      );
    }
  }
}

/// Routes image generation to the right provider based on the model id
/// prefix (`fal-ai/...` → FAL.ai, `openai/...` → OpenAI Images).
class ImageModelRouter implements ImageProvider {
  ImageModelRouter({required this.providers, this.catalog = const ImageModelCatalog()});

  final Map<String, ImageProvider> providers;
  final ImageModelCatalog catalog;

  @override
  String get name => 'router';

  @override
  Future<List<String>> listModels() => Future.value(catalog.ids());

  @override
  Future<ImageGenerationResult> generateImage({
    required String prompt,
    String? model,
    String? negativePrompt,
    int? width,
    int? height,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? style,
    String? outputFormat,
  }) async {
    final modelId = model ?? catalog.models.first.id;
    final info = catalog.byId(modelId);
    final providerName = info?.provider ?? modelId.split('/').first;
    final provider = providers[providerName];
    if (provider == null) {
      return ImageGenerationResult(
        success: false,
        model: modelId,
        provider: providerName,
        prompt: prompt,
        error: 'Provider tidak terdaftar: $providerName',
      );
    }
    return provider.generateImage(
      prompt: prompt,
      model: modelId,
      negativePrompt: negativePrompt,
      width: width,
      height: height,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed,
      style: style,
      outputFormat: outputFormat,
    );
  }
}
