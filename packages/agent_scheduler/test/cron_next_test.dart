import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('parse menolak 31 Februari', () {
    expect(() => CronExpression.parse('0 0 31 2 *'), throwsFormatException);
  });

  test('parse menolak 30 Februari', () {
    expect(() => CronExpression.parse('0 0 30 2 *'), throwsFormatException);
  });

  test('parse menolak 31 April', () {
    expect(() => CronExpression.parse('0 0 31 4 *'), throwsFormatException);
  });

  test('31 Februari dengan dow dibatasi tetap valid karena OR', () {
    final c = CronExpression.parse('0 0 31 2 1');
    expect(c.doms, contains(31));
  });

  test('29 Februari valid karena tahun kabisat', () {
    final c = CronExpression.parse('0 0 29 2 *');
    expect(c.doms, contains(29));
  });

  test('nextAfter menemukan 29 Februari berikutnya', () {
    final c = CronExpression.parse('0 0 29 2 *');
    final next = c.nextAfter(DateTime.utc(2026, 11, 7));
    expect(next, DateTime.utc(2028, 2, 29));
  });

  test('nextAfter OR: Senin Februari ketika dom mustahil', () {
    final c = CronExpression.parse('0 0 31 2 1');
    final next = c.nextAfter(DateTime.utc(2026, 11, 7));
    expect(next, DateTime.utc(2027, 2, 1));
  });

  test('nextAfter menit berikutnya di jam yang sama', () {
    final c = CronExpression.parse('15,45 * * * *');
    final next = c.nextAfter(DateTime.utc(2026, 11, 7, 10, 20));
    expect(next, DateTime.utc(2026, 11, 7, 10, 45));
  });
}
