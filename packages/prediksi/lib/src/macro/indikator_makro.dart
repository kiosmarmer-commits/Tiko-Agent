import '../core/math_utils.dart';
import '../core/models.dart';

/// Suku bunga kebijakan dan inflasi. Kenaikan suku bunga dan inflasi di atas
/// target dianggap tekanan bagi aset berisiko; penurunan dianggap dukungan.
/// Satuan input: persen.
class SukuBungaInflasi {
  /// Target inflasi bank sentral (default 2.5, sesuaikan dengan negaramu).
  final double targetInflasi;

  const SukuBungaInflasi({this.targetInflasi = 2.5});

  String get nama => 'Suku Bunga & Inflasi';

  /// [sukuBungaSebelumnya] = level beberapa bulan lalu (mis. 6 bulan).
  Sinyal sinyal({
    required double sukuBunga,
    required double sukuBungaSebelumnya,
    required double inflasi,
  }) {
    final delta = sukuBunga - sukuBungaSebelumnya;
    final riil = sukuBunga - inflasi;
    final skorArah = -MathUtils.tanh(delta / 0.75);
    final skorInflasi = -MathUtils.tanh((inflasi - targetInflasi) / 2);
    final skor = 0.6 * skorArah + 0.4 * skorInflasi;
    final tanda = delta >= 0 ? '+' : '';
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'Suku bunga $tanda${delta.toStringAsFixed(2)} poin, inflasi ${inflasi.toStringAsFixed(1)}% '
          '(target ${targetInflasi.toStringAsFixed(1)}%), suku bunga riil ${riil.toStringAsFixed(2)}%',
    );
  }
}

/// PMI manufaktur: di atas 50 = ekspansi, di bawah 50 = kontraksi.
class PmiManufaktur {
  const PmiManufaktur();

  String get nama => 'PMI Manufaktur';

  Sinyal sinyal({required double pmi, double? pmiSebelumnya}) {
    var skor = MathUtils.tanh((pmi - 50) / 4);
    var ket = pmi >= 50 ? 'ekspansi' : 'kontraksi';
    if (pmiSebelumnya != null) {
      final delta = pmi - pmiSebelumnya;
      skor = 0.7 * skor + 0.3 * MathUtils.tanh(delta / 2);
      ket += delta >= 0 ? ', membaik' : ', memburuk';
    }
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan: 'PMI ${pmi.toStringAsFixed(1)}: $ket',
    );
  }
}

/// Aturan Sahm untuk data pengangguran bulanan (persen).
///
/// Sinyal resesi menyala bila rata-rata 3 bulan terakhir naik >= 0,5 poin dari
/// titik terendah rata-rata 3 bulan dalam 12 bulan sebelumnya. Butuh minimal
/// 15 data bulanan, urut dari yang terlama.
class AturanSahm {
  const AturanSahm();

  String get nama => 'Aturan Sahm';

  Sinyal sinyal(List<double> pengangguran) {
    final n = pengangguran.length;
    if (n < 15) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= 15 bulan, ada $n).',
      );
    }
    final rata3 = <double>[
      for (var i = 2; i < n; i++)
        (pengangguran[i] + pengangguran[i - 1] + pengangguran[i - 2]) / 3,
    ];
    final sekarang = rata3.last;
    final dasar = rata3
        .sublist(rata3.length - 13, rata3.length - 1)
        .reduce((a, b) => a < b ? a : b);
    final selisih = sekarang - dasar;

    final skor = selisih >= 0.5 ? -0.9 : -MathUtils.tanh(selisih / 0.5) * 0.5;
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'Rata-rata 3 bulan ${sekarang.toStringAsFixed(2)}%, naik ${selisih.toStringAsFixed(2)} poin dari dasar 12 bulan'
          '${selisih >= 0.5 ? " (ambang Sahm terlampaui)" : ""}',
    );
  }
}
