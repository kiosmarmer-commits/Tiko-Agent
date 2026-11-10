import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:agent_core/agent_core.dart';

/// Vision provider configuration
class VisionProvider {
  const VisionProvider({
    required this.name,
    required this.baseUrl,
    required this.apiKeyEnvVar,
    this.defaultModel,
    this.timeout = const Duration(seconds: 60),
    this.maxRetries = 3,
    this.supportsImagePaste = true,
    this.supportsImageAnalysis = true,
    this.supportsOcr = true,
  });

  final String name;
  final String baseUrl;
  final String apiKeyEnvVar;
  final String? defaultModel;
  final Duration timeout;
  final int maxRetries;
  final bool supportsImagePaste;
  final bool supportsImageAnalysis;
  final bool supportsOcr;
}

/// Configuration for vision capabilities
class VisionConfig {
  const VisionConfig({
    this.enabled = true,
    this.defaultProvider = 'openai',
    this.providers = const [
      VisionProvider(
        name: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKeyEnvVar: 'OPENAI_API_KEY',
        defaultModel: 'gpt-4-vision-preview',
        supportsImagePaste: true,
        supportsImageAnalysis: true,
        supportsOcr: true,
      ),
      VisionProvider(
        name: 'anthropic',
        baseUrl: 'https://api.anthropic.com/v1',
        apiKeyEnvVar: 'ANTHROPIC_API_KEY',
        defaultModel: 'claude-3-haiku-20240307',
        supportsImagePaste: true,
        supportsImageAnalysis: true,
        supportsOcr: true,
      ),
    ],
    this.clipboardEnabled = true,
    this.imageCacheEnabled = true,
    this.imageCacheDirectory = 'vision_cache',
    this.maxImageSize = 10 * 1024 * 1024, // 10MB
    this.allowedImageFormats = const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
  });

  final bool enabled;
  final String defaultProvider;
  final List<VisionProvider> providers;
  final bool clipboardEnabled;
  final bool imageCacheEnabled;
  final String imageCacheDirectory;
  final int maxImageSize;
  final List<String> allowedImageFormats;

  /// Get provider by name
  VisionProvider? getProvider(String name) {
    try {
      return providers.firstWhere((p) => p.name == name);
    } catch (e) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'defaultProvider': defaultProvider,
        'providers': providers.map((p) => p.toJson()).toList(),
        'clipboardEnabled': clipboardEnabled,
        'imageCacheEnabled': imageCacheEnabled,
        'imageCacheDirectory': imageCacheDirectory,
        'maxImageSize': maxImageSize,
        'allowedImageFormats': allowedImageFormats,
      };

  factory VisionConfig.fromJson(Map<String, dynamic> json) {
    return VisionConfig(
      enabled: json['enabled'] as bool? ?? true,
      defaultProvider: json['defaultProvider'] as String? ?? 'openai',
      providers: (json['providers'] as List<dynamic>? ?? [])
          .map((p) => VisionProvider.fromJson(p as Map<String, dynamic>))
          .toList(),
      clipboardEnabled: json['clipboardEnabled'] as bool? ?? true,
      imageCacheEnabled: json['imageCacheEnabled'] as bool? ?? true,
      imageCacheDirectory: json['imageCacheDirectory'] as String? ?? 'vision_cache',
      maxImageSize: json['maxImageSize'] as int? ?? 10 * 1024 * 1024,
      allowedImageFormats: (json['allowedImageFormats'] as List<dynamic>? ?? [])
          .map((f) => f.toString())
          .toList(),
    );
  }
}

/// Abstract interface for vision providers
abstract class VisionProviderInterface {
  String get name;

  /// Analyze an image and return a description
  Future<VisionResult> analyzeImage({
    required Uint8List imageBytes,
    String? prompt,
    String? model,
  });

  /// Extract text from an image (OCR)
  Future<OcrResult> extractText({
    required Uint8List imageBytes,
    String? model,
    String? language,
  });

  /// Describe an image
  Future<VisionResult> describeImage(Uint8List imageBytes, {String? model});

