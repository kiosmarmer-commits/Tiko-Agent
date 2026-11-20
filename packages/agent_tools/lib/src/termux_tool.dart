import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Termux tool for Android terminal integration.
class TermuxTool implements Tool {
  TermuxTool({
    this.termuxPrefix = 'termux-',
    this.timeout = const Duration(seconds: 30),
  });

  final String termuxPrefix;
  final Duration timeout;


  @override
  ToolSpec get spec => const ToolSpec(
        name: 'termux',
        description: 'Termux tool for Android terminal integration and command execution.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['run_command', 'install_package', 'uninstall_package', 'list_packages', 'check_package', 'update_packages', 'upgrade_packages', 'list_files', 'read_file', 'write_file', 'delete_file', 'create_directory', 'delete_directory', 'list_devices', 'get_info', 'set_clipboard', 'get_clipboard', 'toast', 'vibrate', 'notification'],
              'description': 'The Termux action to perform',
            },
            'command': {'type': 'string', 'description': 'Command to run'},
            'package': {'type': 'string', 'description': 'Package name'},
            'path': {'type': 'string', 'description': 'File or directory path'},
            'content': {'type': 'string', 'description': 'File content'},
            'text': {'type': 'string', 'description': 'Text for clipboard/toast/notification'},
            'title': {'type': 'string', 'description': 'Title for notification'},
            'duration': {'type': 'number', 'description': 'Duration in ms for vibrate'},
            'recursive': {'type': 'boolean', 'description': 'Recursive flag', 'default': false},
            'force': {'type': 'boolean', 'description': 'Force flag', 'default': false},
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String?;
      switch (action) {
        case 'run_command': return await _runCommand(args, ctx);
        case 'install_package': return await _installPackage(args, ctx);
        case 'uninstall_package': return await _uninstallPackage(args, ctx);
        case 'list_packages': return await _listPackages(args, ctx);
        case 'check_package': return await _checkPackage(args, ctx);
        case 'update_packages': return await _updatePackages(args, ctx);
        case 'upgrade_packages': return await _upgradePackages(args, ctx);
        case 'list_files': return await _listFiles(args, ctx);
        case 'read_file': return await _readFile(args, ctx);
        case 'write_file': return await _writeFile(args, ctx);
        case 'delete_file': return await _deleteFile(args, ctx);
        case 'create_directory': return await _createDirectory(args, ctx);
        case 'delete_directory': return await _deleteDirectory(args, ctx);
        case 'list_devices': return await _listDevices(args, ctx);
        case 'get_info': return await _getInfo(args, ctx);
        case 'set_clipboard': return await _setClipboard(args, ctx);
        case 'get_clipboard': return await _getClipboard(args, ctx);
        case 'toast': return await _toast(args, ctx);
        case 'vibrate': return await _vibrate(args, ctx);
        case 'notification': return await _notification(args, ctx);
        default: return ToolResult(
          callId: '',content: jsonEncode({'error': 'Unknown action'}), isError: true);
      }
    } catch (e) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': e.toString()}), isError: true);
    }
  }

  Future<ToolResult> _runCommand(Map<String, dynamic> args, ToolContext ctx) async {
    final command = args['command'] as String?;
    if (command == null || command.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'command is required'}), isError: true);
    }
    final result = await Process.run('sh', ['-c', command]);
    return ToolResult(
      callId: '',
      content: jsonEncode({'status': 'executed', 'command': command, 'exit_code': result.exitCode, 'stdout': result.stdout.toString(), 'stderr': result.stderr.toString()}),
      isError: result.exitCode != 0,
    );
  }

  Future<ToolResult> _installPackage(Map<String, dynamic> args, ToolContext ctx) async {
    final package = args['package'] as String?;
    if (package == null || package.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'package is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'pkg', ['install', '-y', package]);
    return ToolResult(
      callId: '',
      content: jsonEncode({'status': 'installed', 'package': package, 'exit_code': result.exitCode}),
      isError: result.exitCode != 0,
    );
  }

  Future<ToolResult> _uninstallPackage(Map<String, dynamic> args, ToolContext ctx) async {
    final package = args['package'] as String?;
    final force = args['force'] as bool? ?? false;
    if (package == null || package.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'package is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'pkg', ['uninstall', '-y', if (force) '-f', package]);
    return ToolResult(
      callId: '',
      content: jsonEncode({'status': 'uninstalled', 'package': package, 'exit_code': result.exitCode}),
      isError: result.exitCode != 0,
    );
  }

  Future<ToolResult> _listPackages(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run(termuxPrefix + 'pkg', ['list-installed']);
    final packages = result.stdout.toString().split('\n').where((line) => line.trim().isNotEmpty).toList();
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'listed', 'packages': packages, 'count': packages.length}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _checkPackage(Map<String, dynamic> args, ToolContext ctx) async {
    final package = args['package'] as String?;
    if (package == null || package.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'package is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'pkg', ['show', package]);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'checked', 'package': package, 'installed': result.exitCode == 0}), isError: false);
  }

  Future<ToolResult> _updatePackages(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run(termuxPrefix + 'pkg', ['update']);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'updated', 'exit_code': result.exitCode}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _upgradePackages(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run(termuxPrefix + 'pkg', ['upgrade', '-y']);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'upgraded', 'exit_code': result.exitCode}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _listFiles(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String? ?? '.';
    final result = await Process.run('ls', ['-la', path]);
    final files = result.stdout.toString().split('\n').where((line) => line.trim().isNotEmpty).toList();
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'listed', 'path': path, 'files': files, 'count': files.length}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _readFile(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'path is required'}), isError: true);
    }
    final file = File(path);
    if (!await file.exists()) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'File not found'}), isError: true);
    }
    final content = await file.readAsString();
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'read', 'path': path, 'content': content, 'size': content.length}), isError: false);
  }

  Future<ToolResult> _writeFile(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String?;
    final content = args['content'] as String?;
    if (path == null || path.isEmpty || content == null) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'path and content are required'}), isError: true);
    }
    final file = File(path);
    await file.writeAsString(content);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'written', 'path': path, 'size': content.length}), isError: false);
  }

  Future<ToolResult> _deleteFile(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'path is required'}), isError: true);
    }
    final file = File(path);
    if (!await file.exists()) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'File not found'}), isError: true);
    }
    await file.delete();
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'deleted', 'path': path}), isError: false);
  }

  Future<ToolResult> _createDirectory(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String?;
    final recursive = args['recursive'] as bool? ?? false;
    if (path == null || path.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'path is required'}), isError: true);
    }
    final dir = Directory(path);
    await dir.create(recursive: recursive);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'created', 'path': path, 'recursive': recursive}), isError: false);
  }

  Future<ToolResult> _deleteDirectory(Map<String, dynamic> args, ToolContext ctx) async {
    final path = args['path'] as String?;
    final recursive = args['recursive'] as bool? ?? false;
    if (path == null || path.isEmpty) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'path is required'}), isError: true);
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'Directory not found'}), isError: true);
    }
    await dir.delete(recursive: recursive);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'deleted', 'path': path, 'recursive': recursive}), isError: false);
  }

  Future<ToolResult> _listDevices(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run('termux-deviceinfo', ['list']);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'listed', 'devices': result.stdout.toString()}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _getInfo(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run('termux-info', []);
    final info = <String, String>{};
    final lines = result.stdout.toString().split('\n');
    for (final line in lines) {
      if (line.contains(':')) {
        final parts = line.split(':');
        if (parts.length >= 2) {
          info[parts[0].trim()] = parts.sublist(1).join(':').trim();
        }
      }
    }
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'retrieved', 'info': info}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _setClipboard(Map<String, dynamic> args, ToolContext ctx) async {
    final text = args['text'] as String?;
    if (text == null) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'text is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'clipboard-set', [text]);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'set', 'text': text}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _getClipboard(Map<String, dynamic> args, ToolContext ctx) async {
    final result = await Process.run(termuxPrefix + 'clipboard-get', []);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'retrieved', 'text': result.stdout.toString()}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _toast(Map<String, dynamic> args, ToolContext ctx) async {
    final text = args['text'] as String?;
    if (text == null) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'text is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'toast', [text]);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'shown', 'text': text}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _vibrate(Map<String, dynamic> args, ToolContext ctx) async {
    final duration = args['duration'] as num? ?? 1000;
    final result = await Process.run(termuxPrefix + 'vibrate', ['-d', duration.toString()]);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'vibrated', 'duration_ms': duration}), isError: result.exitCode != 0);
  }

  Future<ToolResult> _notification(Map<String, dynamic> args, ToolContext ctx) async {
    final title = args['title'] as String? ?? 'Notification';
    final text = args['text'] as String?;
    if (text == null) {
      return ToolResult(
        callId: '',content: jsonEncode({'error': 'text is required'}), isError: true);
    }
    final result = await Process.run(termuxPrefix + 'notification', ['--title', title, '--content', text]);
    return ToolResult(
      callId: '',content: jsonEncode({'status': 'shown', 'title': title, 'text': text}), isError: result.exitCode != 0);
  }
}
