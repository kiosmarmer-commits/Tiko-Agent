/// Satu titik pivot (puncak atau lembah) pada deret harga.
class Pivot {
  final int indeks;
  final double harga;

  /// true = puncak (swing high), false = lembah (swing low).
  final bool tinggi;

  const Pivot(this.indeks, this.harga, this.tinggi);

  @override
  String toString() => 'Pivot($indeks, $harga, ${tinggi ? "tinggi" : "rendah"})';
}

/// Menyaring deret [harga] menjadi pivot bergantian (lembah, puncak, lembah, ...).
///
/// Pembalikan baru dianggap sah bila harga berbalik arah minimal [ambang]
/// (proporsi, 0.05 = 5%) dari ekstrem terakhir. Pivot terakhir pada hasil
/// adalah ekstrem sementara dari gerakan yang sedang berjalan.
List<Pivot> zigzag(List<double> harga, {double ambang = 0.05}) {
  final out = <Pivot>[];
  if (harga.length < 2 || ambang <= 0) return out;

  var tren = 0; // 0 belum jelas, 1 naik, -1 turun
  var hi = 0, lo = 0;

  for (var i = 1; i < harga.length; i++) {
    if (harga[i] > harga[hi]) hi = i;
    if (harga[i] < harga[lo]) lo = i;

    if (tren == 0) {
      if (harga[i] >= harga[lo] * (1 + ambang)) {
        out.add(Pivot(lo, harga[lo], false));
        tren = 1;
        hi = i;
      } else if (harga[i] <= harga[hi] * (1 - ambang)) {
        out.add(Pivot(hi, harga[hi], true));
        tren = -1;
        lo = i;
      }
    } else if (tren == 1) {
      if (harga[i] <= harga[hi] * (1 - ambang)) {
        out.add(Pivot(hi, harga[hi], true));
        tren = -1;
        lo = i;
      }
    } else {
      if (harga[i] >= harga[lo] * (1 + ambang)) {
        out.add(Pivot(lo, harga[lo], false));
        tren = 1;
        hi = i;
      }
    }
  }

  // Ekstrem sementara dari gerakan yang sedang berjalan.
  if (tren == 1 && (out.isEmpty || out.last.indeks != hi)) {
    out.add(Pivot(hi, harga[hi], true));
  }
  if (tren == -1 && (out.isEmpty || out.last.indeks != lo)) {
    out.add(Pivot(lo, harga[lo], false));
  }
  return out;
}
