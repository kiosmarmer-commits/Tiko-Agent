// Fase F8.3b (docs/15 §9) — registry 100 bahasa pemrograman data-driven
// untuk CodeExecutionTool. Tiga tingkat kejujuran:
//  1. run/compile — dijalankan host (fail-soft bila toolchain absen) atau
//     via docker image (bila provider docker aktif dan image tersedia).
//  2. builtin — dieksekusi native Dart (mis. interpreter Brainfuck).
//  3. unsupported — runtime proprietary / GUI / mainframe (ABAP, Scratch,
//     Apex, dsb.): gagal eksplisit dengan alasan, bukan error kabur.
// Registry ini data, bukan enum: menambah bahasa = menambah entri,
// tanpa menyentuh logika provider.

import 'dart:io';

/// Spesifikasi eksekusi satu bahasa (F8.3b).
class LanguageSpec {
  const LanguageSpec({
    required this.name,
    required this.ext,
    this.interpreter,
    this.runCmd,
    this.compileCmd,
    this.dockerImage,
    this.unsupportedReason,
  });

  /// id kanonik lowercase (mis. `typescript`, `cpp`).
  final String name;

  /// Ekstensi file kanonik (tanpa titik) untuk file sementara.
  final String ext;

  /// Interpreter/compiler utama untuk probe ketersediaan host. Null hanya
  /// untuk mode builtin/unsupported.
  final String? interpreter;

  /// Perintah `sh -c` satu baris dengan placeholder `{file}` (mode run).
  final String? runCmd;

  /// Chain compile + run (`sh -c`, placeholder `{file}`); binary/output
  /// sementara harus bernama `tiko_prog` di cwd (temp dir) agar tidak
  /// menjatuhkan artefak ke workspace.
  final String? compileCmd;

  /// Image docker; null berarti tidak ada image baku (hostOnly).
  final String? dockerImage;

  /// Tidak null: bahasa sengaja tidak didukung, dengan alasan eksplisit.
  final String? unsupportedReason;

  bool get supported => unsupportedReason == null;
  bool get isBuiltin => interpreter == null && runCmd == null && compileCmd == null && supported;
}

/// Registry 100 bahasa (F8.3b). Sembilan bahasa inti (python, javascript,
/// bash, dart, java, go, c, cpp, rust) tetap di enum ExecutionLanguage di
/// code_execution.dart; entri di sini melengkapi sisanya.
class LanguageRegistry {
  LanguageRegistry._();

  /// Alias umum -> id kanonik registry.
  static const Map<String, String> aliases = {
    'c++': 'cpp',
    'c#': 'csharp',
    'c-sharp': 'csharp',
    'c sharp': 'csharp',
    'golang': 'go',
    'ts': 'typescript',
    'sh': 'shell',
    'shell': 'shell',
    'js': 'javascript',
    'node': 'javascript',
    'py': 'python',
    'vb': 'vbnet',
    'vb.net': 'vbnet',
    'visual basic .net': 'vbnet',
    'visual-basic.net': 'vbnet',
    'f#': 'fsharp',
    'f-sharp': 'fsharp',
    'objective-c': 'objectivec',
    'objc': 'objectivec',
    'commonlisp': 'commonlisp',
    'common-lisp': 'commonlisp',
    'common lisp': 'commonlisp',
    'lisp': 'commonlisp',
    'standardml': 'sml',
    'standard-ml': 'sml',
    'standard ml': 'sml',
    'modula2': 'modula2',
    'modula-2': 'modula2',
    'modula 2': 'modula2',
    'pl/sql': 'plsql',
    't-sql': 'tsql',
    'brainf***': 'brainfuck',
    'bf': 'brainfuck',
    'pascal': 'delphi',
    'object pascal': 'delphi',
    'visual foxpro': 'visualfoxpro',
    'foxpro': 'visualfoxpro',
  };