  /// List available models
  Future<List<String>> listModels();
}

/// Result of vision analysis
class VisionResult {
  const VisionResult({
    required this.success,
    this.description,
    this.objects,
    this.colors,
    this.text,
    this.model,
    this.provider,
    this.error,
    this.confidence,
    this.generationTime,
  });

  final bool success;
  final String? description;
  final List<DetectedObject>? objects;
  final List<String>? colors;
  final String? text;
  final String? model;
  final String? provider;
  final String? error;
  final double? confidence;
  final Duration? generationTime;

  Map<String, dynamic> toJson() => {
        'success': success,
        'description': description,
        'objects': objects?.map((o) => o.toJson()).toList(),
        'colors': colors,
        'text': text,
        'model': model,
        'provider': provider,
        'error': error,
        'confidence': confidence,
        'generationTime': generationTime?.inMilliseconds,
      };
}

/// Detected object in vision analysis
class DetectedObject {
  const DetectedObject({
    required this.name,
    required this.confidence,
    this.boundingBox,
    this.category,
  });

  final String name;
  final double confidence;
  final BoundingBox? boundingBox;
  final String? category;

  Map<String, dynamic> toJson() => {
        'name': name,
        'confidence': confidence,
        'boundingBox': boundingBox?.toJson(),
        'category': category,
      };
}

/// Bounding box for detected objects
class BoundingBox {
  const BoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

/// Result of OCR (text extraction)
class OcrResult {
  const OcrResult({
    required this.success,
    this.text,
    this.language,
    this.model,
    this.provider,
    this.error,
    this.confidence,
    this.lines,
    this.words,
    this.generationTime,
  });

  final bool success;
  final String? text;
  final String? language;
  final String? model;
  final String? provider;
  final String? error;
  final double? confidence;
  final List<String>? lines;
  final List<OcrWord>? words;
  final Duration? generationTime;

  Map<String, dynamic> toJson() => {
        'success': success,
        'text': text,
        'language': language,
        'model': model,
        'provider': provider,
        'error': error,
        'confidence': confidence,
        'lines': lines,
        'words': words?.map((w) => w.toJson()).toList(),
        'generationTime': generationTime?.inMilliseconds,
      };
}

/// Detected word in OCR
class OcrWord {
  const OcrWord({
    required this.text,
    required this.boundingBox,
    this.confidence,
  });

  final String text;
  final BoundingBox boundingBox;
  final double? confidence;

  Map<String, dynamic> toJson() => {
        'text': text,
        'boundingBox': boundingBox.toJson(),
        'confidence': confidence,
      };
}

/// OpenAI Vision provider implementation
class OpenAIVisionProvider implements VisionProviderInterface {
  OpenAIVisionProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.timeout = const Duration(seconds: 60),
    this.maxRetries = 3,
    this.httpClient,
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final int maxRetries;
  final http.Client? httpClient;

  @override
  String get name => 'openai';

