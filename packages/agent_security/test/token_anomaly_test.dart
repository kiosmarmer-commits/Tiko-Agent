import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  final base = DateTime.utc(2026, 11, 17, 8);

  group('TokenAnomalyDetector (E1)', () {
    test('belum ada alarm sebelum sampel minimum tercapai', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      for (var i = 0; i < 4; i++) {
        final a = d.observe('s', 100, base.add(Duration(minutes: i)));
        expect(a, isNull, reason: 'sampel ke-${i + 1} belum boleh alarm');
      }
    });

    test('lonjakan jauh di atas baseline terdeteksi', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      final a = d.observe('s', 5000, base.add(const Duration(minutes: 5)));
      expect(a, isNotNull);
      expect(a!.slug, 's');
      expect(a.tokens, 5000);
      expect(a.baselineMean, closeTo(100, 0.01));
      expect(a.samples, 5); // baseline tanpa sampel pemicu
    });

    test('variasi normal TIDAK ditandai (lindungi false positive)', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      final samples = [95, 105, 100, 110, 90];
      for (var i = 0; i < samples.length; i++) {
        d.observe('s', samples[i], base.add(Duration(minutes: i)));
      }
      // 150 = ~1.9x rata-rata, di bawah lantai rasio 3x.
      final a = d.observe('s', 150, base.add(const Duration(minutes: 5)));
      expect(a, isNull);
    });

    test('baseline datar (stddev 0): lantai rasio mencegah alarm kecil', () {
      final d = TokenAnomalyDetector(minSamples: 5, minSpikeRatio: 3.0);
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      // 250 = 2.5x: di bawah lantai rasio -> tidak alarm meski z-score
      // meledak karena stddev 0.
      expect(d.observe('s', 250, base.add(const Duration(minutes: 5))), isNull);
      // 1000 = 10x: lolos lantai rasio -> alarm.
      expect(
          d.observe('s', 1000, base.add(const Duration(minutes: 6))), isNotNull);
    });

    test('cooldown: alarm kedua untuk skill sama diredam sementara', () {
      final d = TokenAnomalyDetector(
        minSamples: 5,
        cooldown: const Duration(minutes: 60),
      );
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      expect(
          d.observe('s', 5000, base.add(const Duration(minutes: 5))), isNotNull);
      // Masih dalam cooldown -> tidak alarm lagi.
      expect(d.observe('s', 9000, base.add(const Duration(minutes: 10))), isNull);
      // Setelah cooldown lewat -> alarm lagi (lonjakan besar: baseline
      // sudah tercemar sampel 5000/9000, jadi pakai lonjakan ekstrem).
      expect(
          d.observe('s', 50000, base.add(const Duration(minutes: 70))),
          isNotNull);
    });

    test('skill berbeda punya baseline dan cooldown terpisah', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      for (var i = 0; i < 5; i++) {
        d.observe('a', 100, base.add(Duration(minutes: i)));
      }
      // Skill b baru 1 sampel -> belum bisa alarm.
      expect(d.observe('b', 99999, base.add(const Duration(minutes: 5))), isNull);
      // Skill a tetap bisa alarm.
      expect(
          d.observe('a', 5000, base.add(const Duration(minutes: 6))), isNotNull);
    });

    test('jendela rolling FIFO membatasi ukuran sampel', () {
      final d = TokenAnomalyDetector(
        minSamples: 5,
        windowSize: 6,
        minSpikeRatio: 3.0,
      );
      // 5 sampel 100, lalu 1 sampel 10000 (ikut jendela), lalu kembali 100.
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      d.observe('s', 10000, base.add(const Duration(minutes: 5)));
      final stats = d.statsFor('s');
      expect(stats['samples'], 6);
      // Sampel terlama (100 pertama) tergeser keluar setelah 1 sampel lagi.
      // Jendela: [100,100,100,100,10000,100] -> mean = 10500/6 = 1750.
      d.observe('s', 100, base.add(const Duration(minutes: 6)));
      final stats2 = d.statsFor('s');
      expect(stats2['samples'], 6);
      expect(stats2['last'], 100);
      expect(stats2['mean'], closeTo(10500 / 6, 0.01));
    });

    test('reset menghapus baseline skill tertentu atau semua', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      d.reset('s');
      expect(d.statsFor('s')['samples'], 0);
      expect(d.observe('s', 5000, base.add(const Duration(minutes: 5))), isNull);
    });

    test('input tidak valid (slug kosong / token negatif) diabaikan', () {
      final d = TokenAnomalyDetector(minSamples: 2);
      expect(d.observe('', 100, base), isNull);
      expect(d.observe('s', -5, base), isNull);
      expect(d.statsFor('')['samples'], 0);
    });

    test('statsFor melaporkan mean/stddev/last', () {
      final d = TokenAnomalyDetector(minSamples: 5);
      for (var i = 0; i < 5; i++) {
        d.observe('s', 100, base.add(Duration(minutes: i)));
      }
      final stats = d.statsFor('s');
      expect(stats['samples'], 5);
      expect(stats['mean'], 100.0);
      expect(stats['stddev'], 0.0);
      expect(stats['last'], 100);
    });
  });
}
