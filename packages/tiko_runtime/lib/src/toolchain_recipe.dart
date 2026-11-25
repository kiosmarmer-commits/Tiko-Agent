part of 'tiko_runtime.dart';

// Fase F8.4 (docs/15 §9) — provisioning toolchain untuk registry 100 bahasa
// (F8.3b). `tiko doctor` memakai data ini untuk menjelaskan toolchain mana
// yang hilang, dan `tiko doctor --fix` untuk memasang via apt SETELAH
// konfirmasi user (human-in-loop; tidak pernah auto-install diam-diam).
// Bahasa unsupported (proprietari/GUI/mainframe) sengaja tidak punya resep.

/// Resep provisioning satu biner toolchain.
class ToolchainRecipe {
  const ToolchainRecipe({
    required this.bin,
    required this.languages,
    this.aptPackages = const [],
    this.manualHint,
  });

  /// Biner yang diprobe [LanguageRegistry.interpreterAvailable] / enum.
  final String bin;

  /// Bahasa registry/enum yang dilayani biner ini (untuk pesan doctor).
  final String languages;

  /// Paket apt (Debian/Ubuntu). Kosong = tidak ada paket baku.
  final List<String> aptPackages;

  /// Instruksi manual bila [aptPackages] kosong (URL installer ofisial).
  final String? manualHint;

  bool get installableViaApt => aptPackages.isNotEmpty;
}

