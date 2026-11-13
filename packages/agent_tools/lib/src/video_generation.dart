import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:agent_core/agent_core.dart';

/// Video generation configuration (Hermes-parity media breadth, P2-1).
class VideoGenerationConfig {
  const VideoGenerationConfig({
    this.enabled = true,
    this.outputDirectory = 'videos',
    this.maxVideoSize = 100 * 1024 * 1024, // 100MB
    this.allowedFormats = const ['mp4', 'webm', 'gif'],
    this.defaultDurationSec = 5,
    this.maxDurationSec = 20,
    this.defaultFps = 24,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 60,
  });

  final bool enabled;
  final String outputDirectory;
  final int maxVideoSize;
  final List<String> allowedFormats;
  final int defaultDurationSec;
  final int maxDurationSec;
  final int defaultFps;

  /// Interval between queue status polls for asynchronous providers (FAL).
  final Duration pollInterval;

  /// Maximum number of status polls before giving up.
  final int maxPolls;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'outputDirectory': outputDirectory,
        'maxVideoSize': maxVideoSize,
        'allowedFormats': allowedFormats,
        'defaultDurationSec': defaultDurationSec,
        'maxDurationSec': maxDurationSec,
        'defaultFps': defaultFps,
      };
}

/// Result of a video generation request.
class VideoGenerationResult {
  const VideoGenerationResult({
    required this.success,
    this.videoBytes,
    this.videoPath,
    this.videoUrl,
    this.model,
    this.provider,
    this.durationSec,
    this.fps,
    this.aspectRatio,
    this.resolution,
    this.prompt,
    this.error,
    this.generationTime,
  });

  final bool success;

  /// Downloaded video payload, when the provider exposes a direct URL.
  final Uint8List? videoBytes;
  final String? videoPath;
  final String? videoUrl;
  final String? model;
  final String? provider;
  final int? durationSec;
  final int? fps;
  final String? aspectRatio;
  final String? resolution;
  final String? prompt;
  final String? error;
  final Duration? generationTime;

  int get videoSize => videoBytes?.length ?? 0;

  Map<String, dynamic> toJson() => {
        'success': success,
        'model': model,
        'provider': provider,
        'duration_sec': durationSec,
        'fps': fps,
        'aspect_ratio': aspectRatio,
        'resolution': resolution,
        'prompt': prompt,
        'video_url': videoUrl,
        'video_path': videoPath,
        'video_size': videoSize,
        'error': error,
        'generation_time_ms': generationTime?.inMilliseconds,
      };
}

/// Abstract interface for video generation providers.
abstract class VideoProvider {
  String get name;

  Future<VideoGenerationResult> generateVideo({
    required String prompt,
    String? model,
    int? durationSec,
    int? fps,
    String? aspectRatio,
    String? resolution,
    int? seed,
  });

  Future<List<String>> listModels();
}

/// [FAL.ai](https://fal.ai) video generation via the queue API:
///
/// 1. `POST {base}/{model}` → `{request_id, status_url, response_url}`
/// 2. poll `status_url` until `status == COMPLETED` (bounded by
///    [maxPolls] × [pollInterval]) or `ERROR`
/// 3. `GET response_url` → `{video: {url: ...}}` → download bytes
class FalVideoGenerationProvider implements VideoProvider {
  FalVideoGenerationProvider({
    required this.apiKey,
    this.baseUrl = 'https://queue.fal.run',
    this.config = const VideoGenerationConfig(),
    http.Client? httpClient,
  }) : _ownedClient = httpClient;

  final String apiKey;
  final String baseUrl;
  final VideoGenerationConfig config;
  final http.Client? _ownedClient;

  http.Client get _client => _ownedClient ?? http.Client();

  @override
  String get name => 'fal';

  @override
  Future<List<String>> listModels() => Future.value(const [
        'veo3',
        'veo3-fast',
        'kling-video/v2/master/text-to-video',
        'wan/v2.2-a14b/text-to-video',
        'ltx-video',
        'ltx-video-fast',
        'pixverse/v4.5/text-to-video',
        'hunyuan-video',
      ]);

