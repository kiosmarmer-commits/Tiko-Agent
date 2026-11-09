import 'package:agent_core/agent_core.dart';

import 'cron.dart';
import 'job_store.dart';

/// Tool schedule_job (TASK-05-04) — medium risk, needs confirm in ask mode.
class ScheduleJobTool implements Tool {
  ScheduleJobTool(this.store);

  final JobStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'schedule_job',
    description:
        'Jadwalkan prompt berkala. cron: 5 field (menit jam dom bulan dow), mis. "0 7 * * 1-5".',
    inputSchema: {
      'type': 'object',
      'properties': {
        'cron': {'type': 'string'},
        'prompt': {'type': 'string'},
        'channel': {'type': 'string', 'description': 'cli | telegram | …'},
        'user_key': {'type': 'string'},
        'missed_policy': {
          'type': 'string',
          'description': 'skip | run_once | catch_up',
        },
        'timezone': {
          'type': 'string',
          'description':
              'Nama zona IANA penuh, mis. Asia/Jakarta atau America/New_York; DST dihitung otomatis',
        },
      },
      'required': ['cron', 'prompt'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cron = (args['cron'] as String?)?.trim() ?? '';
    final prompt = (args['prompt'] as String?)?.trim() ?? '';
    if (cron.isEmpty || prompt.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'cron dan prompt wajib',
        isError: true,
      );
    }
    try {
      CronExpression.parse(cron);
    } catch (e) {
      return ToolResult(callId: '', content: 'cron invalid: $e', isError: true);
    }

    final policyName = (args['missed_policy'] as String?) ?? 'run_once';
    final policy = MissedPolicy.values.firstWhere(
      (p) => p.name == policyName || p.name == policyName.replaceAll('_', ''),
      orElse: () => MissedPolicy.runOnce,
    );

    final timezone = (args['timezone'] as String?) ?? 'UTC';
    late final Job job;
    try {
      job = await store.addAndSave(
        cron: cron,
        prompt: prompt,
        channel: (args['channel'] as String?) ?? ctx.session.channel,
        userKey: (args['user_key'] as String?) ?? ctx.session.userKey,
        missedPolicy: policy,
        timezone: timezone,
      );
    } catch (error) {
      return ToolResult(callId: '', content: 'job tidak dapat disimpan: $error', isError: true);
    }

    return ToolResult(
      callId: '',
      content:
          'Job dibuat id=${job.id}\ncron=${job.cron}'
          '\ntz=${job.timezone}'
          '\nnext_run=${job.nextRun.toIso8601String()}'
          '\nprompt=${job.prompt}',
    );
  }
}

class ListJobsTool implements Tool {
  ListJobsTool(this.store);
  final JobStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'list_jobs',
    description: 'Daftar job terjadwal.',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final jobs = store.all;
    if (jobs.isEmpty) {
      return const ToolResult(callId: '', content: '(tidak ada job)');
    }
    final lines = jobs.map((j) {
      return '${j.id}  ${j.enabled ? "ON" : "OFF"}  ${j.cron}'
          '  tz=${j.timezone}  next=${j.nextRun.toIso8601String()}'
          '\n  ${j.prompt}';
    });
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}

class CancelJobTool implements Tool {
  CancelJobTool(this.store);
  final JobStore store;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'cancel_job',
    description: 'Hapus job by id.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final id = (args['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      return const ToolResult(callId: '', content: 'id wajib', isError: true);
    }
    final ok = store.remove(id);
    return ToolResult(
      callId: '',
      content: ok ? 'Job $id dihapus' : 'Job $id tidak ditemukan',
      isError: !ok,
    );
  }
}
