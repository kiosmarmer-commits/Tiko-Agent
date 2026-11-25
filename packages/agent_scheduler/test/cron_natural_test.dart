import 'dart:io';

import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

/// Gap docs/13: frasa jadwal natural ("every 1h", "daily 09:00") menjadi
/// cron 5 field ketat — di JobStore.add normalisasi terjadi sebelum parse,
/// jadi CLI/HTTP cukup menerima frasa apa adanya.
void main() {
  group('normalizeCronInput', () {
    test('5 field lolos apa adanya (dan divalidasi CronExpression.parse)', () {
      expect(normalizeCronInput('*/5 * * * *'), '*/5 * * * *');
      expect(normalizeCronInput(' 0 8 * * * '), '0 8 * * *');
      expect(normalizeCronInput('bukan cron'), 'bukan cron', reason:
          'pass-through: kegagalan divalidasi CronExpression.parse di add()');
    });

    test('every <N> menit/jam/hari/minggu', () {
      expect(normalizeCronInput('every 30m'), '*/30 * * * *');
      expect(normalizeCronInput('Every 5 minutes'), '*/5 * * * *');
      expect(normalizeCronInput('every 1 menit'), '* * * * *');
      expect(normalizeCronInput('every 1h'), '0 * * * *');
      expect(normalizeCronInput('every 6 jam'), '0 */6 * * *');
      expect(normalizeCronInput('every 2 hari'), '0 0 */2 * *');
      expect(normalizeCronInput('EVERY 2 weeks'), '0 0 * * 1');
    });

    test('hourly/daily/weekly/monthly dengan alias Indonesia', () {
      expect(normalizeCronInput('hourly'), '0 * * * *');
      expect(normalizeCronInput('tiap jam'), '0 * * * *');
      expect(normalizeCronInput('daily 09:00'), '0 9 * * *');
      expect(normalizeCronInput('harian pukul 21:05'), '5 21 * * *');
      expect(normalizeCronInput('daily at 07:03'), '3 7 * * *');
      expect(normalizeCronInput('weekly mon 08:00'), '0 8 * * 1');
      expect(normalizeCronInput('mingguan jumat 09:30'), '30 9 * * 5');
      expect(normalizeCronInput('weekly sunday 12:00'), '0 12 * * 0');
      expect(normalizeCronInput('monthly 1 00:00'), '0 0 1 * *');
      expect(normalizeCronInput('bulanan 15 06:30'), '30 6 15 * *');
    });

    test('frasa dicoba tapi tidak lengkap -> FormatException (fail-closed)', () {
      expect(() => normalizeCronInput('daily'), throwsFormatException);
      expect(() => normalizeCronInput('every'), throwsFormatException);
      expect(() => normalizeCronInput('every 30 lightyear'),
          throwsFormatException);
      expect(() => normalizeCronInput('every 0 menit'), throwsFormatException);
      expect(() => normalizeCronInput('weekly senin'), throwsFormatException);
      expect(() => normalizeCronInput('daily 24:00'), throwsFormatException);
    });

    test('hasil normalisasi selalu valid untuk CronExpression.parse', () {
      for (final phrase in [
        'every 10m',
        'every 3h',
        'every 4 days',
        'hourly',
        'daily 06:30',
        'weekly kamis 09:00',
      ]) {
        expect(
          () => CronExpression.parse(normalizeCronInput(phrase)),
          returnsNormally,
          reason: phrase,
        );
      }
    });

    test('JobStore.add menerima frasa natural dan menyimpan cron ternormalisasi',
        () async {
      final tmp = await Directory.systemTemp.createTemp('cron-natural-');
      final store =
          JobStore(persistPath: '${tmp.path}/jobs.json');
      try {
        final job = store.add(
          cron: 'every 15 menit',
          prompt: 'uji',
          channel: 'cli',
          userKey: 'u',
        );
        expect(job.cron, '*/15 * * * *');
              } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('nextAfter menghormati frasa ternormalisasi', () {
      final next = CronExpression.parse(normalizeCronInput('every 30 menit'))
          .nextAfter(DateTime.utc(2026, 1, 1, 10, 15), timezone: 'UTC');
      expect(next.minute, anyOf(30, 45));
      expect(next.hour, 10);
    });
  });
}
