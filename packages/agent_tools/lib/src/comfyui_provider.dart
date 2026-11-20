import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'image_generation.dart';

/// Stable Diffusion via ComfyUI provider.
///
/// This provider connects to a ComfyUI server for image generation.
///
/// API Documentation: https://github.com/comfyanonymous/ComfyUI
class ComfyUIProvider implements ImageProvider {
  ComfyUIProvider({
    http.Client? client,
    required this.comfyuiUrl,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String comfyuiUrl;
  final Duration timeout;

  @override
  String get name => 'comfyui';

  @override
  Future<List<String>> listModels() async => const [
        'stable-diffusion-xl-base-1.0',
        'stable-diffusion-1.5',
        'stable-diffusion-2.1',
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
    final modelId = model ?? 'stable-diffusion-xl-base-1.0';
    try {
      // Build ComfyUI workflow
      final workflow = <String, dynamic>{
        'nodes': [
          {
            'id': 0,
            'type': 'CLIPTextEncode',
            'inputs': {
              'text': prompt,
              'clip': ['CLIP', 0],
            },
          },
          if (negativePrompt != null && negativePrompt.isNotEmpty)
            {
              'id': 1,
              'type': 'CLIPTextEncode',
              'inputs': {
                'text': negativePrompt,
                'clip': ['CLIP', 0],
              },
            },
          {
            'id': 2,
            'type': 'CheckpointLoaderSimple',
            'inputs': {
              'ckpt_name': modelId,
            },
          },
          {
            'id': 3,
            'type': 'KSampler',
            'inputs': {
              'model': [2, 0],
              'seed': seed ?? 0,
              'steps': steps ?? 20,
              'cfg': guidanceScale ?? 7.0,
              'sampler_name': 'euler',
              'scheduler': 'normal',
              'denoise': 1.0,
              'positive': [0, 0],
              if (negativePrompt != null && negativePrompt.isNotEmpty)
                'negative': [1, 0],
            },
          },
          {
            'id': 4,
            'type': 'VAEDecode',
            'inputs': {
              'samples': [3, 0],
              'vae': [2, 1],
            },
          },
          {
            'id': 5,
            'type': 'VAEEncode',
            'inputs': {
              'pixels': [4, 0],
              'vae': [2, 1],
            },
          },
          {
            'id': 6,
            'type': 'SaveImage',
            'inputs': {
              'images': [4, 0],
            },
          },
        ],
        'links': [
          [0, 0, 3, 0],
          if (negativePrompt != null && negativePrompt.isNotEmpty)
            [1, 0, 3, 1],
          [2, 0, 3, 2],
          [2, 1, 4, 1],
          [2, 1, 5, 1],
          [3, 0, 4, 0],
          [4, 0, 6, 0],
        ],
      };

      // Remove negative prompt node if not needed
      if (negativePrompt == null || negativePrompt.isEmpty) {
        workflow['nodes'].removeWhere((node) => node['id'] == 1);
        workflow['links'].removeWhere((link) => link[1] == 1);
        // Update negative input in KSampler
        for (final node in workflow['nodes']) {
          if (node['id'] == 3) {
            node['inputs'].remove('negative');
          }
        }
      }

      final uri = Uri.parse('$comfyuiUrl/prompt');
      final res = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'prompt': workflow}),
          )
          .timeout(timeout);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('ComfyUI prompt failed: HTTP ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final promptId = json['prompt_id'] as String?;
      if (promptId == null || promptId.isEmpty) {
        throw StateError('ComfyUI did not return prompt_id');
      }

      // Poll for results
      final historyUri = Uri.parse('$comfyuiUrl/history/$promptId');
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final historyRes = await _client.get(historyUri).timeout(timeout);
        if (historyRes.statusCode < 200 || historyRes.statusCode >= 300) {
          continue;
        }
        final historyJson = jsonDecode(historyRes.body) as Map<String, dynamic>;
        final historyPrompt = historyJson['prompt_id'] as String?;
        if (historyPrompt == promptId) {
          final outputs = historyJson['outputs'] as Map<String, dynamic>?;
          if (outputs != null && outputs.isNotEmpty) {
            final firstOutput = outputs.values.first as Map<String, dynamic>?;
            if (firstOutput != null) {
              final imageData = firstOutput['images'] as List<dynamic>?;
              if (imageData != null && imageData.isNotEmpty) {
                final firstImage = imageData.first as Map<String, dynamic>?;
                if (firstImage != null) {
                  final imageBase64 = firstImage['image'] as String?;
                  if (imageBase64 != null && imageBase64.isNotEmpty) {
                    final bytes = base64.decode(imageBase64.split(',').last);
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
                  }
                }
              }
            }
          }
        }
      }

      throw StateError('ComfyUI generation timed out');
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