/// Katalog resep toolchain — satu entri per biner interpreter/compiler yang
/// diprobe registry F8.3b ditambah enum inti F8.3.
const List<ToolchainRecipe> kToolchainRecipes = [
  ToolchainRecipe(
    bin: 'python3',
    languages: 'python',
    aptPackages: ['python3'],
  ),
  ToolchainRecipe(
    bin: 'node',
    languages: 'javascript/typescript',
    aptPackages: ['nodejs'],
  ),
  ToolchainRecipe(
    bin: 'bash',
    languages: 'bash/shell',
    aptPackages: ['bash'],
  ),
  ToolchainRecipe(
    bin: 'go',
    languages: 'go (golang)',
    aptPackages: ['golang-go'],
  ),
  ToolchainRecipe(
    bin: 'javac',
    languages: 'java/groovy',
    aptPackages: ['default-jdk'],
  ),
  ToolchainRecipe(
    bin: 'gcc',
    languages: 'c/assembly/objectivec',
    aptPackages: ['gcc'],
  ),
  ToolchainRecipe(
    bin: 'g++',
    languages: 'cpp',
    aptPackages: ['g++'],
  ),
  ToolchainRecipe(
    bin: 'rustc',
    languages: 'rust',
    aptPackages: ['rustc'],
  ),
  ToolchainRecipe(
    bin: 'dart',
    languages: 'dart',
    manualHint:
        'ikuti https://docs.flutter.dev/get-started/install atau '
        'https://dart.dev/get-dart (wajib ada di PATH sebelum tiko dijalankan)',
  ),
  ToolchainRecipe(
    bin: 'sqlite3',
    languages: 'sql',
    aptPackages: ['sqlite3'],
  ),
  ToolchainRecipe(
    bin: 'pwsh',
    languages: 'powershell',
    manualHint:
        'ikuti https://learn.microsoft.com/powershell/scripting/install '
        '(repo packages.microsoft.com)',
  ),
  ToolchainRecipe(
    bin: 'Rscript',
    languages: 'r',
    aptPackages: ['r-base'],
  ),
  ToolchainRecipe(
    bin: 'ruby',
    languages: 'ruby',
    aptPackages: ['ruby'],
  ),
  ToolchainRecipe(
    bin: 'lua',
    languages: 'lua',
    aptPackages: ['lua5.4'],
    manualHint:
        'paket apt menyediakan biner lua5.4 — symlink ke `lua` bila registry '
        'tetap menolak',
  ),
  ToolchainRecipe(
    bin: 'php',
    languages: 'php',
    aptPackages: ['php-cli'],
  ),
  ToolchainRecipe(
    bin: 'swift',
    languages: 'swift',
    manualHint: 'ikuti https://www.swift.org/install (tarball ofisial)',
  ),
  ToolchainRecipe(
    bin: 'kotlinc',
    languages: 'kotlin',
    manualHint: 'ikuti https://sdkman.io (sdk install kotlin)',
  ),
  ToolchainRecipe(
    bin: 'runghc',
    languages: 'haskell',
    aptPackages: ['ghc'],
  ),
  ToolchainRecipe(
    bin: 'julia',
    languages: 'julia',
    manualHint: 'ikuti https://julialang.org/downloads (juliaup)',
  ),
  ToolchainRecipe(
    bin: 'elixir',
    languages: 'elixir',
    aptPackages: ['elixir'],
  ),
  ToolchainRecipe(
    bin: 'clojure',
    languages: 'clojure',
    aptPackages: ['clojure'],
  ),
  ToolchainRecipe(
    bin: 'groovy',
    languages: 'groovy',
    manualHint: 'ikuti https://sdkman.io (sdk install groovy)',
  ),
  ToolchainRecipe(
    bin: 'scala',
    languages: 'scala',
    manualHint: 'ikuti https://www.scala-lang.org/download (coursier/sdkman)',
  ),
  ToolchainRecipe(
    bin: 'perl',
    languages: 'perl',
    aptPackages: ['perl'],
  ),
  ToolchainRecipe(
    bin: 'fpc',
    languages: 'pascal/delphi (free pascal)',
    aptPackages: ['fpc'],
  ),
  ToolchainRecipe(
    bin: 'gfortran',
    languages: 'fortran',
    aptPackages: ['gfortran'],
  ),
  ToolchainRecipe(
    bin: 'cobc',
    languages: 'cobol',
    aptPackages: ['gnucobol'],
  ),
  ToolchainRecipe(
    bin: 'gnatmake',
    languages: 'ada',
    aptPackages: ['gnat'],
  ),
  ToolchainRecipe(
    bin: 'ocaml',
    languages: 'ocaml',
    aptPackages: ['ocaml'],
  ),
  ToolchainRecipe(
    bin: 'crystal',
    languages: 'crystal',
    manualHint: 'ikuti https://crystal-lang.org/install (repo ofisial)',
  ),
  ToolchainRecipe(
    bin: 'nim',
    languages: 'nim',
    aptPackages: ['nim'],
  ),
  ToolchainRecipe(
    bin: 'zig',
    languages: 'zig',
    manualHint: 'ikuti https://ziglang.org/download (tarball ofisial)',
  ),
  ToolchainRecipe(
    bin: 'dmd',
    languages: 'd',
    manualHint: 'ikuti https://dlang.org/download (install.dlang.org)',
  ),
  ToolchainRecipe(
    bin: 'gst',
    languages: 'smalltalk',
    aptPackages: ['gnu-smalltalk'],
  ),
  ToolchainRecipe(
    bin: 'iverilog',
    languages: 'verilog',
    aptPackages: ['iverilog'],
  ),
  ToolchainRecipe(
    bin: 'gm2',
    languages: 'modula-2',
    aptPackages: ['gm2'],
  ),
  ToolchainRecipe(
    bin: 'racket',
    languages: 'racket',
    aptPackages: ['racket'],
  ),
  ToolchainRecipe(
    bin: 'gforth',
    languages: 'forth',
    aptPackages: ['gforth'],
  ),
  ToolchainRecipe(
    bin: 'io',
    languages: 'io',
    manualHint: 'ikuti https://github.com/stevedekorte/io (build dari source)',
  ),
  ToolchainRecipe(
    bin: 'factor',
    languages: 'factor',
    manualHint: 'ikuti https://factorcode.org (binary release)',
  ),
  ToolchainRecipe(
    bin: 'ijconsole',
    languages: 'j',
    manualHint: 'ikuti https://code.jsoftware.com/wiki/Install',
  ),
  ToolchainRecipe(
    bin: 'gs',
    languages: 'postscript',
    aptPackages: ['ghostscript'],
  ),
  ToolchainRecipe(
    bin: 'tclsh',
    languages: 'tcl',
    aptPackages: ['tcl'],
  ),
  ToolchainRecipe(
    bin: 'fbc',
    languages: 'freebasic',
    aptPackages: ['freebasic'],
  ),
  ToolchainRecipe(
    bin: 'gbs3',
    languages: 'gambas',
    aptPackages: ['gambas3-script'],
  ),
  ToolchainRecipe(
    bin: 'sml',
    languages: 'sml',
    aptPackages: ['smlnj'],
  ),
  ToolchainRecipe(
    bin: 'swipl',
    languages: 'prolog',
    aptPackages: ['swi-prolog'],
  ),
  ToolchainRecipe(
    bin: 'guile',
    languages: 'scheme',
    aptPackages: ['guile-3.0'],
  ),
  ToolchainRecipe(
    bin: 'sbcl',
    languages: 'commonlisp',
    aptPackages: ['sbcl'],
  ),
  ToolchainRecipe(
    bin: 'escript',
    languages: 'erlang',
    aptPackages: ['erlang'],
  ),
  ToolchainRecipe(
    bin: 'dotnet',
    languages: 'csharp/fsharp',
    manualHint:
        'ikuti https://dotnet.microsoft.com/download (dotnet-install.sh) '
        'atau pasang paket distro dotnet-sdk-<versi>',
  ),
  ToolchainRecipe(
    bin: 'sh',
    languages: 'shell (sh, umumnya sudah preinstalled)',
    aptPackages: ['bash'],
  ),
  ToolchainRecipe(
    bin: 'awk',
    languages: 'awk',
    aptPackages: ['gawk'],
  ),
];

