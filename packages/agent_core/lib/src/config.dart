import 'dart:io';

/// Minimal YAML-ish loader for config/agent.yaml (subset enough for our config).
class AppConfig {
  AppConfig({
    this.maxIterations = 12,
    this.maxTokensPerTask = 60000,
    this.maxWallClockSec = 300,
    this.maxToolCalls = 30,
    this.defaultProvider = 'mock',
    this.shellAllowlist = const ['ls', 'cat', 'git status', 'pwd', 'echo'],
    this.requireConfirm = const [
      'write_file',
      'shell',
      'http_request',
      'schedule_job',
    ],
    this.permissionMode = 'ask',
    this.searxngBaseUrl = 'http://127.0.0.1:8080',
    this.workspace = '.',
    this.schedulerTickSec = 20,
    this.httpDomainAllowlist = const [],
    this.dbPath = 'data/agent.db',
    this.dataDir = 'data',
    this.skillsDir = 'skills',
    this.logsDir = 'logs',
    this.mcpServers = const [],
    this.telegramAllowedUserIds = const [],
  });

  int maxIterations;
  int maxTokensPerTask;
  int maxWallClockSec;
  int maxToolCalls;
  String defaultProvider;
  List<String> shellAllowlist;
  List<String> requireConfirm;
  String permissionMode;
  String searxngBaseUrl;
  String workspace;
  int schedulerTickSec;
  List<String> httpDomainAllowlist;
  String dbPath;
  String dataDir;
  String skillsDir;
  String logsDir;
  List<Map<String, dynamic>> mcpServers;
  List<int> telegramAllowedUserIds;

  static AppConfig load([String path = 'config/agent.yaml']) {
    final file = File(path);
    if (!file.existsSync()) return AppConfig();
    return parse(file.readAsStringSync());
  }

  static AppConfig parse(String text) {
    final c = AppConfig();
    String? section;
    for (final raw in text.split('\n')) {
      final line = raw.split('#').first.trimRight();
      if (line.trim().isEmpty) continue;
      final t = line.trim();
      if (!line.startsWith(' ') &&
          !line.startsWith('\t') &&
          t.endsWith(':') &&
          !t.contains(' ')) {
        section = t.substring(0, t.length - 1);
        continue;
      }
      if (!t.contains(':')) continue;
      final idx = t.indexOf(':');
      final key = t.substring(0, idx).trim();
      var val = t.substring(idx + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) ||
          (val.startsWith("'") && val.endsWith("'"))) {
        val = val.substring(1, val.length - 1);
      }

      void setInt(void Function(int) f) {
        final n = int.tryParse(val);
        if (n != null) f(n);
      }

      if (section == 'agent') {
        if (key == 'max_iterations') setInt((n) => c.maxIterations = n);
        if (key == 'max_tokens_per_task') setInt((n) => c.maxTokensPerTask = n);
        if (key == 'max_wall_clock_sec') setInt((n) => c.maxWallClockSec = n);
        if (key == 'max_tool_calls') setInt((n) => c.maxToolCalls = n);
      } else if (section == 'providers' && key == 'default_chat') {
        c.defaultProvider = val;
      } else if (section == 'security') {
        if (key == 'mode') c.permissionMode = val;
        if (key == 'shell_allowlist') c.shellAllowlist = _list(val);
        if (key == 'require_confirm') c.requireConfirm = _list(val);
      } else if (section == 'search' && key == 'searxng_base_url') {
        c.searxngBaseUrl = val;
      } else if (key == 'workspace') {
        c.workspace = val;
      } else if (section == 'scheduler' && key == 'tick_interval_sec') {
        setInt((n) => c.schedulerTickSec = n);
      } else if (section == 'http' && key == 'domain_allowlist') {
        c.httpDomainAllowlist = _list(val);
      } else if (section == 'storage') {
        if (key == 'db_path') c.dbPath = val;
        if (key == 'data_dir') c.dataDir = val;
      }
    }
    return c;
  }

  static List<String> _list(String val) {
    val = val.trim();
    if (val.startsWith('[')) {
      return val
          .substring(1, val.endsWith(']') ? val.length - 1 : val.length)
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return [val];
  }
}
