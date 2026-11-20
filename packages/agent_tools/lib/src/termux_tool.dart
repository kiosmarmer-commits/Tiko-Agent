import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Termux tool for Android terminal integration.
///
/// Termux is a powerful terminal emulator for Android that provides
/// a Linux environment on mobile devices. This tool allows AI agents
/// to interact with Termux commands and manage the Termux environment.
///
/// Configuration:
/// - termuxPrefix: Termux command prefix (default: 'termux-')
/// - timeout: Command timeout (default: 30 seconds)
class TermuxTool implements Tool {
  TermuxTool({
    this.termuxPrefix = 'termux-',
    this.timeout = const Duration(seconds: 30),
  });

  final String termuxPrefix;
  final Duration timeout;

  @override
  String get name => 'termux';

  @override
  String get description =>
      'Termux tool for Android terminal integration and command execution.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'run_command',
                'install_package',
                'uninstall_package',
                'list_packages',
                'check_package',
                'update_packages',
                'upgrade_packages',
                'list_files',
                'read_file',
                'write_file',
                'delete_file',
                'create_directory',
                'delete_directory',
                'list_devices',
                'get_info',
                'set_clipboard',
                'get_clipboard',
                'toast',
                'vibrate',
                'notification',
              ],
              'description': 'The Termux action to perform',
            },
            'command': {
              'type': 'string',
              'description': 'Command to run',
            },
            'package': {
              'type': 'string',
              'description': 'Package name for package management actions',
            },
            'path': {
              'type': 'string',
              'description': 'File or directory path',
            },
            'content': {
              'type': 'string',
              'description': 'File content for write_file',
            },
            'text': {
              'type': 'string',
              'description': 'Text for clipboard, toast, or notification',
            },
            'title': {
              'type': 'string',
              'description': 'Title for notification',
            },
            'duration': {
              'type': 'number',
              'description': 'Duration in milliseconds for vibrate',
            },
            'recursive': {
              'type': 'boolean',
              'description': 'Recursive flag for directory operations',
              'default': false,
            },
            'force': {
              'type': 'boolean',
              'description': 'Force flag for operations',
              'default': false,
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(ToolCall call) async {
    try {
      final action = call.args['action'] as String?;
      
      switch (action) {
        case 'run_command':
          return await _runCommand(call);
        case 'install_package':
          return await _installPackage(call);
        case 'uninstall_package':
          return await _uninstallPackage(call);
        case 'list_packages':
          return await _listPackages(call);
        case 'check_package':
          return await _checkPackage(call);
        case 'update_packages':
          return await _updatePackages(call);
        case 'upgrade_packages':
          return await _upgradePackages(call);
        case 'list_files':
          return await _listFiles(call);
        case 'read_file':
          return await _readFile(call);
        case 'write_file':
          return await _writeFile(call);
        case 'delete_file':
          return await _deleteFile(call);
        case 'create_directory':
          return await _createDirectory(call);
        case 'delete_directory':
          return await _deleteDirectory(call);
        case 'list_devices':
          return await _listDevices(call);
        case 'get_info':
          return await _getInfo(call);
        case 'set_clipboard':
          return await _setClipboard(call);
        case 'get_clipboard':
          return await _getClipboard(call);
        case 'toast':
          return await _toast(call);
        case 'vibrate':
          return await _vibrate(call);
        case 'notification':
          return await _notification(call);
        default:
          return ToolResult(
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _runCommand(ToolCall call) async {
    try {
      final command = call.args['command'] as String?;
      
      if (command == null || command.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'command is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        'sh',
        ['-c', command],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'executed',
          'command': command,
          'exit_code': result.exitCode,
          'stdout': result.stdout.toString(),
          'stderr': result.stderr.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to run command: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _installPackage(ToolCall call) async {
    try {
      final package = call.args['package'] as String?;
      
      if (package == null || package.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'package is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['install', '-y', package],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'installed',
          'package': package,
          'exit_code': result.exitCode,
          'stdout': result.stdout.toString(),
          'stderr': result.stderr.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to install package: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _uninstallPackage(ToolCall call) async {
    try {
      final package = call.args['package'] as String?;
      final force = call.args['force'] as bool? ?? false;
      
      if (package == null || package.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'package is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['uninstall', '-y', if (force) '-f', package],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'uninstalled',
          'package': package,
          'exit_code': result.exitCode,
          'stdout': result.stdout.toString(),
          'stderr': result.stderr.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to uninstall package: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listPackages(ToolCall call) async {
    try {
      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['list-installed'],
        timeout: timeout,
      );

      final packages = result.stdout.toString().split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();

      return ToolResult(
        content: jsonEncode({
          'status': 'listed',
          'packages': packages,
          'count': packages.length,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list packages: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _checkPackage(ToolCall call) async {
    try {
      final package = call.args['package'] as String?;
      
      if (package == null || package.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'package is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['show', package],
        timeout: timeout,
      );

      final isInstalled = result.exitCode == 0;

      return ToolResult(
        content: jsonEncode({
          'status': 'checked',
          'package': package,
          'installed': isInstalled,
          'info': result.stdout.toString(),
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to check package: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _updatePackages(ToolCall call) async {
    try {
      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['update'],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'updated',
          'exit_code': result.exitCode,
          'stdout': result.stdout.toString(),
          'stderr': result.stderr.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to update packages: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _upgradePackages(ToolCall call) async {
    try {
      final result = await Process.run(
        termuxPrefix + 'pkg',
        ['upgrade', '-y'],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'upgraded',
          'exit_code': result.exitCode,
          'stdout': result.stdout.toString(),
          'stderr': result.stderr.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to upgrade packages: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listFiles(ToolCall call) async {
    try {
      final path = call.args['path'] as String? ?? '.';
      
      final result = await Process.run(
        'ls',
        ['-la', path],
        timeout: timeout,
      );

      final files = result.stdout.toString().split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();

      return ToolResult(
        content: jsonEncode({
          'status': 'listed',
          'path': path,
          'files': files,
          'count': files.length,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list files: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _readFile(ToolCall call) async {
    try {
      final path = call.args['path'] as String?;
      
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }

      final file = File(path);
      if (!await file.exists()) {
        return ToolResult(
          content: jsonEncode({'error': 'File not found: $path'}),
          isError: true,
        );
      }

      final content = await file.readAsString();

      return ToolResult(
        content: jsonEncode({
          'status': 'read',
          'path': path,
          'content': content,
          'size': content.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to read file: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _writeFile(ToolCall call) async {
    try {
      final path = call.args['path'] as String?;
      final content = call.args['content'] as String?;
      
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }
      if (content == null) {
        return ToolResult(
          content: jsonEncode({'error': 'content is required'}),
          isError: true,
        );
      }

      final file = File(path);
      await file.writeAsString(content);

      return ToolResult(
        content: jsonEncode({
          'status': 'written',
          'path': path,
          'size': content.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to write file: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _deleteFile(ToolCall call) async {
    try {
      final path = call.args['path'] as String?;
      
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }

      final file = File(path);
      if (!await file.exists()) {
        return ToolResult(
          content: jsonEncode({'error': 'File not found: $path'}),
          isError: true,
        );
      }

      await file.delete();

      return ToolResult(
        content: jsonEncode({
          'status': 'deleted',
          'path': path,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to delete file: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createDirectory(ToolCall call) async {
    try {
      final path = call.args['path'] as String?;
      final recursive = call.args['recursive'] as bool? ?? false;
      
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }

      final dir = Directory(path);
      await dir.create(recursive: recursive);

      return ToolResult(
        content: jsonEncode({
          'status': 'created',
          'path': path,
          'recursive': recursive,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to create directory: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _deleteDirectory(ToolCall call) async {
    try {
      final path = call.args['path'] as String?;
      final recursive = call.args['recursive'] as bool? ?? false;
      
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }

      final dir = Directory(path);
      if (!await dir.exists()) {
        return ToolResult(
          content: jsonEncode({'error': 'Directory not found: $path'}),
          isError: true,
        );
      }

      await dir.delete(recursive: recursive);

      return ToolResult(
        content: jsonEncode({
          'status': 'deleted',
          'path': path,
          'recursive': recursive,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to delete directory: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listDevices(ToolCall call) async {
    try {
      final result = await Process.run(
        'termux-deviceinfo',
        ['list'],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'listed',
          'devices': result.stdout.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list devices: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getInfo(ToolCall call) async {
    try {
      final result = await Process.run(
        'termux-info',
        [],
        timeout: timeout,
      );

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
        content: jsonEncode({
          'status': 'retrieved',
          'info': info,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get info: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _setClipboard(ToolCall call) async {
    try {
      final text = call.args['text'] as String?;
      
      if (text == null) {
        return ToolResult(
          content: jsonEncode({'error': 'text is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'clipboard-set',
        [text],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'set',
          'text': text,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to set clipboard: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getClipboard(ToolCall call) async {
    try {
      final result = await Process.run(
        termuxPrefix + 'clipboard-get',
        [],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'retrieved',
          'text': result.stdout.toString(),
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get clipboard: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _toast(ToolCall call) async {
    try {
      final text = call.args['text'] as String?;
      
      if (text == null) {
        return ToolResult(
          content: jsonEncode({'error': 'text is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'toast',
        [text],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'shown',
          'text': text,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to show toast: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _vibrate(ToolCall call) async {
    try {
      final duration = call.args['duration'] as num? ?? 1000;
      
      final result = await Process.run(
        termuxPrefix + 'vibrate',
        ['-d', duration.toString()],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'vibrated',
          'duration_ms': duration,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to vibrate: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _notification(ToolCall call) async {
    try {
      final title = call.args['title'] as String? ?? 'Notification';
      final text = call.args['text'] as String?;
      
      if (text == null) {
        return ToolResult(
          content: jsonEncode({'error': 'text is required'}),
          isError: true,
        );
      }

      final result = await Process.run(
        termuxPrefix + 'notification',
        ['--title', title, '--content', text],
        timeout: timeout,
      );

      return ToolResult(
        content: jsonEncode({
          'status': 'shown',
          'title': title,
          'text': text,
        }),
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to show notification: ${e.toString()}'}),
        isError: true,
      );
    }
  }
}