/// Hasil scan [kToolchainRecipes] terhadap PATH host: resep apt yang siap
/// dipasang massal, dan resep manual yang butuh langkah user.
class ToolchainPlan {
  const ToolchainPlan({
    this.aptInstallable = const [],
    this.manual = const [],
  });

  final List<ToolchainRecipe> aptInstallable;
  final List<ToolchainRecipe> manual;

  bool get empty => aptInstallable.isEmpty && manual.isEmpty;

  /// Command instalasi massal (satu proses); `asRoot=false` menambah prefix
  /// sudo untuk sesi non-root.
  List<String> aptCommand({bool asRoot = true}) {
    final pkgs = <String>{
      for (final r in aptInstallable) ...r.aptPackages,
    }.toList();
    return [if (!asRoot) 'sudo', 'apt-get', 'install', '-y', ...pkgs];
  }

  String describe() {
    final aptLine = aptInstallable
        .map((r) => '${r.bin} (${r.languages}: ${r.aptPackages.join(" ")})')
        .join(', ');
    final manualLine = manual
        .map((r) => '${r.bin} (${r.languages}: ${r.manualHint})')
        .join(', ');
    return 'apt-installable: ${aptInstallable.isEmpty ? '-' : aptLine}\n'
        'manual: ${manual.isEmpty ? '-' : manualLine}';
  }
}

/// Scan biner resep terhadap [environment] (fallback PATH proses). Terpisah
/// dari [LanguageRegistry.onPath] agar unit test bisa menyuntik PATH mock.
ToolchainPlan buildToolchainPlan({Map<String, String>? environment}) {
  final missing = <ToolchainRecipe>[
    for (final r in kToolchainRecipes)
      if (!_recipeOnPath(r.bin, environment)) r,
  ];
  return ToolchainPlan(
    aptInstallable: [for (final r in missing) if (r.installableViaApt) r],
    manual: [for (final r in missing) if (!r.installableViaApt) r],
  );
}

bool _recipeOnPath(String bin, Map<String, String>? environment) {
  final path =
      environment?['PATH'] ?? Platform.environment['PATH'] ?? '';
  final suffix = Platform.isWindows ? bin.endsWith('.exe') ? '' : '.exe' : '';
  final listSep = Platform.isWindows ? ';' : ':';
  for (final dir in path.split(listSep)) {
    if (dir.trim().isEmpty) continue;
    final candidate = Platform.isWindows
        ? '$dir\\$bin$suffix'
        : p.join(dir, bin);
    try {
      final type = FileSystemEntity.typeSync(candidate);
      if (type != FileSystemEntityType.notFound) return true;
    } on FileSystemException {
      continue;
    }
  }
  return false;
}

/// Wadah hasil eksekusi proses probe (Process.run-style) untuk injeksi mock
/// pada unit test [applyToolchainPlan].
class ToolchainProcOut {
  const ToolchainProcOut(this.exitCode, this.output);

  /// Kode exit proses (0 = sukses).
  final int exitCode;

  /// Gabungan stdout+stderr proses.
  final String output;
}

