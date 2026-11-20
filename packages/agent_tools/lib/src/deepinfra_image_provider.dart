import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_generation.dart';

/// DeepInfra image generation provider.
///
/// API Documentation: https://deepinfra.com/docs
class DeepInfraImageProvider implements ImageProvider {
  DeepInfraImageProvider({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://api.deepinfra.com/v1',
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'deepinfra';

  @override
  Future<List<String>> listModels() async => const [
        'stabilityai/stable-diffusion-xl-base-1.0',
        'black-forest-labs/FLUX.1-dev',
        'black-forest-labs/FLUX.1-schnell',
      ];

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
    final modelId = model ?? 'black-forest-labs/FLUX.1-schnell';
    try {
      final body = <String, dynamic>{
        'model': modelId,
        'prompt': prompt,
        if (negativePrompt != null) 'negative_prompt': negativePrompt,
        if (width != null && height != null)
          'image_size': {'width': width, 'height': height},
        if (steps != null) 'num_inference_steps': steps,
        if (guidanceScale != null) 'guidance_scale': guidanceScale,
        if (seed != null) 'seed': seed,
        if (style != null) 'style': style,
      };

      final uri = Uri.parse('$baseUrl/inference/$modelId');
      final res = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('DeepInfra image generation failed: HTTP ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['images'] as List<dynamic>? ?? [];
      if (data.isEmpty) {
        throw StateError('DeepInfra did not return any images');
      }

      final imageData = (data.first as Map<String, dynamic>)['image'] as String?;
      if (imageData == null || imageData.isEmpty) {
        throw StateError('DeepInfra did not return image data');
      }

      final bytes = base64.decode(imageData);
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
