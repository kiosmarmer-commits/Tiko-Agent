import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'video_generation.dart';

/// DeepInfra Video generation provider.
///
/// API Documentation: https://deepinfra.com/docs
class DeepInfraVideoProvider implements VideoProvider {
  DeepInfraVideoProvider({
    http.Client? client,
    required this.apiKey,
    this.baseUrl = 'https://api.deepinfra.com/v1',
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'deepinfra';

  @override
  Future<List<String>> listModels() async => const [
        'stabilityai/stable-video-diffusion',
        'runwayml/stable-diffusion-video',
      ];

  @override
  Future<VideoGenerationResult> generateVideo({
    required String prompt,
    String? model,
    String? negativePrompt,
    
    
    int? durationSec,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? style,
    String? outputFormat,
  }) async {
    final started = DateTime.now();
    final modelId = model ?? 'stabilityai/stable-video-diffusion';
    try {
      final body = <String, dynamic>{
        'model': modelId,
        'prompt': prompt,
        if (negativePrompt != null) 'negative_prompt': negativePrompt,
        if (width != null && height != null)
          'size': {'width': width, 'height': height},
        if (duration != null) 'duration': duration,
        if (steps != null) 'steps': steps,
        if (guidanceScale != null) 'guidance_scale': guidanceScale,
        if (seed != null) 'seed': seed,
        if (style != null) 'style': style,
        if (outputFormat != null) 'format': outputFormat,
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
        throw StateError('DeepInfra video generation failed: HTTP ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final videoUrl = json['video_url'] as String?;
      if (videoUrl == null || videoUrl.isEmpty) {
        throw StateError('DeepInfra did not return video URL');
      }

      return VideoGenerationResult(
        success: true,
        videoUrl: videoUrl,
        model: modelId,
        provider: name,
        
        
        durationSec: duration,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
    } catch (e) {
      return VideoGenerationResult(
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