  @override
  Future<VisionResult> analyzeImage({
    required Uint8List imageBytes,
    String? prompt,
    String? model,
  }) async {
    final client = httpClient ?? http.Client();
    
    try {
      // Convert image to base64
      final imageBase64 = base64Encode(imageBytes);
      
      // Build the request
      final requestBody = {
        'model': model ?? 'gpt-4-vision-preview',
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': prompt ?? 'Describe this image in detail',
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
              },
            ],
          },
        ],
        'max_tokens': 1000,
      };
      
      final response = await client.post(
        Uri.parse('$baseUrl/chat/completions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(timeout);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final content = data['choices']?[0]['message']['content'] as String? ?? '';
        
        return VisionResult(
          success: true,
          description: content,
          model: model ?? 'gpt-4-vision-preview',
          provider: name,
          generationTime: Duration(milliseconds: data['usage']?['total_tokens'] ?? 0),
        );
      } else {
        return VisionResult(
          success: false,
          error: 'OpenAI API error: ${response.statusCode} - ${response.body}',
          provider: name,
          model: model,
        );
      }
    } catch (e) {
      return VisionResult(
        success: false,
        error: 'Failed to analyze image: ${e.toString()}',
        provider: name,
        model: model,
      );
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  @override
  Future<OcrResult> extractText({
    required Uint8List imageBytes,
    String? model,
    String? language,
  }) async {
    final client = httpClient ?? http.Client();
    
    try {
      // Convert image to base64
      final imageBase64 = base64Encode(imageBytes);
      
      // Build the request for OCR
      final requestBody = {
        'model': model ?? 'gpt-4-vision-preview',
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': 'Extract all text from this image. Return only the text without any description or commentary.',
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
              },
            ],
          },
        ],
        'max_tokens': 2000,
      };
      
      final response = await client.post(
        Uri.parse('$baseUrl/chat/completions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(timeout);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final content = data['choices']?[0]['message']['content'] as String? ?? '';
        
        return OcrResult(
          success: true,
          text: content,
          language: language,
          model: model ?? 'gpt-4-vision-preview',
          provider: name,
          generationTime: Duration(milliseconds: data['usage']?['total_tokens'] ?? 0),
        );
      } else {
        return OcrResult(
          success: false,
          error: 'OpenAI API error: ${response.statusCode} - ${response.body}',
          provider: name,
          model: model,
        );
      }
    } catch (e) {
      return OcrResult(
        success: false,
        error: 'Failed to extract text: ${e.toString()}',
        provider: name,
        model: model,
      );
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  @override
  Future<VisionResult> describeImage(Uint8List imageBytes, {String? model}) async {
    return await analyzeImage(
      imageBytes: imageBytes,
      prompt: 'Describe this image in detail including objects, colors, and any text.',
      model: model,
    );
  }

  @override
  Future<List<String>> listModels() async {
    return [
      'gpt-4-vision-preview',
      'gpt-4o',
      'gpt-4o-mini',
    ];
  }
}

/// Tool for vision capabilities (image analysis, OCR, description)
class VisionTool implements Tool {
  VisionTool({
    required this.provider,
    required this.config,
    this.outputDirectory,
    this.maxRetries = 3,
  });

  final VisionProviderInterface provider;
  final VisionConfig config;
  final String? outputDirectory;
  final int maxRetries;

  @override
  String get name => 'vision';

