import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_generation.dart';

/// Krea AI image generation provider.
///
/// API Documentation: https://api.krea.ai/docs
class KreaImageProvider implements ImageProvider {
  KreaImageProvider({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://api.krea.ai/v1',
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'krea';

  @override
  Future<List<String>> listModels() async => const [
        'krea-v2-medium',
        'krea-v2-large',
        'krea-v3',
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
    final modelId = model ?? 'krea-v2-medium';
    try {
      final body = <String, dynamic>{
        'model': modelId,
        'prompt': prompt,
        if (negativePrompt != null) 'negative_prompt': negativePrompt,
        if (width != null && height != null)
          'size': {'width': width, 'height': height},
        if (steps != null) 'steps': steps,
        if (guidanceScale != null) 'guidance_scale': guidanceScale,
        if (seed != null) 'seed': seed,
        if (style != null) 'style': style,
        if (outputFormat != null) 'format': outputFormat,
      };

      final uri = Uri.parse('$baseUrl/images/generations');
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
        throw StateError('Krea image generation failed: HTTP ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      if (data.isEmpty) {
        throw StateError('Krea did not return any images');
      }

      final imageUrl = (data.first as Map<String, dynamic>)['url'] as String?;
      if (imageUrl == null || imageUrl.isEmpty) {
        throw StateError('Krea did not return image URL');
      }

      final bytes = await _download(Uri.parse(imageUrl));
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

  Future<Uint8List> _download(Uri uri) async {
    final res = await _client.get(uri).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Image download failed: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }
}