  @override
  Future<VideoGenerationResult> generateVideo({
    required String prompt,
    String? model,
    int? durationSec,
    int? fps,
    String? aspectRatio,
    String? resolution,
    int? seed,
  }) async {
    final started = DateTime.now();
    final modelName = model ?? 'veo3-fast';
    try {
      // 1. Submit the generation job.
      final submit = await _client
          .post(
            Uri.parse('$baseUrl/$modelName'),
            headers: {
              'Authorization': 'Key $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'prompt': prompt,
              if (durationSec != null) 'duration': '$durationSec seconds',
              if (aspectRatio != null) 'aspect_ratio': aspectRatio,
              if (resolution != null) 'resolution': resolution,
              if (seed != null) 'seed': seed,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (submit.statusCode >= 400) {
        return VideoGenerationResult(
          success: false,
          error: 'FAL submit failed: HTTP ${submit.statusCode}',
          provider: name,
          model: modelName,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }
      final submitted = jsonDecode(submit.body) as Map<String, dynamic>;
      final statusUrl = submitted['status_url'] as String?;
      final responseUrl = submitted['response_url'] as String?;
      if (statusUrl == null || responseUrl == null) {
        return VideoGenerationResult(
          success: false,
          error: 'FAL submit response missing status_url/response_url',
          provider: name,
          model: modelName,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }

      // 2. Poll the queue status (bounded).
      var status = '';
      for (var i = 0; i < config.maxPolls; i++) {
        await Future<void>.delayed(config.pollInterval);
        final poll = await _client.get(
          Uri.parse(statusUrl),
          headers: {'Authorization': 'Key $apiKey'},
        );
        if (poll.statusCode >= 400) {
          return VideoGenerationResult(
            success: false,
            error: 'FAL status poll failed: HTTP ${poll.statusCode}',
            provider: name,
            model: modelName,
            prompt: prompt,
            generationTime: DateTime.now().difference(started),
          );
        }
        final state = jsonDecode(poll.body) as Map<String, dynamic>;
        status = state['status']?.toString() ?? '';
        if (status == 'COMPLETED') break;
        if (status == 'ERROR') {
          return VideoGenerationResult(
            success: false,
            error: 'FAL job failed on the provider side',
            provider: name,
            model: modelName,
            prompt: prompt,
            generationTime: DateTime.now().difference(started),
          );
        }
      }
      if (status != 'COMPLETED') {
        return VideoGenerationResult(
          success: false,
          error:
              'FAL job did not complete within ${config.maxPolls} polls',
          provider: name,
          model: modelName,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }

      // 3. Fetch the result payload and download the video.
      final result = await _client.get(
        Uri.parse(responseUrl),
        headers: {'Authorization': 'Key $apiKey'},
      );
      if (result.statusCode >= 400) {
        return VideoGenerationResult(
          success: false,
          error: 'FAL result fetch failed: HTTP ${result.statusCode}',
          provider: name,
          model: modelName,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }
      final payload = jsonDecode(result.body) as Map<String, dynamic>;
      final video = payload['video'];
      final url = video is Map ? video['url']?.toString() : null;
      if (url == null || url.isEmpty) {
        return VideoGenerationResult(
          success: false,
          error: 'FAL result payload missing video.url',
          provider: name,
          model: modelName,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }
      final download = await _client.get(Uri.parse(url));
      if (download.statusCode >= 400) {
        return VideoGenerationResult(
          success: false,
          error: 'FAL video download failed: HTTP ${download.statusCode}',
          provider: name,
          model: modelName,
          videoUrl: url,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }
      if (download.bodyBytes.length > config.maxVideoSize) {
        return VideoGenerationResult(
          success: false,
          error: 'Video exceeds maxVideoSize (${config.maxVideoSize} bytes)',
          provider: name,
          model: modelName,
          videoUrl: url,
          prompt: prompt,
          generationTime: DateTime.now().difference(started),
        );
      }
      return VideoGenerationResult(
        success: true,
        videoBytes: download.bodyBytes,
        videoUrl: url,
        model: modelName,
        provider: name,
        durationSec: durationSec,
        fps: fps,
        aspectRatio: aspectRatio,
        resolution: resolution,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
    } catch (e) {
      return VideoGenerationResult(
        success: false,
        error: 'Failed to generate video: $e',
        provider: name,
        model: modelName,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
    } finally {
      if (_ownedClient == null) _client.close();
    }
  }
}

/// Tool for generating videos from text prompts (P2-1, Hermes-parity).
class VideoGenerationTool implements Tool {
  VideoGenerationTool({
    required this.provider,
    this.config = const VideoGenerationConfig(),
    this.outputDirectory,
  });

  final VideoProvider provider;
  final VideoGenerationConfig config;
  final String? outputDirectory;

  String get name => 'generate_video';

  String get description =>
      'Generate a short video from a text prompt using AI video models '
      '(FAL.ai: Veo, Kling, Wan, LTX, PixVerse, Hunyuan). Returns the saved '
      'file path and provider URL.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'The text prompt describing the video to generate',
              'minLength': 1,
            },
            'model': {
              'type': 'string',
              'description':
                  'The video model to use (default: provider default)',
            },
            'duration_sec': {
              'type': 'integer',
              'description':
                  'Requested clip length in seconds (default: '
                  '${config.defaultDurationSec}, max ${config.maxDurationSec})',
              'minimum': 1,
              'maximum': config.maxDurationSec,
            },
            'fps': {
              'type': 'integer',
              'description': 'Frames per second (default: ${config.defaultFps})',
              'minimum': 8,
              'maximum': 60,
            },
            'aspect_ratio': {
              'type': 'string',
              'description': 'Aspect ratio, e.g. 16:9 or 9:16',
            },
            'resolution': {
              'type': 'string',
              'description': 'Resolution preset, e.g. 720p or 1080p',
            },
            'seed': {
              'type': 'integer',
              'description': 'Random seed for reproducible generation',
            },
            'save_to_file': {
              'type': 'boolean',
              'description':
                  'Whether to save the video to a file (default: true)',
            },
          },
          'required': ['prompt'],
        },
        risk: 'medium',
        parallelSafe: false,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final started = DateTime.now();
    try {
      final prompt = args['prompt'] as String? ?? '';
      if (prompt.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'success': false, 'error': 'Prompt is required'}),
          isError: true,
        );
      }
      final durationSec = args['duration_sec'] is int
          ? args['duration_sec'] as int
          : config.defaultDurationSec;
      final clampedDuration = min(max(durationSec, 1), config.maxDurationSec);
      final saveToFile = args['save_to_file'] as bool? ?? true;

      final result = await provider.generateVideo(
        prompt: prompt,
        model: args['model'] as String?,
        durationSec: clampedDuration,
        fps: args['fps'] as int?,
        aspectRatio: args['aspect_ratio'] as String?,
        resolution: args['resolution'] as String?,
        seed: args['seed'] as int?,
      );

      if (!result.success) {
        return ToolResult(
          callId: '',
          content: jsonEncode(result.toJson()),
          isError: true,
        );
      }

      String? videoPath = result.videoPath;
      if (saveToFile && result.videoBytes != null) {
        videoPath = await _saveVideo(
          result.videoBytes!,
          prompt,
          result.model,
        );
      }

      final finalResult = VideoGenerationResult(
        success: true,
        videoBytes: result.videoBytes,
        videoPath: videoPath,
        videoUrl: result.videoUrl,
        model: result.model,
        provider: result.provider,
        durationSec: result.durationSec,
        fps: result.fps,
        aspectRatio: result.aspectRatio,
        resolution: result.resolution,
        prompt: prompt,
        generationTime: DateTime.now().difference(started),
      );
      return ToolResult(
        callId: '',
        content: jsonEncode(finalResult.toJson()),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'success': false, 'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<String> _saveVideo(
    Uint8List bytes,
    String prompt,
    String? model,
  ) async {
    final dir = Directory(outputDirectory ?? config.outputDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safePrompt = prompt
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final filename =
        '${timestamp}_${safePrompt.substring(0, min(50, safePrompt.length))}_${model ?? 'unknown'}.mp4';
    final path = p.join(dir.path, filename);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  Future<List<String>> listModels() => provider.listModels();
}

/// Factory for creating video generation tools.
class VideoGenerationToolFactory {
  static Tool create({
    String provider = 'fal',
    required String apiKey,
    String? outputDirectory,
    VideoGenerationConfig config = const VideoGenerationConfig(),
  }) {
    switch (provider.toLowerCase()) {
      case 'fal':
        return VideoGenerationTool(
          provider: FalVideoGenerationProvider(
            apiKey: apiKey,
            config: config,
          ),
          config: config,
          outputDirectory: outputDirectory,
        );
      default:
        throw ArgumentError('Unsupported video provider: $provider');
    }
  }
}