  @override
  String get description =>
      'Analyze images, extract text (OCR), and describe visual content. '
      'Supports image paste from clipboard, file paths, URLs, and base64 encoded images.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['analyze', 'describe', 'ocr', 'detect_objects'],
              'description': 'The vision action to perform',
            },
            'image': {
              'type': 'string',
              'description': 'Image source: file path, URL, base64, or clipboard',
            },
            'image_base64': {
              'type': 'string',
              'description': 'Base64 encoded image data',
            },
            'prompt': {
              'type': 'string',
              'description': 'Custom prompt for analysis (for analyze action)',
            },
            'model': {
              'type': 'string',
              'description': 'Model to use for vision',
            },
            'language': {
              'type': 'string',
              'description': 'Language hint for OCR',
            },
            'save_to_file': {
              'type': 'boolean',
              'description': 'Whether to save the image to a file',
              'default': false,
            },
          },
          'required': ['action'],
        },
        outputSchema: {
          'type': 'object',
          'properties': {
            'success': {'type': 'boolean'},
            'description': {'type': 'string'},
            'text': {'type': 'string'},
            'objects': {'type': 'array'},
            'colors': {'type': 'array'},
            'model': {'type': 'string'},
            'error': {'type': 'string'},
          },
        },
        risk: 'medium',
        parallelSafe: false,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final startTime = DateTime.now();
    
    try {
      // Parse action
      final action = args['action'] as String? ?? 'analyze';
      
      // Get image data
      final imageData = await _getImageData(args);
      if (imageData == null) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'No image data provided. Use image, image_base64, or clipboard.',
          }),
          isError: true,
        );
      }

      // Perform the requested action
      switch (action) {
        case 'analyze':
        case 'describe':
          final prompt = args['prompt'] as String?;
          final model = args['model'] as String?;
          final result = await provider.analyzeImage(
            imageBytes: imageData,
            prompt: action == 'analyze' ? prompt : null,
            model: model,
          );
          return _createResult(result, startTime);

        case 'ocr':
          final language = args['language'] as String?;
          final model = args['model'] as String?;
          final result = await provider.extractText(
            imageBytes: imageData,
            model: model,
            language: language,
          );
          return _createOcrResult(result, startTime);

        case 'detect_objects':
          final model = args['model'] as String?;
          final result = await provider.describeImage(
            imageData,
            model: model,
          );
          return _createResult(result, startTime);

        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'success': false,
              'error': 'Unknown action: $action',
            }),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        isError: true,
      );
    }
  }

  /// Get image data from various sources
  Future<Uint8List?> _getImageData(Map<String, dynamic> args) async {
    // Try image_base64 first
    if (args.containsKey('image_base64')) {
      final base64 = args['image_base64'] as String?;
      if (base64 != null && base64.isNotEmpty) {
        try {
          return base64Decode(base64);
        } catch (e) {
          return null;
        }
      }
    }

    // Try image path/URL
    if (args.containsKey('image')) {
      final imageSource = args['image'] as String?;
      if (imageSource != null && imageSource.isNotEmpty) {
        // Check if it's a file path
        if (await File(imageSource).exists()) {
          return await File(imageSource).readAsBytes();
        }
        
        // Check if it's a URL
        if (Uri.tryParse(imageSource)?.isAbsolute == true) {
          try {
            final response = await http.get(Uri.parse(imageSource));
            if (response.statusCode == 200) {
              return response.bodyBytes;
            }
          } catch (e) {
            return null;
          }
        }
        
        // Check if it's base64 (without prefix)
        try {
          return base64Decode(imageSource);
        } catch (e) {
          return null;
        }
      }
    }

    // Try clipboard (platform-specific)
    if (config.clipboardEnabled) {
      try {
        final clipboardData = await _getClipboardImage();
        if (clipboardData != null) {
          return clipboardData;
        }
      } catch (e) {
        // Clipboard not available
      }
    }

    return null;
  }

  /// Get image from clipboard (platform-specific)
  /// This is a placeholder - actual implementation depends on platform
  Future<Uint8List?> _getClipboardImage() async {
    // In a real implementation, this would use platform-specific APIs
    // For now, return null
    return null;
  }

  /// Create tool result from vision result
  ToolResult _createResult(VisionResult result, DateTime startTime) {
    final json = result.toJson();
    json['generationTime'] = result.generationTime?.inMilliseconds;
    
    return ToolResult(
      callId: '',
      content: jsonEncode(json),
      isError: !result.success,
    );
  }

  /// Create tool result from OCR result
  ToolResult _createOcrResult(OcrResult result, DateTime startTime) {
    final json = result.toJson();
    json['generationTime'] = result.generationTime?.inMilliseconds;
    
    return ToolResult(
      callId: '',
      content: jsonEncode(json),
      isError: !result.success,
    );
  }

  /// List available models
  Future<List<String>> listModels() async {
    return await provider.listModels();
  }
}

/// Tool for pasting images from clipboard
class ImagePasteTool implements Tool {
  ImagePasteTool({
    required this.visionTool,
    this.outputDirectory,
  });

  final VisionTool visionTool;
  final String? outputDirectory;

  @override
  String get name => 'paste_image';