/// Runner analog `Process.run` — output ditangkap (untuk probe apt).
typedef ToolchainProcRunner = Future<ToolchainProcOut> Function(
    String exe, List<String> args);

/// Runner analog `Process.start(inheritStdio)` — hanya kode exit (instalasi).
typedef ToolchainSpawnRunner = Future<int> Function(List<String> argv);

/// Runner probe bawaan: `Process.run` dengan output stdout+stderr digabung.
Future<ToolchainProcOut> defaultToolchainProcRunner(
    String exe, List<String> args) async {
  final res = await Process.run(exe, args);
  return ToolchainProcOut(res.exitCode, '${res.stdout}${res.stderr}');
}

/// Runner instalasi bawaan: `Process.start` dengan stdio diwariskan agar
/// user melihat progress apt-get langsung.
Future<int> defaultToolchainSpawnRunner(List<String> argv) async {
  final proc = await Process.start(
    argv.first,
    argv.sublist(1),
    mode: ProcessStartMode.inheritStdio,
  );
  return proc.exitCode;
}

/// Ambil daftar paket yang dinyatakan apt tidak tersedia dari output gabungan
/// probe (`apt-get install --dry-run`). Mendukung tiga pola error apt:
/// `Unable to locate package X`, `Package X is not available`, dan
/// `Package 'X' has no installation candidate` (kutip tunggal dilepas).
List<String> parseUnavailableAptPackages(String output) {
  final missing = <String>{};
  final patterns = [
    RegExp(r'Unable to locate package (\S+)'),
    RegExp(r'Package (\S+) is not available'),
    RegExp(r"Package '?([^'\s]+)'? has no installation candidate"),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(output)) {
      final name = match.group(1);
      if (name == null || name.isEmpty) continue;
      missing.add(name.replaceAll("'", ''));
    }
  }
  return missing.toList();
}

/// Hasil [applyToolchainPlan].
class ToolchainApplyResult {
  const ToolchainApplyResult({
    required this.success,
    required this.message,
    this.ran = false,
  });

  final bool success;
  final String message;

  /// True bila proses instalasi benar-benar dijalankan (bukan dry-run).
  final bool ran;
}

