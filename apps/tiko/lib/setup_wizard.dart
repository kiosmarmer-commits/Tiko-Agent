import 'dart:io';

import 'package:agent_providers/agent_providers.dart';
import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:tiko_tui/tiko_tui.dart';

typedef SetupProbeFn = Future<ProbeOutcome> Function({
  required String providerType,
  String? baseUrl,
  String? apiKey,
});

typedef SetupLocalOllamaFn =
    Future<(OnboardingSuggestion, List<String>)?> Function();

typedef SetupCheckDepsFn =
    Future<List<DependencyReport>> Function(List<String> commands);

/// Depedensi eksternal wizard onboarding agar alur jaringan/process dapat
/// di-mock penuh di test. Bawaan menjalankan probe + `which` sungguhan.
class SetupWizardDeps {
  const SetupWizardDeps({this.probe, this.probeOllama, this.checkDependencies});

  final SetupProbeFn? probe;
  final SetupLocalOllamaFn? probeOllama;
  final SetupCheckDepsFn? checkDependencies;

  SetupProbeFn get resolveProbe => probe ?? _defaultProbe;
  SetupLocalOllamaFn get resolveProbeOllama =>
      probeOllama ?? OnboardingProbe.probeLocalOllama;
  SetupCheckDepsFn get resolveCheckDependencies =>
      checkDependencies ?? OnboardingAssist.checkDependencies;