  static const List<LanguageSpec> specs = [
    LanguageSpec(
      name: 'csharp',
      ext: 'cs',
      interpreter: 'dotnet',
      runCmd: 'dotnet run "{file}"',
      dockerImage: 'mcr.microsoft.com/dotnet/sdk:10.0',
    ),
    LanguageSpec(
      name: 'typescript',
      ext: 'ts',
      interpreter: 'node',
      runCmd: 'node --experimental-strip-types "{file}"',
      dockerImage: 'node:23-alpine',
    ),
    LanguageSpec(
      name: 'sql',
      ext: 'sql',
      interpreter: 'sqlite3',
      runCmd: 'sqlite3 :memory: ".read {file}"',
      dockerImage: 'keinos/sqlite3:latest',
    ),
    LanguageSpec(
      name: 'shell',
      ext: 'sh',
      interpreter: 'sh',
      runCmd: 'sh "{file}"',
      dockerImage: 'alpine:latest',
    ),
    LanguageSpec(
      name: 'powershell',
      ext: 'ps1',
      interpreter: 'pwsh',
      runCmd: 'pwsh -NoProfile -File "{file}"',
      dockerImage: 'mcr.microsoft.com/powershell:7.4',
    ),
    LanguageSpec(
      name: 'r',
      ext: 'r',
      interpreter: 'Rscript',
      runCmd: 'Rscript "{file}"',
      dockerImage: 'r-base:4.4.2',
    ),
    LanguageSpec(
      name: 'ruby',
      ext: 'rb',
      interpreter: 'ruby',
      runCmd: 'ruby "{file}"',
      dockerImage: 'ruby:3.3-slim',
    ),
    LanguageSpec(
      name: 'lua',
      ext: 'lua',
      interpreter: 'lua',
      runCmd: 'lua "{file}"',
      dockerImage: 'nickblah/lua:5.4',
    ),
    LanguageSpec(
      name: 'php',
      ext: 'php',
      interpreter: 'php',
      runCmd: 'php "{file}"',
      dockerImage: 'php:8.3-cli',
    ),
    LanguageSpec(
      name: 'swift',
      ext: 'swift',
      interpreter: 'swift',
      runCmd: 'swift "{file}"',
      dockerImage: 'swift:6.0-noble',
    ),
    LanguageSpec(
      name: 'kotlin',
      ext: 'kts',
      interpreter: 'kotlinc',
      runCmd: 'kotlinc -script "{file}"',
      dockerImage: 'zenika/alpine-kotlin:4.53',
    ),
    LanguageSpec(
      name: 'haskell',
      ext: 'hs',
      interpreter: 'runghc',
      runCmd: 'runghc "{file}"',
      dockerImage: 'haskell:9.6-slim',
    ),
    LanguageSpec(
      name: 'julia',
      ext: 'jl',
      interpreter: 'julia',
      runCmd: 'julia "{file}"',
      dockerImage: 'julia:1.10',
    ),
    LanguageSpec(
      name: 'elixir',
      ext: 'exs',
      interpreter: 'elixir',
      runCmd: 'elixir "{file}"',
      dockerImage: 'elixir:1.17-slim',
    ),
    LanguageSpec(
      name: 'clojure',
      ext: 'clj',
      interpreter: 'clojure',
      runCmd: 'clojure -M "{file}"',
      dockerImage: 'clojure:temurin-21-tools-deps',
    ),
    LanguageSpec(
      name: 'groovy',
      ext: 'groovy',
      interpreter: 'groovy',
      runCmd: 'groovy "{file}"',
      dockerImage: 'groovy:4.0-jdk21',
    ),
    LanguageSpec(
      name: 'fsharp',
      ext: 'fsx',
      interpreter: 'dotnet',
      runCmd: 'dotnet fsi "{file}"',
      dockerImage: 'mcr.microsoft.com/dotnet/sdk:10.0',
    ),
    LanguageSpec(
      name: 'perl',
      ext: 'pl',
      interpreter: 'perl',
      runCmd: 'perl "{file}"',
      dockerImage: 'perl:5.40-slim',
    ),
    LanguageSpec(
      name: 'assembly',
      ext: 's',
      interpreter: 'gcc',
      compileCmd: 'gcc "{file}" -o tiko_prog && ./tiko_prog',
      dockerImage: 'gcc:14-bookworm',
    ),
    LanguageSpec(
      name: 'fortran',
      ext: 'f90',
      interpreter: 'gfortran',
      compileCmd: 'gfortran -O1 "{file}" -o tiko_prog && ./tiko_prog',
      dockerImage: 'gcc:14-bookworm',
    ),
    LanguageSpec(
      name: 'cobol',
      ext: 'cob',
      interpreter: 'cobc',
      compileCmd: 'cobc -x -j "{file}" -o tiko_prog && ./tiko_prog',
    ),
    LanguageSpec(
      name: 'ada',
      ext: 'adb',
      interpreter: 'gnatmake',
      compileCmd: 'gnatmake -o tiko_prog "{file}" && ./tiko_prog',
    ),
    LanguageSpec(
      name: 'objectivec',
      ext: 'm',
      interpreter: 'gcc',
      compileCmd: 'gcc -O1 -x objective-c "{file}" -o tiko_prog -lobjc && ./tiko_prog',
      dockerImage: 'gcc:14-bookworm',
    ),
    LanguageSpec(
      name: 'commonlisp',
      ext: 'lisp',
      interpreter: 'sbcl',
      runCmd: 'sbcl --script "{file}"',
      dockerImage: 'clfoundation/sbcl:2.4',
    ),
    LanguageSpec(
      name: 'scheme',
      ext: 'scm',
      interpreter: 'guile',
      runCmd: 'guile --no-auto-compile "{file}"',
    ),
    LanguageSpec(
      name: 'prolog',
      ext: 'pro',
      interpreter: 'swipl',
      runCmd: 'swipl -q -f "{file}" -t halt',
      dockerImage: 'swipl:9.2.5',
    ),
    LanguageSpec(
      name: 'erlang',
      ext: 'erl',
      interpreter: 'escript',
      runCmd: 'escript "{file}"',
      dockerImage: 'erlang:27-slim',
    ),
    LanguageSpec(
      name: 'ocaml',
      ext: 'ml',
      interpreter: 'ocaml',
      runCmd: 'ocaml "{file}"',
    ),
    LanguageSpec(
      name: 'crystal',
      ext: 'cr',
      interpreter: 'crystal',
      runCmd: 'crystal run "{file}"',
      dockerImage: 'crystallang/crystal:1.14',
    ),
    LanguageSpec(
      name: 'nim',
      ext: 'nim',
      interpreter: 'nim',
      runCmd: 'nim c -r --hints:off --warnings:off --colors:off "{file}"',
      dockerImage: 'nimlang/nim:2.0',
    ),
    LanguageSpec(
      name: 'zig',
      ext: 'zig',
      interpreter: 'zig',
      runCmd: 'zig run "{file}"',
      dockerImage: 'ziglang/zig:0.13',
    ),
    LanguageSpec(
      name: 'd',
      ext: 'd',
      interpreter: 'dmd',
      runCmd: 'dmd -run "{file}"',
      dockerImage: 'dlang2/dmd-ubuntu:latest',
    ),
    LanguageSpec(
      name: 'smalltalk',
      ext: 'st',
      interpreter: 'gst',
      runCmd: 'gst "{file}"',
    ),
    LanguageSpec(
      name: 'verilog',
      ext: 'v',
      interpreter: 'iverilog',
      compileCmd: 'iverilog -g2012 -o tiko_prog "{file}" && vvp tiko_prog',
    ),
    LanguageSpec(
      name: 'modula2',
      ext: 'mod',
      interpreter: 'gm2',
      compileCmd: 'gm2 -O1 "{file}" -o tiko_prog && ./tiko_prog',
      dockerImage: 'gcc:14-bookworm',
    ),
    LanguageSpec(
      name: 'racket',
      ext: 'rkt',
      interpreter: 'racket',
      runCmd: 'racket "{file}"',
    ),
    LanguageSpec(
      name: 'forth',
      ext: 'fs',
      interpreter: 'gforth',
      runCmd: 'gforth "{file}" -e bye',
    ),
    LanguageSpec(
      name: 'io',
      ext: 'io',
      interpreter: 'io',
      runCmd: 'io "{file}"',
    ),
    LanguageSpec(
      name: 'factor',
      ext: 'factor',
      interpreter: 'factor',
      runCmd: 'factor "{file}"',
    ),
    LanguageSpec(
      name: 'j',
      ext: 'ijs',
      interpreter: 'ijconsole',
      runCmd: 'ijconsole "{file}"',
    ),
    LanguageSpec(
      name: 'postscript',
      ext: 'eps',
      interpreter: 'gs',
      runCmd: 'gs -q -dBATCH -dNODISPLAY "{file}"',
    ),
    LanguageSpec(
      name: 'awk',
      ext: 'awk',
      interpreter: 'awk',
      runCmd: 'awk -f "{file}" /dev/null',
    ),
    LanguageSpec(
      name: 'tcl',
      ext: 'tcl',
      interpreter: 'tclsh',
      runCmd: 'tclsh "{file}"',
    ),
    LanguageSpec(
      name: 'freebasic',
      ext: 'bas',
      interpreter: 'fbc',
      compileCmd: 'fbc "{file}" -x tiko_prog && ./tiko_prog',
    ),
    LanguageSpec(
      name: 'gambas',
      ext: 'gb',
      interpreter: 'gbs3',
      runCmd: 'gbs3 "{file}"',
    ),
    LanguageSpec(name: 'brainfuck', ext: 'bf'),
    LanguageSpec(
      name: 'scala',
      ext: 'scala',
      interpreter: 'scala',
      runCmd: 'scala "{file}"',
    ),
    LanguageSpec(
      name: 'sml',
      ext: 'sml',
      interpreter: 'sml',
      runCmd: 'sml < "{file}"',
    ),
    LanguageSpec(
      name: 'pascal',
      ext: 'pas',
      interpreter: 'fpc',
      compileCmd: 'fpc -XS "{file}" -otiko_prog && ./tiko_prog',
    ),
    // ---- Sengaja TIDAK didukung (alasan eksplisit, fail-closed) ----
    LanguageSpec(
      name: 'matlab',
      ext: 'mltb',
      unsupportedReason:
          'runtime proprietary (MATLAB); alternatif open source: Octave via tool shell',
    ),
    LanguageSpec(
      name: 'delphi',
      ext: 'dpr',
      unsupportedReason:
          'runtime proprietary (Delphi IDE); Object Pascal bisa via language "pascal"',
    ),
    LanguageSpec(
      name: 'vbnet',
      ext: 'vb',
      unsupportedReason:
          'toolchain VB.NET single-file jarang tersedia; bungkus dalam proyek .NET via tool shell',
    ),
    LanguageSpec(
      name: 'vhdl',
      ext: 'vhd',
      unsupportedReason:
          'HDL butuh testbench + simulator (ghdl); jalankan via tool shell bila terpasang',
    ),
    LanguageSpec(
      name: 'abap',
      ext: 'abap',
      unsupportedReason: 'hanya berjalan pada SAP NetWeaver (mainframe SAP)',
    ),
    LanguageSpec(
      name: 'sas',
      ext: 'sas',
      unsupportedReason: 'runtime proprietary (SAS Institute)',
    ),
    LanguageSpec(
      name: 'plsql',
      ext: 'pls',
      unsupportedReason:
          'butuh Oracle Database; gunakan tool koneksi DB, bukan eksekusi file',
    ),
    LanguageSpec(
      name: 'tsql',
      ext: 'tsql',
      unsupportedReason:
          'butuh SQL Server; gunakan tool koneksi DB, bukan eksekusi file',
    ),
    LanguageSpec(
      name: 'apex',
      ext: 'cls',
      unsupportedReason: 'hanya berjalan pada platform Salesforce',
    ),
    LanguageSpec(
      name: 'solidity',
      ext: 'sol',
      unsupportedReason: 'butuh EVM/deploy kontrak; gunakan tool ethereum',
    ),
    LanguageSpec(
      name: 'vyper',
      ext: 'vy',
      unsupportedReason: 'butuh EVM/deploy kontrak; gunakan tool ethereum',
    ),
    LanguageSpec(
      name: 'eiffel',
      ext: 'e',
      unsupportedReason: 'toolchain jarang (EiffelStudio)',
    ),
    LanguageSpec(
      name: 'oberon',
      ext: 'obn',
      unsupportedReason: 'compiler historis jarang tersedia',
    ),
    LanguageSpec(
      name: 'logo',
      ext: 'logo',
      unsupportedReason: 'interpreter jarang (ucblogo)',
    ),
    LanguageSpec(
      name: 'scratch',
      ext: 'sb3',
      unsupportedReason: 'bahasa visual — butuh editor GUI, tidak headless',
    ),
    LanguageSpec(
      name: 'alice',
      ext: 'a3p',
      unsupportedReason: 'bahasa visual 3D — butuh IDE GUI',
    ),
    LanguageSpec(
      name: 'squeak',
      ext: 'image',
      unsupportedReason: 'butuh image Smalltalk GUI (Squeak VM)',
    ),
    LanguageSpec(
      name: 'self',
      ext: 'self',
      unsupportedReason: 'butuh VM Self (jarang dipasang)',
    ),
    LanguageSpec(
      name: 'k',
      ext: 'k',
      unsupportedReason: 'runtime proprietary (KDB+/Shakti)',
    ),
    LanguageSpec(
      name: 'apl',
      ext: 'apl',
      unsupportedReason: 'butuh interpreter Dyalog (dapat dipasang manual)',
    ),
    LanguageSpec(
      name: 'actionscript',
      ext: 'as',
      unsupportedReason: 'runtime Flash sudah EOL',
    ),
    LanguageSpec(
      name: 'coldfusion',
      ext: 'cfm',
      unsupportedReason: 'butuh server CFML (Adobe ColdFusion/Lucee)',
    ),
    LanguageSpec(
      name: 'xquery',
      ext: 'xq',
      unsupportedReason: 'butuh engine (BaseX/Saxon) + input XML',
    ),
    LanguageSpec(
      name: 'xslt',
      ext: 'xsl',
      unsupportedReason: 'butuh input XML; gunakan xsltproc via tool shell',
    ),
    LanguageSpec(
      name: 'spss',
      ext: 'sps',
      unsupportedReason: 'runtime proprietary (IBM SPSS)',
    ),
    LanguageSpec(
      name: 'stata',
      ext: 'do',
      unsupportedReason: 'runtime proprietary (StataCorp)',
    ),
    LanguageSpec(
      name: 'gams',
      ext: 'gms',
      unsupportedReason: 'runtime proprietary (GAMS)',
    ),
    LanguageSpec(
      name: 'sed',
      ext: 'sed',
      unsupportedReason: 'butuh file input eksternal; gunakan tool shell',
    ),
    LanguageSpec(
      name: 'livecode',
      ext: 'lc',
      unsupportedReason: 'runtime proprietary (LiveCode Ltd)',
    ),
    LanguageSpec(
      name: 'purebasic',
      ext: 'pb',
      unsupportedReason: 'runtime proprietary (Fantaisie Software)',
    ),
    LanguageSpec(
      name: 'harbour',
      ext: 'prg',
      unsupportedReason: 'toolchain jarang tersedia; pasang Harbour manual',
    ),
    LanguageSpec(
      name: 'visualfoxpro',
      ext: 'vfp',
      unsupportedReason: 'runtime proprietary (Microsoft, sudah EOL)',
    ),
    LanguageSpec(
      name: 'rpg',
      ext: 'rpg',
      unsupportedReason: 'hanya berjalan pada IBM i (AS/400)',
    ),
    LanguageSpec(
      name: 'natural',
      ext: 'nsp',
      unsupportedReason: 'hanya berjalan pada ADABAS (Software AG)',
    ),
    LanguageSpec(
      name: 'pli',
      ext: 'pli',
      unsupportedReason: 'butuh compiler mainframe (IBM Enterprise PL/I)',
    ),
    LanguageSpec(
      name: 'simula',
      ext: 'sim',
      unsupportedReason: 'compiler jarang (cim)',
    ),
    LanguageSpec(
      name: 'algol',
      ext: 'alg',
      unsupportedReason: 'compiler historis jarang tersedia',
    ),
    LanguageSpec(
      name: 'snobol',
      ext: 'sno',
      unsupportedReason: 'interpreter jarang (csnobol4)',
    ),
    LanguageSpec(
      name: 'icon',
      ext: 'icn',
      unsupportedReason: 'interpreter jarang (icont/iconx)',
    ),
    LanguageSpec(
      name: 'curry',
      ext: 'curry',
      unsupportedReason: 'toolchain jarang (pakcs)',
    ),
    LanguageSpec(
      name: 'mercury',
      ext: 'mrc',
      unsupportedReason: 'toolchain jarang (Mercury compiler)',
    ),
    LanguageSpec(
      name: 'oz',
      ext: 'oz',
      unsupportedReason: 'butuh Mozart Programming VM',
    ),
    LanguageSpec(
      name: 'joy',
      ext: 'joy',
      unsupportedReason: 'interpreter jarang tersedia',
    ),
    LanguageSpec(
      name: 'piet',
      ext: 'png',
      unsupportedReason:
          'bahasa visual (bitmap warna) — belum ada interpreter terintegrasi',
    ),
  ];

