import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// S20-A — computer-use headless: kontrol desktop GUI (screenshot, klik,
/// ketik, tombol, scroll) untuk agent di host yang mengizinkan. Fail-closed
/// berlapis:
///  - **default off** — tool hanya terdaftar bila config
///    `agent.computer_use: true`; TANPA flag ini tool tidak ada sama sekali.
///  - risk `high` — melewati PermissionGate approval (guided/strict).
///  - engine dilist jujur: `xdotool`/`scrot`/`import`/`pyautogui` — bila
///    binary hilang, hasilnya penanda jujur + hint, bukan error kabur.
///  - semua spawn argv array (tanpa interpreter shell), timeout, output cap.
class ComputerProcessResult {
  const ComputerProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get message => stderr.trim().isNotEmpty ? stderr : stdout;
}

/// Abstraksi proses host — dapat diinjeksi untuk test tanpa desktop nyata.
abstract class ComputerProcessRunner {
  Future<ComputerProcessResult> run(
    List<String> argv, {
    Duration timeout = const Duration(seconds: 20),
  });

  bool binaryExists(String bin);
}

class LocalComputerProcessRunner implements ComputerProcessRunner {
  const LocalComputerProcessRunner();

  @override
  Future<ComputerProcessResult> run(
    List<String> argv, {
    Duration timeout = _computerUseDefaultTimeout,
  }) async {
    try {
      final result =
          await Process.run(argv.first, argv.sublist(1)).timeout(timeout);
      return ComputerProcessResult(
        exitCode: result.exitCode,
        stdout: (result.stdout as String?) ?? '',
        stderr: (result.stderr as String?) ?? '',
      );
    } on ProcessException catch (e) {
      return ComputerProcessResult(
        exitCode: 127,
        stdout: '',
        stderr: 'binary tidak tersedia (${e.executable})',
      );
    }
  }

  @override
  bool binaryExists(String bin) {
    final result = Process.runSync('/usr/bin/which', [bin]);
    return result.exitCode == 0 &&
        ((result.stdout as String?) ?? '').trim().isNotEmpty;
  }
}

const _computerUseDefaultTimeout = Duration(seconds: 20);

class ComputerUseTool implements Tool {
  const ComputerUseTool({
    this.runner = const LocalComputerProcessRunner(),
    this.timeout = _computerUseDefaultTimeout,
  });

  final ComputerProcessRunner runner;
  final Duration timeout;

