import 'package:prediksi/prediksi.dart';
import 'package:test/test.dart';

void main() {
  group('SiklusBenner', () {
    final benner = SiklusBenner();

    test('2026 adalah good times -> jual', () {
      final s = benner.pada(DateTime.utc(2026, 11, 12));
      expect(s.arah, Arah.jual);
    });

    test('2023 adalah hard times -> beli', () {
      expect(benner.pada(DateTime.utc(2023, 6, 1)).arah, Arah.beli);
    });

    test('1999 bertumpuk panic + good times -> pakai panic (skor -1)', () {
      expect(benner.pada(DateTime.utc(1999, 1, 1)).skor, closeTo(-1, 1e-9));
    });

    test('tahun antar peristiwa memberi fase', () {
      // 2024 tidak ada di tabel; terakhir = 2023 (hard times).
      expect(benner.pada(DateTime.utc(2024, 5, 1)).skor, closeTo(0.3, 1e-9));
    });
  });

  group('SiklusPeriodik', () {
    test('di puncak skor -1, di lembah skor +1', () {
      const s = SiklusPeriodik(nama: 'uji', periodeTahun: 10, acuanPuncak: 2000);
      expect(s.pada(DateTime.utc(2000, 1, 1)).skor, closeTo(-1, 1e-6));
      expect(s.pada(DateTime.utc(2005, 1, 1)).skor, closeTo(1, 0.01));
    });
  });

  group('HalvingBitcoin', () {
    test('sekitar 31 bulan setelah halving 2024 -> akumulasi', () {
      final s = HalvingBitcoin().pada(DateTime.utc(2026, 11, 12));
      expect(s.skor, closeTo(0.3, 1e-9));
    });

    test('sebelum halving pertama -> tahan', () {
      expect(HalvingBitcoin().pada(DateTime.utc(2010, 1, 1)).arah, Arah.tahan);
    });
  });

  test('SiklusGabungan menghasilkan skor dalam rentang -1..1', () {
    final s = SiklusGabungan.pasarUmum().pada(DateTime.utc(2026, 11, 12));
    expect(s.skor, inInclusiveRange(-1, 1));
  });
}