/// Jalankan rencana provisioning. Human-in-loop: [confirm] dipanggil dengan
/// ringkasan rencana; tanpa jawaban eksplisit tidak ada paket yang dipasang.
/// Stdio diwariskan agar user melihat progress apt-get langsung.
///
/// Sebelum instalasi batch, ketersediaan paket diprobe via
/// `apt-get install --dry-run` ([procRunner]); paket yang tidak ada di repo
/// distro (mis. gnu-smalltalk pada beberapa Debian) dilewati sehingga satu
/// paket rusak tidak membatalkan seluruh batch. Bila batch tetap gagal,
/// fallback per-paket dijalankan via [spawnRunner] dan kegagalannya
/// dilaporkan jujur di [ToolchainApplyResult.message].
Future<ToolchainApplyResult> applyToolchainPlan(
  ToolchainPlan plan, {
  required Future<bool> Function(String planMessage) confirm,
  Map<String, String>? environment,
  bool dryRun = false,
  ToolchainProcRunner? procRunner,
  ToolchainSpawnRunner? spawnRunner,
}) async {
  if (plan.empty) {
    return const ToolchainApplyResult(
      success: true,
      message: 'semua toolchain registry sudah tersedia',
    );
  }
  if (plan.aptInstallable.isNotEmpty) {
    if (!Platform.isLinux) {
      return ToolchainApplyResult(
        success: false,
        message:
            'instalasi apt hanya didukung di Linux; ikuti hint manual untuk '
            '${plan.manual.map((r) => r.bin).join(", ")}',
      );
    }
  }
  final summary = plan.describe();
  if (!await confirm(summary)) {
    return const ToolchainApplyResult(
      success: false,
      message: 'prosesing dibatalkan — tidak ada paket yang dipasang',
    );
  }
  if (dryRun) {
    return ToolchainApplyResult(
      success: true,
      ran: false,
      message: plan.aptInstallable.isEmpty
          ? 'dry-run: hanya toolchain manual (tidak ada yang dijalankan)'
          : plan
                .aptCommand(
                  asRoot:
                      !Platform.environment.containsKey('SUDO_USER') &&
                      Platform.environment['USER'] != 'root',
                )
                .join(' '),
    );
  }
  if (plan.aptInstallable.isNotEmpty) {
    final runner = procRunner ?? defaultToolchainProcRunner;
    final spawn = spawnRunner ?? defaultToolchainSpawnRunner;
    final asRoot =
        Platform.environment['SUDO_USER'] == null &&
        Platform.environment['USER'] == 'root';
    final pkgs = plan.aptCommand(asRoot: asRoot).sublist(asRoot ? 3 : 4);
    var available = pkgs;
    var skipped = <String>[];
    try {
      final probeArgv = [
        if (!asRoot) 'sudo',
        'apt-get',
        'install',
        '--dry-run',
        '-y',
        ...pkgs,
      ];
      final probe = await runner(probeArgv.first, probeArgv.sublist(1));
      final missing = parseUnavailableAptPackages(probe.output);
      if (missing.isNotEmpty) {
        skipped = [
          for (final pkg in pkgs)
            if (missing.contains(pkg)) pkg,
        ];
        available = [
          for (final pkg in pkgs)
            if (!missing.contains(pkg)) pkg,
        ];
      }
    } on ProcessException {
      available = pkgs;
      skipped = const [];
    }
    if (available.isEmpty) {
      return ToolchainApplyResult(
        success: false,
        ran: true,
        message:
            'semua ${skipped.length} paket apt tidak tersedia di repo '
            'distro ini: ${skipped.join(", ")} — cek nama paket '
            'Debian/Ubuntu terbaru atau pasang manual',
      );
    }
    final baseArgv = [if (!asRoot) 'sudo', 'apt-get', 'install', '-y'];
    int code;
    try {
      code = await spawn([...baseArgv, ...available]);
    } on ProcessException catch (error) {
      return ToolchainApplyResult(
        success: false,
        ran: true,
        message:
            'gagal menjalankan ${baseArgv.first}: '
            '${error.message} (sudo tersedia? apt terpasang?)',
      );
    }
    var installed = List<String>.of(available);
    var failed = <String>[];
    if (code != 0) {
      installed = <String>[];
      for (final pkg in available) {
        try {
          if (await spawn([...baseArgv, pkg]) == 0) {
            installed.add(pkg);
          } else {
            failed.add(pkg);
          }
        } on ProcessException catch (error) {
          return ToolchainApplyResult(
            success: false,
            ran: true,
            message:
                'gagal menjalankan ${baseArgv.first}: '
                '${error.message} (sudo tersedia? apt terpasang?)',
          );
        }
      }
    }
    final skippedNote = skipped.isEmpty
        ? ''
        : '\nDilewati (tidak tersedia di repo distro ini — coba repo '
              'distro lain / pasang manual): ${skipped.join(", ")}';
    if (failed.isNotEmpty && installed.isEmpty) {
      return ToolchainApplyResult(
        success: false,
        ran: true,
        message:
            'gagal memasang paket terpilih: ${failed.join(", ")}$skippedNote',
      );
    }
    if (failed.isNotEmpty) {
      return ToolchainApplyResult(
        success: false,
        ran: true,
        message:
            'sebagian berhasil: ${installed.join(", ")}; gagal: '
            '${failed.join(", ")} — jalankan `tiko doctor` ulang'
            '$skippedNote',
      );
    }
    final stillAptManual = plan.manual
        .map((r) => '${r.bin}: ${r.manualHint}')
        .join('\n  ');
    return ToolchainApplyResult(
      success: true,
      ran: true,
      message: plan.manual.isEmpty
          ? 'selesai — jalankan `tiko doctor` untuk verifikasi'
                '$skippedNote'
          : 'selesai (apt) — berikut yang perlu dipasang manual sekali '
                'saja:\n  $stillAptManual$skippedNote',
    );
  }
  final stillManual = plan.manual
      .map((r) => '${r.bin}: ${r.manualHint}')
      .join('\n  ');
  return ToolchainApplyResult(
    success: true,
    ran: true,
    message: plan.manual.isEmpty
        ? 'selesai — jalankan `tiko doctor` untuk verifikasi'
        : 'selesai (apt) — berikut yang perlu dipasang manual sekali saja:\n'
              '  $stillManual',
  );
}