  @override
  String get description =>
      'Paste an image from the clipboard and optionally analyze it. '
      'The image can be from screenshot, copy-paste, or drag-and-drop.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'analyze': {
              'type': 'boolean',
              'description': 'Whether to analyze the image after pasting',
              'default': false,
            },
            'prompt': {
              'type': 'string',
              'description': 'Custom prompt for analysis (if analyze is true)',
            },
            'save_to_file': {
              'type': 'boolean',
              'description': 'Whether to save the image to a file',
              'default': true,
            },
          },
        },
        outputSchema: {
          'type': 'object',
          'properties': {
            'success': {'type': 'boolean'},
            'imagePath': {'type': 'string'},
            'imageBase64': {'type': 'string'},
            'description': {'type': 'string'},
            'error': {'type': 'string'},
          },
        },
        risk: 'medium',
        parallelSafe: false,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      // Get image from clipboard
      final clipboardData = await _getClipboardImage();
      
      if (clipboardData == null) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'No image found in clipboard',
          }),
          isError: true,
        );
      }

      // Save to file if requested
      String? imagePath;
      final saveToFile = args['save_to_file'] as bool? ?? true;
      if (saveToFile) {
        imagePath = await _saveImage(clipboardData);
      }

      // Analyze if requested
      String? description;
      final analyze = args['analyze'] as bool? ?? false;
      if (analyze) {
        final prompt = args['prompt'] as String?;
        final result = await visionTool.provider.analyzeImage(
          imageBytes: clipboardData,
          prompt: prompt,
        );
        description = result.description;
      }

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': true,
          'imagePath': imagePath,
          'imageBase64': base64Encode(clipboardData),
          'description': description,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        isError: true,
      );
    }
  }

  /// Get image from clipboard (platform-specific)
  Future<Uint8List?> _getClipboardImage() async {
    // In a real implementation, this would use platform-specific APIs
    // For Flutter: use clipboard package
    // For CLI: use platform-specific commands
    // For now, return null
    return null;
  }

  /// Save image to file
  Future<String> _saveImage(Uint8List imageBytes) async {
    final dir = Directory(outputDirectory ?? 'images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = 'clipboard_$timestamp.png';
    final path = p.join(dir.path, filename);

    final file = File(path);
    await file.writeAsBytes(imageBytes);

    return path;
  }
}

/// Factory for creating vision tools
class VisionToolFactory {
  static List<Tool> create({
    String provider = 'openai',
    String? apiKey,
    String? outputDirectory,
  }) {
    if (provider.toLowerCase() == 'openai') {
      if (apiKey == null || apiKey.isEmpty) {
        throw ArgumentError('OpenAI API key is required for OpenAI provider');
      }
      
      final visionProvider = OpenAIVisionProvider(apiKey: apiKey);
      final config = VisionConfig(
        defaultProvider: 'openai',
        outputDirectory: outputDirectory ?? 'vision_cache',
      );
      
      final visionTool = VisionTool(
        provider: visionProvider,
        config: config,
        outputDirectory: outputDirectory,
      );
      
      final imagePasteTool = ImagePasteTool(
        visionTool: visionTool,
        outputDirectory: outputDirectory,
      );
      
      return [visionTool, imagePasteTool];
    }
    
    throw ArgumentError('Unsupported provider: $provider');
  }
}

/// Extension for VisionConfig to support provider from JSON
extension VisionConfigProvider on VisionProvider {
  Map<String, dynamic> toJson() => {
        'name': name,
        'baseUrl': baseUrl,
        'apiKeyEnvVar': apiKeyEnvVar,
        'defaultModel': defaultModel,
        'timeout': timeout.inSeconds,
        'maxRetries': maxRetries,
        'supportsImagePaste': supportsImagePaste,
        'supportsImageAnalysis': supportsImageAnalysis,
        'supportsOcr': supportsOcr,
      };

  factory VisionProvider.fromJson(Map<String, dynamic> json) {
    return VisionProvider(
      name: json['name'] as String,
      baseUrl: json['baseUrl'] as String? ?? 'https://api.openai.com/v1',
      apiKeyEnvVar: json['apiKeyEnvVar'] as String? ?? 'OPENAI_API_KEY',
      defaultModel: json['defaultModel'] as String?,
      timeout: Duration(seconds: json['timeout'] as int? ?? 60),
      maxRetries: json['maxRetries'] as int? ?? 3,
      supportsImagePaste: json['supportsImagePaste'] as bool? ?? true,
      supportsImageAnalysis: json['supportsImageAnalysis'] as bool? ?? true,
      supportsOcr: json['supportsOcr'] as bool? ?? true,
    );
  }
}