  static final Map<String, LanguageSpec> _byName = {
    for (final s in specs) s.name: s,
  };

  /// Semua nama kanonik registry (termasuk yang unsupported).
  static List<String> get names =>
      List.unmodifiable(specs.map((s) => s.name));

  /// Lookup nama/alias; null bila tidak dikenal.
  static LanguageSpec? lookup(String name) {
    final key = name.trim().toLowerCase();
    final canonical = aliases[key] ?? key;
    return _byName[canonical];
  }

  /// Biner tersedia di PATH (tanpa menjalankannya; portabel lintas OS).
  static bool onPath(String bin) {
    final dirs = Platform.environment['PATH']?.split(Platform.pathSeparator);
    if (dirs == null) return false;
    for (final dir in dirs) {
      if (dir.trim().isEmpty) continue;
      final suffix = Platform.isWindows ? bin.endsWith('.exe') ? '' : '.exe' : '';
      try {
        final file = File(
          Platform.isWindows ? '$dir\\$bin$suffix' : '$dir/$bin',
        );
        if (file.existsSync()) return true;
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  /// Interpreter registry spesifikasi tersedia di host (probe PATH).
  static bool interpreterAvailable(LanguageSpec spec) {
    final bin = spec.interpreter;
    return bin != null && onPath(bin);
  }
}

/// Interpreter Brainfuck built-in (F8.3b): 8 instruksi, loop bracket-match,
/// kap 1.000.000 langkah + output 100.000 char agar agen tidak menggantung.
class BrainfuckInterpreter {
  BrainfuckInterpreter._();

  /// Jalankan source BF; hasil stdout-nya berupa teks plain.
  static String run(String code, {int maxSteps = 1000000}) {
    final program = code.codeUnits
        .where((c) => '><+-.,[]'.contains(String.fromCharCode(c)))
        .toList();
    final jump = <int, int>{};
    final stack = <int>[];
    for (var i = 0; i < program.length; i++) {
      if (program[i] == 0x5B) {
        // '['
        stack.add(i);
      } else if (program[i] == 0x5D) {
        // ']'
        if (stack.isEmpty) {
          throw const FormatException('bracket tidak seimbang');
        }
        final open = stack.removeLast();
        jump[open] = i;
        jump[i] = open;
      }
    }
    if (stack.isNotEmpty) throw const FormatException('bracket tidak seimbang');

    final tape = <int>[0];
    var pointer = 0;
    var pc = 0;
    var steps = 0;
    final out = StringBuffer();

    while (pc < program.length) {
      if (++steps > maxSteps) {
        throw StateError('melebihi batas langkah Brainfuck ($steps)');
      }
      switch (program[pc]) {
        case 0x3E: // '>'
          pointer++;
          if (pointer >= tape.length) tape.add(0);
          break;
        case 0x3C: // '<'
          if (pointer == 0) throw StateError('pointer < 0 (tape kiri)');
          pointer--;
          break;
        case 0x2B: // '+'
          tape[pointer] = (tape[pointer] + 1) & 0xFF;
          break;
        case 0x2D: // '-'
          tape[pointer] = (tape[pointer] - 1) & 0xFF;
          break;
        case 0x2E: // '.'
          if (out.length < 100000) out.writeCharCode(tape[pointer]);
          break;
        case 0x2C: // ','
          tape[pointer] = 0; // stdin: EOF
          break;
        case 0x5B: // '['
          if (tape[pointer] == 0) pc = jump[pc]!;
          break;
        case 0x5D: // ']'
          if (tape[pointer] != 0) pc = jump[pc]!;
          break;
      }
      pc++;
    }
    return out.toString();
  }
}
