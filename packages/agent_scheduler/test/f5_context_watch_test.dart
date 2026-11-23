import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

/// Fase F5 (docs/15 §6) — chaining konteks antar-job + probe watcher.
void main() {
  group('Job F5 fields', () {
    test('toJson/fromJson roundtrip context_from + watch', () async {
      final path =
          '${Directory.systemTemp.createTempSync().path}/jobs_f5.json';
      final store = JobStore(persistPath: path);
      final job = store.add(
        cron: '*/5 * * * *',
        prompt: 'cek status',
        channel: 'cli',
        userKey: 'u1',
        contextFrom: ['src-1', 'src-2'],
        watchProbe: WatchProbe.url('https://example.com/status'),
      );
      store.recordWatch(job.id, state: 'http:200:2:abcd1234');

      await store.save();
      final loaded = JobStore(persistPath: path);
      await loaded.load();
      final back = loaded.get(job.id)!;
      expect(back.contextFrom, ['src-1', 'src-2']);
      expect(back.watchProbe, isNotNull);
      expect(back.watchProbe!.url, 'https://example.com/status');
      expect(back.watchState, 'http:200:2:abcd1234');
      expect(back.watchProbeAt, isNotNull);

      final round = Job.fromJson(back.toJson());
      expect(round.contextFrom, back.contextFrom);
      expect(round.watchProbe!.url, back.watchProbe!.url);
      expect(round.watchState, back.watchState);
      expect(round.watchProbeAt, back.watchProbeAt);
    });

    test('fromJson: watch kind tak dikenal -> FormatException', () {
      expect(
        () => Job.fromJson({
          'id': 'j1',
          'cron': '*/5 * * * *',
          'prompt': 'p',
          'channel': 'cli',
          'user_key': 'u1',
          'next_run': DateTime.now().toUtc().toIso8601String(),
          'watch': {'kind': 'rss', 'url': 'https://x.example'},
        }),
        throwsFormatException,
      );
    });

    test('fromJson: watch_state non-string -> FormatException', () {
      expect(
        () => Job.fromJson({
          'id': 'j1',
          'cron': '*/5 * * * *',
          'prompt': 'p',
          'channel': 'cli',
          'user_key': 'u1',
          'next_run': DateTime.now().toUtc().toIso8601String(),
          'watch_state': 42,
        }),
        throwsFormatException,
      );
    });

    test('add: >5 context_from -> ArgumentError, duplikat dibuang', () {
      final store = JobStore(persistPath: '${Directory.systemTemp.createTempSync().path}/jobs_f5b.json');
      expect(
        () => store.add(
          cron: '*/5 * * * *',
          prompt: 'p',
          channel: 'cli',
          userKey: 'u1',
          contextFrom: List.generate(6, (i) => 'j$i'),
        ),
        throwsArgumentError,
      );
      final job = store.add(
        cron: '*/5 * * * *',
        prompt: 'p',
        channel: 'cli',
        userKey: 'u1',
        contextFrom: ['a', 'a', 'b'],
      );
      expect(job.contextFrom, ['a', 'b']);
    });

    test('add: watch url tidak http(s) -> FormatException', () {
      final store = JobStore(persistPath: '${Directory.systemTemp.createTempSync().path}/jobs_f5c.json');
      expect(
        () => store.add(
          cron: '*/5 * * * *',
          prompt: 'p',
          channel: 'cli',
          userKey: 'u1',
          watchProbe: WatchProbe.url('ftp://example.com/x'),
        ),
        throwsFormatException,
      );
    });

    test('update: set contextFrom + clearWatch mereset state watcher', () async {
      final path =
          '${Directory.systemTemp.createTempSync().path}/jobs_f5d.json';
      final store = JobStore(persistPath: path);
      final job = store.add(
        cron: '*/5 * * * *',
        prompt: 'p',
        channel: 'cli',
        userKey: 'u1',
        watchProbe: WatchProbe.url('https://example.com'),
      );
      store.recordWatch(job.id, state: 'x');
      expect(store.get(job.id)!.watchState, 'x');

      final updated = store.update(
        job.id,
        contextFrom: ['other'],
        clearWatch: true,
      );
      expect(updated!.contextFrom, ['other']);
      expect(updated.watchProbe, isNull);
      expect(updated.watchState, isNull);
      expect(updated.watchProbeAt, isNull);
    });

    test('recordWatch: id tak dikenal -> null', () {
      final store = JobStore(persistPath: '${Directory.systemTemp.createTempSync().path}/jobs_f5e.json');
      expect(store.recordWatch('nope', state: 'x'), isNull);
    });
  });

  group('ScheduleJobTool F5 args', () {
    test('menerima context_from + watch_url', () async {
      final store = JobStore(persistPath: '${Directory.systemTemp.createTempSync().path}/jobs_f5t.json');
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'u1'),
        workspacePath: '.',
      );
      final result = await ScheduleJobTool(store).run({
        'cron': '*/5 * * * *',
        'prompt': 'p',
        'context_from': ['job-a', 'job-b'],
        'watch_url': 'https://example.com/health',
      }, ctx);
      expect(result.isError, isFalse);
      final job = store.all.single;
      expect(job.contextFrom, ['job-a', 'job-b']);
      expect(job.watchProbe!.url, 'https://example.com/health');
    });

    test('watch_url invalid -> isError', () async {
      final store = JobStore(persistPath: '${Directory.systemTemp.createTempSync().path}/jobs_f5u.json');
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'u1'),
        workspacePath: '.',
      );
      final result = await ScheduleJobTool(store).run({
        'cron': '*/5 * * * *',
        'prompt': 'p',
        'watch_url': 'gopher://example.com',
      }, ctx);
      expect(result.isError, isTrue);
      expect(store.all, isEmpty);
    });
  });

  group('JobOutputStore', () {
    test('record -> load roundtrip, trim + cap entry', () async {
      final path =
          '${Directory.systemTemp.createTempSync().path}/outputs/job_outputs.json';
      final store = JobOutputStore(persistPath: path);
      await store.load();
      await store.record('j1', 'langkah 1 selesai');
      await store.record('j2', ' ' * 10);

      final store2 = JobOutputStore(persistPath: path);
      await store2.load();
      expect(store2.textFor('j1'), 'langkah 1 selesai');
      expect(store2.atFor('j1'), isNotNull);
      expect(store2.textFor('j2'), isNull);

      await store.record(
        'j3',
        'x' * (JobOutputStore.maxEntryLength + 10),
      );
      final trimmed = store.textFor('j3')!;
      expect(trimmed.length, JobOutputStore.maxEntryLength + 1);
      expect(trimmed.endsWith('…'), isTrue);
    });

    test('cap jumlah entry: entri tertua dibuang', () async {
      final path =
          '${Directory.systemTemp.createTempSync().path}/outputs2/job_outputs.json';
      final store = JobOutputStore(persistPath: path);
      await store.load();
      for (var i = 0; i < JobOutputStore.maxEntries + 5; i++) {
        await store.record('job-$i', 'out $i');
      }
      expect(store.length, JobOutputStore.maxEntries);
      expect(store.textFor('job-0'), isNull);
      expect(store.textFor('job-${JobOutputStore.maxEntries + 4}'), isNotNull);
    });

    test('file korup dilompati (fail-soft)', () async {
      final dir = Directory.systemTemp.createTempSync();
      final path = '${dir.path}/job_outputs.json';
      await File(path).writeAsString('{bukan json');
      await File('${path}.tmp').writeAsString('x');
      final store = JobOutputStore(persistPath: path);
      await store.load();
      expect(store.length, 0);
      await store.record('j1', 'ok setelah korup');
      final store2 = JobOutputStore(persistPath: path);
      await store2.load();
      expect(store2.textFor('j1'), 'ok setelah korup');
      expect(File('$path.tmp').existsSync(), isFalse);
    });
  });

  group('fnv1aHex', () {
    test('paritas nilai FNV-1a 32-bit ASCII', () {
      expect(fnv1aHex('hello'), '4f9f2cab');
      expect(fnv1aHex(''), '811c9dc5');
    });

    test('stabil & sensitif perubahan kecil', () {
      expect(fnv1aHex('status: OK'), fnv1aHex('status: OK'));
      expect(fnv1aHex('status: OK'), isNot(fnv1aHex('status: OK ')));
    });
  });
}
