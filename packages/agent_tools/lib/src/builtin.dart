import 'dart:io';

import 'package:agent_calc/agent_calc.dart';
import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;
import 'package:path/path.dart' as p;
import 'prediksi_tool.dart';

import 'grep.dart';
import 'probe.dart';
import 'ssrf.dart';
import 'web_search.dart';
import 'path_safety.dart';
import 'sandbox.dart';
import 'readability.dart';
import 'browser_tool.dart';
import 'skill_bundle.dart';
import 'image_generation.dart';
import 'video_generation.dart';
import 'vision.dart';
import 'code_execution.dart';
import 'batch_processing.dart';
import 'api_server.dart';
import 'ide_integration.dart';

/// Built-in tools for M1 (complete set for DoD).
List<Tool> createBuiltinTools({
  String? workspaceRoot,
  SsrfGuard? ssrf,
  String searxngBaseUrl = 'http://127.0.0.1:8080',
  String? tavilyApiKey,
  bool enableWebSearch = true,
  SandboxRunner? sandbox,
  SkillRegistry? skillRegistry,
  String? falApiKey,
  String? openaiApiKey,
  ImageProvider? imageProvider,
  bool enableImageGeneration = false,
  VideoProvider? videoProvider,
  bool enableVideoGeneration = false,
  bool enableVision = false,
  bool enableContextFiles = true,
  bool enableContextReferences = true,
  bool enableCodeExecution = false,
  String? codeExecutionWorkingDirectory,
  bool enableBatchProcessing = false,
  String? batchProcessingWorkingDirectory,
  AgentLoop? agentLoop,
  bool enableApiServer = false,
  String? apiServerWorkingDirectory,
  int apiServerPort = 8080,
  String? apiServerAuthToken,
  bool enableIdeIntegration = false,
  String? ideIntegrationWorkingDirectory,
  String ideType = 'vscode',
  // New search provider API keys
  String? perplexityApiKey,
  String? keenableApiKey,
  String? xaiApiKey,
  String? openaiCodexApiKey,
  String? nousPortalApiKey,
  String? parallelApiKey,
  String? braveApiKey,
  String? exaApiKey,
  String? firecrawlApiKey,
}) {
  final root = workspaceRoot ?? Directory.current.path;
  final guard = ssrf ?? SsrfGuard();
  
  // Create skill bundle manager if skill registry is provided
  final bundleManager = skillRegistry != null
      ? SkillBundleManager(
          skillRegistry: skillRegistry,
          bundlesDirectory: p.join(root, 'bundles'),
        )
      : null;
  
  // Create context files manager
  final contextFilesManager = enableContextFiles
      ? ContextFilesManager(
          config: const ContextFilesConfig(
            enabled: true,
            searchPaths: ['.', '..'],
          ),
          workingDirectory: root,
        )
      : null;
  
  // Create context expander
  final contextExpander = enableContextReferences
      ? EnhancedContextExpander(
          workspaceRoot: root,
          contextFilesManager: contextFilesManager,
        )
      : null;
  
  return [
    ...createPrediksiTools(),
    DatetimeTool(),
    CalcTool(),
    ListDirTool(workspaceRoot: root),
    GrepTool(workspaceRoot: root),
    ProbeTool(workspaceRoot: root),
    ReadFileTool(workspaceRoot: root),
    WriteFileTool(workspaceRoot: root),
    ShellTool(
      sandbox:
          sandbox ?? SandboxRunner(kind: SandboxKind.none, workspacePath: root),
    ),
    WebFetchTool(ssrf: guard),
    BrowserTool(
      sandbox: sandbox,
      headless: true,
    ),
    if (bundleManager != null) SkillBundleTool(bundleManager),
    if (enableWebSearch)
      WebSearchTool(
        searxngBaseUrl: searxngBaseUrl,
        tavilyApiKey: tavilyApiKey,
        braveApiKey: braveApiKey,
        exaApiKey: exaApiKey,
        firecrawlApiKey: firecrawlApiKey,
        parallelApiKey: parallelApiKey,
        perplexityApiKey: perplexityApiKey,
        keenableApiKey: keenableApiKey,
        xaiApiKey: xaiApiKey,
        openaiCodexApiKey: openaiCodexApiKey,
        nousPortalApiKey: nousPortalApiKey,
        ssrf: guard,
      ),
  ];
}