  static final _keyChars = RegExp(r'^[A-Za-z0-9_+\-. ]+$');
  static const _engineHint =
      'tidak ada engine input tersedia (install xdotool atau '
      'python3-pyautogui). Lihat tiko doctor --fix';

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'computer_use',
        description:
            'Kontrol desktop GUI host (explicit opt-in, perlu approval): '
            'screenshot, klik, ketik, tombol, scroll. action: '
            '"screenshot"|"click"|"type"|"key"|"scroll". Screenshot tersimpan '
            'di data/screenshots/ workspace dan path-nya dikembalikan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'description': 'screenshot | click | type | key | scroll',
            },
            'x': {'type': 'integer', 'description': 'posisi x (click/scroll)'},
            'y': {'type': 'integer', 'description': 'posisi y (click/scroll)'},
            'button': {
              'type': 'string',
              'description': 'left | right | middle (default left)',
            },
            'double': {'type': 'boolean', 'description': 'double click'},
            'text': {
              'type': 'string',
              'description': 'teks untuk type (max 2000)',
            },
            'combo': {
              'type': 'string',
              'description': 'kombinasi tombol untuk key, mis. "ctrl+s"',
            },
            'clicks': {
              'type': 'integer',
              'description': 'jumlah langkah scroll, bisa negatif',
            },
          },
          'required': ['action'],
        },
        risk: 'high',
        timeoutSec: 60,
        maxOutputChars: 4000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = ((args['action'] as String?) ?? '').trim();
    switch (action) {
      case 'screenshot':
        return _screenshot(ctx);
      case 'click':
        return _click(args);
      case 'type':
        return _type(args);
      case 'key':
        return _key(args);
      case 'scroll':
        return _scroll(args);
      default:
        return ToolResult(
          callId: '',
          content:
              'error: action tidak dikenal "$action" (didukung: screenshot, '
              'click, type, key, scroll)',
          isError: true,
        );
    }
  }

  String _trim(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  Future<String?> _screenEngine() async {
    for (final bin in const ['scrot', 'import']) {
      if (runner.binaryExists(bin)) return bin;
    }
    if (await _pythonHas('pyautogui')) return 'pyautogui';
    return null;
  }

  bool _inputEngineXdoto() => runner.binaryExists('xdotool');

  Future<bool> _pythonHas(String module) async {
    final r = await runner.run([
      'python3',
      '-c',
      'import importlib.util,sys; '
          'sys.exit(0 if importlib.util.find_spec("$module") else 1)',
    ], timeout: timeout);
    return r.exitCode == 0;
  }

  Future<ToolResult> _screenshot(ToolContext ctx) async {
    final engine = await _screenEngine();
    if (engine == null) {
      return const ToolResult(
        callId: '',
        content:
            'tidak ada engine screenshot tersedia (cobalah scrot, imagemagick '
            '"import", atau python3-pyautogui). Lihat tiko doctor --fix',
        isError: true,
      );
    }
    final dir = Directory(p.join(ctx.workspacePath, 'data', 'screenshots'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(
      dir.path,
      'screenshot-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    final argv = switch (engine) {
      'scrot' => ['scrot', '-z', path],
      'import' => ['import', '-window', 'root', path],
      _ => [
          'python3',
          '-c',
          'import pyautogui; pyautogui.screenshot(r"$path")',
        ],
    };
    final r = await runner.run(argv, timeout: timeout);
    final ok = r.exitCode == 0 && File(path).existsSync();
    if (!ok) {
      return ToolResult(
        callId: '',
        content:
            'engine screenshot "$engine" gagal (exit ${r.exitCode}): '
            '${_trim(r.message, 400)}',
        isError: true,
      );
    }
    final size = File(path).lengthSync();
    return ToolResult(
      callId: '',
      content:
          'screenshot tersimpan: $path ($size byte)\n'
          'buka via read_file atau lampirkan sebagai attachment.',
    );
  }

  Future<ToolResult> _click(Map<String, dynamic> args) async {
    final x = (args['x'] as num?)?.toInt();
    final y = (args['y'] as num?)?.toInt();
    if (x == null || y == null || x < 0 || y < 0 || x > 65535 || y > 65535) {
      return const ToolResult(
        callId: '',
        content: 'error: x dan y wajib integer 0..65535',
        isError: true,
      );
    }
    final buttonName = ((args['button'] as String?) ?? 'left').trim();
    final button = switch (buttonName) {
      'left' => 1,
      'middle' => 2,
      'right' => 3,
      _ => -1,
    };
    if (button < 0) {
      return const ToolResult(
        callId: '',
        content: 'error: button harus left | middle | right',
        isError: true,
      );
    }
    final isDouble = args['double'] == true;
    if (_inputEngineXdoto()) {
      final r = await runner.run(
        [
          'xdotool',
          'mousemove',
          '$x',
          '$y',
          'click',
          if (isDouble) ...['--repeat', '2'],
          '$button',
        ],
        timeout: timeout,
      );
      return _okOr(
          r, 'click $x,$y', isDouble ? 'double-$buttonName' : buttonName);
    }
    if (await _pythonHas('pyautogui')) {
      final script = 'import pyautogui; pyautogui.FAILSAFE=False; '
          'pyautogui.click(x=$x, y=$y, button=${_pyLiteral(buttonName)}, '
          'clicks=${isDouble ? 2 : 1})';
      final r = await runner.run(['python3', '-c', script], timeout: timeout);
      return _okOr(r, 'click $x,$y', isDouble ? 'double' : 'single');
    }
    return ToolResult(callId: '', content: _engineHint, isError: true);
  }

  Future<ToolResult> _type(Map<String, dynamic> args) async {
    final text = (args['text'] as String?) ?? '';
    if (text.isEmpty || text.length > 2000) {
      return const ToolResult(
        callId: '',
        content: 'error: text wajib diisi (1..2000 karakter)',
        isError: true,
      );
    }
    if (_inputEngineXdoto()) {
      final r = await runner.run(
        ['xdotool', 'type', '--clearmodifiers', '--', text],
        timeout: timeout,
      );
      return _okOr(r, 'type', '${text.length} karakter');
    }
    if (await _pythonHas('pyautogui')) {
      final script = 'import pyautogui; pyautogui.FAILSAFE=False; '
          'pyautogui.write(${_pyLiteral(text)})';
      final r = await runner.run(['python3', '-c', script], timeout: timeout);
      return _okOr(r, 'type', '${text.length} karakter');
    }
    return ToolResult(callId: '', content: _engineHint, isError: true);
  }

  Future<ToolResult> _key(Map<String, dynamic> args) async {
    final combo = ((args['combo'] as String?) ?? '').trim();
    if (combo.isEmpty || !_keyChars.hasMatch(combo) || combo.length > 64) {
      return const ToolResult(
        callId: '',
        content:
            'error: combo wajib diisi (karakter [A-Za-z0-9_+-] dan spasi '
            'untuk urutan, mis. "ctrl+s" atau "Return")',
        isError: true,
      );
    }
    if (_inputEngineXdoto()) {
      final r = await runner.run(
        ['xdotool', 'key', '--clearmodifiers', combo],
        timeout: timeout,
      );
      return _okOr(r, 'key', combo);
    }
    if (await _pythonHas('pyautogui')) {
      final parts = combo.split('+').map((e) => e.trim()).toList();
      final script = 'import pyautogui; pyautogui.FAILSAFE=False; '
          'pyautogui.hotkey(*[${parts.map(_pyLiteral).join(', ')}])';
      final r = await runner.run(['python3', '-c', script], timeout: timeout);
      return _okOr(r, 'key', combo);
    }
    return ToolResult(callId: '', content: _engineHint, isError: true);
  }

  Future<ToolResult> _scroll(Map<String, dynamic> args) async {
    final x = (args['x'] as num?)?.toInt() ?? -1;
    final y = (args['y'] as num?)?.toInt() ?? -1;
    final clicks = ((args['clicks'] as num?)?.toInt() ?? 3);
    if (x < 0 || y < 0 || x > 65535 || y > 65535) {
      return const ToolResult(
        callId: '',
        content: 'error: x dan y wajib integer 0..65535',
        isError: true,
      );
    }
    if (clicks < -20 || clicks > 20 || clicks == 0) {
      return const ToolResult(
        callId: '',
        content: 'error: clicks harus -20..20 dan tidak nol',
        isError: true,
      );
    }
    if (_inputEngineXdoto()) {
      final button = clicks > 0 ? 4 : 5;
      final r = await runner.run(
        [
          'xdotool',
          'mousemove',
          '$x',
          '$y',
          'click',
          '--repeat',
          '${clicks.abs()}',
          '$button',
        ],
        timeout: timeout,
      );
      return _okOr(r, 'scroll $x,$y', '${clicks.abs()} langkah');
    }
    if (await _pythonHas('pyautogui')) {
      final script = 'import pyautogui; pyautogui.FAILSAFE=False; '
          'pyautogui.moveTo($x, $y); pyautogui.scroll(${clicks.abs()})';
      final r = await runner.run(['python3', '-c', script], timeout: timeout);
      return _okOr(r, 'scroll $x,$y', '${clicks.abs()} langkah');
    }
    return ToolResult(callId: '', content: _engineHint, isError: true);
  }

  String _pyLiteral(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return "'$escaped'";
  }

  ToolResult _okOr(
    ComputerProcessResult r,
    String action,
    String detail,
  ) {
    if (r.exitCode == 0) {
      return ToolResult(callId: '', content: '$action ok ($detail)');
    }
    return ToolResult(
      callId: '',
      content: '$action gagal (exit ${r.exitCode}): ${_trim(r.message, 400)}',
      isError: true,
    );
  }
}
