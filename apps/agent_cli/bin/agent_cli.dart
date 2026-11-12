import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:agent_security/agent_security.dart';

/// CLI interaktif M1 — mock atau Ollama lokal.
///
///   dart run apps/agent_cli/bin/agent_cli.dart
///   AGENT_PROVIDER=ollama dart run apps/agent_cli/bin/agent_cli.dart
Future<void> main(List<String> args) async {
  final useOllama =
      Platform.environment['AGENT_PROVIDER'] == 'ollama' ||
      args.contains('--ollama');

  stderr.writeln(
    'PERINGATAN: agent_cli adalah prototipe M1 (memory/session tidak persisten). '
    'Gunakan `dart run apps/tiko/bin/tiko.dart chat` untuk runtime utama.',
  );
  stdout.writeln('agent_cli v0.1 (M1, legacy)');
  stdout.writeln(
    useOllama
        ? 'Provider: Ollama OpenAI-compat (http://127.0.0.1:11434/v1)'
        : 'Provider: mock',
  );
  stdout.writeln('Perintah: /new  /status  /tools  /quit\n');

  final LlmProvider llm;
  if (useOllama) {
    final model = Platform.environment['OLLAMA_MODEL'] ?? 'qwen2.5:3b';
    llm = OpenAiCompatProvider(
      id: 'ollama_local',
      baseUrl:
          Platform.environment['OLLAMA_BASE'] ?? 'http://127.0.0.1:11434/v1',
      model: model,
    );
  } else {
    llm = MockLlmProvider(scenario: MockScenario.plain);
  }

  final workspace = Directory.current.path;
  final sandboxKind = await SandboxRunner.detect();
  final sandbox = SandboxRunner(kind: sandboxKind, workspacePath: workspace);
  final registry = ToolRegistry();
  registry.registerAll(
    createBuiltinTools(workspaceRoot: workspace, sandbox: sandbox),
  );

  final scriptRunner = ScriptToolRunner(toolsDir: 'tools', sandbox: sandbox);
  final scripts = await scriptRunner.loadAll();
  registry.registerAll(scripts);

  final gate = MatrixPermissionGate(
    mode: PermissionMode.ask,
    onConfirmRequest: (call, sess) async {
      stdout.writeln('');
      stdout.writeln('⚠️  Konfirmasi tool [${call.name}]');
      stdout.writeln('    args: ${call.args}');
      stdout.write('    izinkan? [y/N] ');
      final line = stdin.readLineSync()?.trim().toLowerCase();
      return line == 'y' || line == 'yes';
    },
  );

  final router = Router(providers: {llm.id: llm}, defaultProviderId: llm.id);

  final contextBuilder = ContextBuilder();
  final session = Session(
    id: 'cli-1',
    channel: 'cli',
    userKey: Platform.localHostname,
  );

  final loop = AgentLoop(
    router: router,
    contextBuilder: _CliContextBuilder(
      registry: registry,
      inner: contextBuilder,
    ),
    compactor: Compactor(),
    gate: gate,
    executor: RegistryToolExecutor(registry),
    memory: NoopMemory(),
    workspacePath: workspace,
    reply: (m, text) async {
      stdout.writeln('\nassistant> $text\n');
    },
    confirm: (call, sess) async {
      stdout.writeln('⚠️  Konfirmasi [${call.name}] ${call.args}? [y/N]');
      final line = stdin.readLineSync()?.trim().toLowerCase();
      return line == 'y' || line == 'yes';
    },
  );

  while (true) {
    stdout.write('you> ');
    final line = stdin.readLineSync();
    if (line == null) break;
    final text = line.trim();
    if (text.isEmpty) continue;
    if (text == '/quit' || text == '/exit') break;
    if (text == '/new') {
      session.summary = null;
      stdout.writeln('(sesi direset)');
      continue;
    }
    if (text == '/status') {
      stdout.writeln(
        'provider=${llm.id}  session=${session.id}  tools=${registry.names.length}',
      );
      continue;
    }
    if (text == '/tools') {
      for (final s in registry.specs) {
        stdout.writeln('  ${s.name} [${s.risk}] — ${s.description}');
      }
      continue;
    }

    if (llm is MockLlmProvider) {
      if (text.contains('waktu') || text.contains('tanggal')) {
        llm.scenario = MockScenario.singleTool;
      } else if (text.contains('hitung') || text.contains('calc')) {
        llm.scenario = MockScenario.multiTool;
      } else {
        llm.scenario = MockScenario.plain;
      }
    }

    final msg = InboundMessage(
      channel: 'cli',
      userKey: session.userKey,
      sessionKey: 'cli:${session.userKey}',
      text: text,
    );
    try {
      await loop.handle(msg, session);
    } catch (e, st) {
      stdout.writeln('error: $e');
      stderr.writeln(st);
    }
  }

  await scriptRunner.close();
  stdout.writeln('Sampai jumpa.');
}

class _CliContextBuilder extends ContextBuilder {
  _CliContextBuilder({required this.registry, required ContextBuilder inner})
    : super(systemPrompt: inner.systemPrompt, memory: inner.memory);

  final ToolRegistry registry;

  @override
  Future<AgentContext> build(
    Session session,
    InboundMessage m,
    RouteDecision route,
  ) async {
    final ctx = await super.build(session, m, route);
    return AgentContext(
      messages: ctx.messages,
      tools: registry.specs,
      session: ctx.session,
      systemPrompt: ctx.systemPrompt,
    );
  }
}