  static Future<ProbeOutcome> _defaultProbe({
    required String providerType,
    String? baseUrl,
    String? apiKey,
  }) => OnboardingProbe.probe(
        providerType: providerType,
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
}

/// Maksimum model live yang ditampilkan dalam menu pilihan model.
const kSetupMaxModelChoices = 10;

const _securityChoices = ['auto', 'guided', 'ask', 'deny'];

/// Onboarding wizard terpandu penuh (Hermes S10):
/// 1) deteksi provider otomatis (env API key + daemon Ollama lokal),
/// 2) test connection + live model discovery per provider,
/// 3) rekomendasi mode keamanan (auto untuk runtime lokal, guided cloud),
/// 4) wizard workspace (buat direktori bila perlu) + pemeriksaan dependency,
/// 5) recovery: config invalid di awal ditawari rollback revisi; verifikasi
///    pasca-tulis memulihkan otomatis ke revisi valid terakhir bila gagal.
///
/// Return kode keluar: 0 sukses, 1 dibatalkan/gagal, 2 input tidak valid.
/// PromptAborted dilempar apa adanya untuk penangan CLI (Ctrl+C/EOF).
Future<int> runSetupWizard({
  required String configPath,
  required bool force,
  PromptRunner? prompts,
  Map<String, String>? environment,
  SetupWizardDeps deps = const SetupWizardDeps(),
  StringSink? out,
}) async {
  final sink = out ?? stdout;
  void say([String message = '']) => sink.writeln(message);
  final runner = prompts ?? PromptRunner();
  final env = environment ?? Platform.environment;

  try {
    say('Wizard onboarding Tiko — kredensial disimpan sebagai SecretRef');
    say('env:VAR di config, nilai rahasianya di gateway.env (permission 600).');
    say('');

    final configAbs = p.absolute(configPath);
    final configDir = p.dirname(configAbs);
    final projectRoot = p.basename(configDir) == 'config'
        ? p.dirname(configDir)
        : configDir;
    final dataDir = p.join(projectRoot, 'data');
    final revisionsDir = p.join(dataDir, 'config_revisions');

    // Step 0 — recovery konfigurasi gagal (config sudah ada).
    final start = await _startExistingConfig(
      runner: runner,
      say: say,
      configPath: configPath,
    );
    if (!start.ok) return 1;
    final overwriteAgreed = force || start.overwrite;

    // Step 1 — deteksi provider otomatis.
    final (providerType, detectedVar) = await _pickProvider(
      runner,
      say,
      deps,
      env,
    );

    final needsKey = !const {
      'mock',
      'ollama',
      'ollama_native',
    }.contains(providerType);

    final collected = <String, String>{};
    String? baseUrl;
    String? apiKeyForProbe;
    String? apiKeyEnvVar;

    if (needsKey) {
      final keyVar = OnboardingProfile.defaultApiKeyVar(providerType);
      final defaultBase = OnboardingProbe.defaultBaseUrl(providerType);
      final rawBase = await runner.prompt(
        'base_url (kosongkan untuk default preset [$defaultBase])',
      );
      baseUrl = rawBase.trim().isEmpty ? null : rawBase.trim();
      apiKeyEnvVar = keyVar;
      final envValue = env[keyVar] ?? '';
      if (detectedVar == keyVar && envValue.isNotEmpty) {
        say('API key terdeteksi di env $keyVar (nilainya tidak ditampilkan).');
        if (await runner.confirm(
          'Pakai dari environment tanpa menulis ulang ke gateway.env?',
        )) {
          apiKeyForProbe = envValue;
        }
      }
      if (apiKeyForProbe == null) {
        collected[keyVar] =
            await runner.prompt('API key ($keyVar)', required: true);
        apiKeyForProbe = collected[keyVar]!;
      }
    }

    // Step 2 — test connection (sekaligus live model discovery).
    var probed = const ProbeOutcome(ok: true, detail: '', probed: false);
    if (needsKey || providerType == 'ollama' || providerType == 'ollama_native') {
      while (true) {
        say('Menguji koneksi $providerType…');
        probed = await deps.resolveProbe(
          providerType: providerType,
          baseUrl: baseUrl,
          apiKey: apiKeyForProbe,
        );
        if (!probed.probed || probed.ok) {
          say('  ${probed.ok ? '✓' : '·'} ${probed.detail}');
          break;
        }
        say('  ✗ ${probed.detail}');
        final action = await runner.select(
          'Koneksi gagal — lanjut bagaimana?',
          const [
            'Ulangi probe',
            'Isi model manual & lewati test',
            'Ganti base_url',
            'Batal',
          ],
          def: 'Ulangi probe',
        );
        if (action.startsWith('Batal')) {
          say('Wizard dibatalkan; tidak ada yang ditulis.');
          return 1;
        }
        if (action.startsWith('Isi model manual')) break;
        if (action.startsWith('Ganti')) {
          baseUrl = await runner.prompt('base_url baru', required: true);
        }
      }
    }

    // Step 3 — pilih model (list live bila discovery berhasil).
    final model = await _pickModel(
      runner,
      say,
      providerType,
      probed.models,
    );

    // Step 4 — rekomendasi mode keamanan.
    final securityMode = await _pickSecurityMode(runner, say, providerType);

    // Step 5 — wizard workspace.
    final workspace = await _pickWorkspace(runner, say);

    // Step 6 — pemeriksaan dependency lokal.
    final depCommands = [
      'git',
      if (providerType == 'ollama' || providerType == 'ollama_native') 'ollama',
    ];
    say('Memeriksa dependency lokal: ${depCommands.join(', ')}…');
    for (final report
        in await deps.resolveCheckDependencies(depCommands)) {
      if (report.found) {
        say('  ✓ ${report.command} — ${report.detail}');
      } else {
        say('  ⚠ ${report.command} tidak ditemukan — fitur terkait dinonaktifkan.');
      }
    }

    // Step 7 — kredensial gateway (disimpan di gateway.env).
    if (await runner.confirm('Aktifkan gateway Telegram?')) {
      collected['TG_TOKEN'] =
          await runner.prompt('TG_TOKEN', required: true);
      collected['TG_ALLOW'] = await runner.prompt(
        'TG_ALLOW (id user, dipisah koma)',
        required: true,
      );
    }
    if (await runner.confirm('Aktifkan gateway Discord?')) {
      collected['DISCORD_BOT_TOKEN'] =
          await runner.prompt('DISCORD_BOT_TOKEN', required: true);
      final allow =
          await runner.prompt('DISCORD_ALLOW (id user, dipisah koma)');
      if (allow.isNotEmpty) collected['DISCORD_ALLOW'] = allow;
    }
    if (await runner.confirm('Aktifkan email SMTP (outbound)?')) {
      collected['EMAIL_FROM'] =
          await runner.prompt('EMAIL_FROM', required: true);
      collected['SMTP_HOST'] =
          await runner.prompt('SMTP_HOST', required: true);
      collected['SMTP_PORT'] = await runner.prompt('SMTP_PORT', def: '587');
      final smtpUser = await runner.prompt('SMTP_USER');
      if (smtpUser.isNotEmpty) {
        collected['SMTP_USER'] = smtpUser;
        collected['SMTP_PASS'] =
            await runner.prompt('SMTP_PASS', required: true);
        collected['SMTP_STARTTLS'] = '1';
      }
      final emailAllow =
          await runner.prompt('EMAIL_ALLOW (tujuan diizinkan, dipisah koma)');
      if (emailAllow.isNotEmpty) collected['EMAIL_ALLOW'] = emailAllow;
    }
    if (await runner.confirm('Aktifkan email inbound IMAP?')) {
      collected['IMAP_HOST'] =
          await runner.prompt('IMAP_HOST', required: true);
      collected['IMAP_PORT'] = await runner.prompt('IMAP_PORT', def: '993');
      collected['IMAP_USER'] =
          await runner.prompt('IMAP_USER', required: true);
      collected['IMAP_PASSWORD'] =
          await runner.prompt('IMAP_PASSWORD', required: true);
      collected['IMAP_ALLOW'] = await runner.prompt(
        'IMAP_ALLOW (pengirim diizinkan)',
        required: true,
      );
    }

    // Step 8 — ringkasan + konfirmasi.
    final profile = OnboardingProfile(
      providerType: providerType,
      workspace: workspace,
      baseUrl: baseUrl,
      model: model,
      apiKeyEnvVar: apiKeyEnvVar,
      securityMode: securityMode,
      env: collected,
    );
    say('');
    say('Ringkasan:');
    say('  provider    : $providerType');
    say('  base_url    : ${profile.baseUrl ?? '(default preset)'}');
    say('  model       : ${profile.model ?? '(default preset)'}');
    say('  keamanan    : $securityMode');
    say('  workspace   : $workspace');
    say('  gateway.env : ${collected.length} variabel rahasia');
    if (apiKeyEnvVar != null && !collected.containsKey(apiKeyEnvVar)) {
      say('  API key     : dipakai dari env $apiKeyEnvVar (tidak ditulis)');
    }
    if (!await runner.confirm('Lanjut simpan config?')) {
      say('Wizard dibatalkan; tidak ada yang ditulis.');
      return 1;
    }

    // Step 9 — tulis, verifikasi, recovery otomatis bila hasil korup.
    final paths = await OnboardingWizard.writeAll(
      configPath: configPath,
      dataDir: dataDir,
      profile: profile,
      force: overwriteAgreed,
    );
    say('');
    say('✓ Config disimpan: ${paths.configPath}');
    say('✓ Env file disimpan: ${paths.envPath} (permission 600)');

    final recovery = await OnboardingRecovery.verifyAndRecover(
      configPath: paths.configPath,
      revisionsDir: revisionsDir,
    );
    if (!recovery.ok) {
      say('⚠ Verifikasi pasca-tulis GAGAL: '
          '${recovery.issues.where((i) => i.fatal).join('; ')}');
      say('  Periksa revisi di: $revisionsDir');
    } else if (recovery.rolledBackTo != null) {
      say('⚠ Config hasil wizard tidak valid; dipulihkan otomatis: ${recovery.detail}');
    } else {
      say('  ✓ Verifikasi pasca-tulis: config valid.');
    }

    say('');
    say('Lanjut:');
    say('  source ${paths.envPath}');
    say('  tiko doctor --probe && tiko chat');
    return 0;
  } on PromptAborted {
    rethrow;
  } on StateError catch (error) {
    say('✗ GAGAL menyimpan: ${error.message}');
    say('Tidak ada perubahan yang selesai; jalankan ulang wizard.');
    return 1;
  } on ArgumentError catch (error) {
    say('✗ GAGAL: ${error.message ?? error}');
    return 2;
  }
}

final class _StartResult {
  const _StartResult({this.ok = true, this.overwrite = false});
  final bool ok;
  final bool overwrite;
}

Future<_StartResult> _startExistingConfig({
  required PromptRunner runner,
  required void Function([String]) say,
  required String configPath,
}) async {
  final file = File(configPath);
  if (!file.existsSync()) return const _StartResult();
  final (_, issues) = TikoConfig.load(configPath);
  final fatal = issues.where((issue) => issue.fatal).toList();
  if (fatal.isEmpty) {
    say('Config valid ditemukan: ${p.absolute(configPath)}');
    if (!await runner.confirm(
      'Lanjutkan wizard dan timpa config saat selesai?',
    )) {
      say('Wizard dibatalkan; config tidak diubah.');
      return const _StartResult(ok: false);
    }
    return const _StartResult(overwrite: true);
  }
  say('Config sudah ada tetapi TIDAK VALID:');
  for (final issue in fatal) {
    say('  $issue');
  }
  final choice = await runner.select(
    'Recovery konfigurasi gagal — pilih tindakan:',
    const [
      'Pulihkan dari revisi terakhir (rollback otomatis)',
      'Abaikan & tulis ulang lewat wizard (revisi baru)',
      'Batal',
    ],
    def: 'Pulihkan dari revisi terakhir (rollback otomatis)',
  );
  if (choice.startsWith('Batal')) {
    say('Wizard dibatalkan; config tidak diubah.');
    return const _StartResult(ok: false);
  }
  if (choice.startsWith('Pulihkan')) {
    final configDir = p.dirname(p.absolute(configPath));
    final projectRoot = p.basename(configDir) == 'config'
        ? p.dirname(configDir)
        : configDir;
    final recovery = await OnboardingRecovery.verifyAndRecover(
      configPath: configPath,
      revisionsDir: p.join(projectRoot, 'data', 'config_revisions'),
    );
    say(
      recovery.ok
          ? '  ✓ ${recovery.detail}'
          : '  ✗ ${recovery.detail}',
    );
    return const _StartResult(ok: false);
  }
  return const _StartResult(overwrite: true);
}

/// Step 1: kandidat provider dari env + daemon Ollama lokal + fallback mock.
/// Return (providerType, apiKeyEnvVar hasil deteksi bila ada).
Future<(String, String?)> _pickProvider(
  PromptRunner runner,
  void Function([String]) say,
  SetupWizardDeps deps,
  Map<String, String> env,
) async {
  final candidates = <OnboardingSuggestion>[];
  void add(OnboardingSuggestion suggestion) {
    if (!candidates.any((c) => c.providerType == suggestion.providerType)) {
      candidates.add(suggestion);
    }
  }

  for (final detected in OnboardingProbe.detectFromEnv(env)) {
    add(detected);
  }
  final ollama = await deps.resolveProbeOllama();
  if (ollama != null) add(ollama.$1);
  add(const OnboardingSuggestion(
    providerType: 'mock',
    label: 'Mock (tanpa jaringan)',
    reason: 'fallback pengujian lokal',
  ));

  if (candidates.length > 1) {
    say('Deteksi otomatis provider:');
    for (final candidate in candidates) {
      say(
        '  · ${candidate.label} (${candidate.providerType}) — ${candidate.reason}',
      );
    }
    say('');
  }
  final display = [
    for (final c in candidates) '${c.label} (${c.providerType})',
  ];
  final chosen =
      await runner.select('Tipe provider:', display, def: display.first);
  final idx = display.indexOf(chosen);
  if (idx < 0) return ('mock', null);
  return (candidates[idx].providerType, candidates[idx].apiKeyEnvVar);
}

Future<String?> _pickModel(
  PromptRunner runner,
  void Function([String]) say,
  String providerType,
  List<String> liveModels,
) async {
  final preset = findProviderPreset(providerType);
  final defaultModel = preset?.defaultModel;
  String? model;
  if (liveModels.isNotEmpty) {
    say('Model live ditemukan (${liveModels.length}) via discovery.');
    final choices = [
      ...liveModels.take(kSetupMaxModelChoices),
      'Ketik model lain…',
    ];
    final preferred =
        defaultModel != null && liveModels.contains(defaultModel)
            ? defaultModel
            : liveModels.first;
    final chosen = await runner.select(
      'Pilih model:',
      choices,
      def: choices.contains(preferred) ? preferred : choices.first,
    );
    if (chosen == 'Ketik model lain…') {
      final manual = await runner.prompt(
        'model (kosongkan untuk default preset [${defaultModel ?? 'tidak diketahui'}])',
        def: defaultModel,
      );
      model = manual.isEmpty ? null : manual;
    } else {
      model = chosen;
    }
  } else {
    final manual = await runner.prompt(
      'model (kosongkan untuk default preset [${defaultModel ?? 'tidak diketahui'}])',
      def: defaultModel,
    );
    model = manual.isEmpty ? null : manual;
  }
  say('Model dipilih: ${model ?? defaultModel ?? '(default runtime)'}');
  return model;
}

Future<String> _pickSecurityMode(
  PromptRunner runner,
  void Function([String]) say,
  String providerType,
) async {
  final recommended = OnboardingProbe.recommendSecurityMode(providerType);
  say('');
  say('Mode keamanan — rekomendasi wizard: $recommended'
      ' (${recommended == 'auto' ? 'runtime lokal, risiko rendah' : 'endpoint cloud, konfirmasi tetap aktif'})');
  final display = [
    for (final mode in _securityChoices)
      '$mode${mode == recommended ? ' (rekomendasi)' : ''}',
  ];
  final chosen = await runner.select(
    'Pilih mode keamanan:',
    display,
    def: display.firstWhere((d) => d.startsWith('$recommended ')),
  );
  return RegExp(r'^(\w+)').firstMatch(chosen)?.group(1) ?? 'ask';
}

Future<String> _pickWorkspace(
  PromptRunner runner,
  void Function([String]) say,
) async {
  while (true) {
    final workspace = await runner.prompt(
      'Workspace (direktori kerja agent)',
      def: '.',
      required: true,
    );
    final dir = Directory(workspace);
    if (dir.existsSync()) return workspace;
    if (await runner.confirm('Direktori "$workspace" belum ada. Buat?')) {
      try {
        await dir.create(recursive: true);
        say('  ✓ direktori dibuat: $workspace');
        return workspace;
      } catch (error) {
        say('  ✗ gagal membuat direktori: $error');
      }
    } else {
      say('  Pilih direktori lain.');
    }
  }
}
