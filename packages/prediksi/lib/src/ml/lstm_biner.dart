import 'dart:math' as math;
import 'dart:typed_data';

import '../core/math_utils.dart';
import 'dasar_ml.dart';

double _sigmoid(double x) =>
    1 / (1 + math.exp(-x.clamp(-30.0, 30.0).toDouble()));

/// Catatan nilai antara saat forward, dibutuhkan oleh backward.
class _Jejak {
  final List<Float64List> z = [];
  final List<Float64List> i = [];
  final List<Float64List> f = [];
  final List<Float64List> g = [];
  final List<Float64List> o = [];
  final List<Float64List> cPrev = [];
  final List<Float64List> tc = [];
  final List<Float64List> h = [];
  double y = 0.5;
}

/// LSTM satu lapis untuk klasifikasi biner (peluang kelas 1).
///
/// Masukan [x] adalah urutan yang diratakan: [panjangUrutan] langkah, masing-
/// masing berisi d fitur (jadi x.length = panjangUrutan * d). Keluaran adalah
/// sigmoid dari lapisan dense di atas hidden state terakhir. Dilatih dengan
/// backpropagation through time, binary cross-entropy, dan optimizer Adam.
///
/// Ini implementasi edukasi: lambat dibanding library ML sungguhan dan tidak
/// menjamin hasil bagus pada data pasar.
class LstmBiner implements PengklasifikasiBiner {
  final int panjangUrutan;
  final int tersembunyi;
  final int epoch;
  final int ukuranBatch;
  final double lajuBelajar;
  final int benih;

  LstmBiner({
    this.panjangUrutan = 10,
    this.tersembunyi = 8,
    this.epoch = 25,
    this.ukuranBatch = 16,
    this.lajuBelajar = 0.02,
    this.benih = 11,
  })  : assert(panjangUrutan > 0),
        assert(tersembunyi > 0),
        assert(epoch > 0),
        assert(ukuranBatch > 0);

  int _d = 0;
  Float64List _p = Float64List(0);
  Float64List _g = Float64List(0);
  Float64List _m = Float64List(0);
  Float64List _v = Float64List(0);
  List<double> _rata = [];
  List<double> _sd = [];

  // Letak parameter di dalam vektor _p.
  int get _nIn => _d + tersembunyi;
  int get _offW => 0;
  int get _offB => 4 * tersembunyi * _nIn;
  int get _offWy => _offB + 4 * tersembunyi;
  int get _offBy => _offWy + tersembunyi;
  int get _jumlahParam => _offBy + 1;

  List<double> _skalakan(List<double> x) => [
        for (var k = 0; k < x.length; k++)
          (x[k] - _rata[k % _d]) / _sd[k % _d],
      ];

  _Jejak _maju(List<double> xs) {
    final hh = tersembunyi, nIn = _nIn;
    final jejak = _Jejak();
    var h = Float64List(hh);
    var c = Float64List(hh);

    for (var t = 0; t < panjangUrutan; t++) {
      final z = Float64List(nIn);
      for (var k = 0; k < _d; k++) {
        z[k] = xs[t * _d + k];
      }
      for (var k = 0; k < hh; k++) {
        z[_d + k] = h[k];
      }

      double pra(int gerbang, int u) {
        final r = gerbang * hh + u;
        var s = _p[_offB + r];
        final base = _offW + r * nIn;
        for (var k = 0; k < nIn; k++) {
          s += _p[base + k] * z[k];
        }
        return s;
      }

      final ig = Float64List(hh), fg = Float64List(hh);
      final gg = Float64List(hh), og = Float64List(hh);
      final cBaru = Float64List(hh), tc = Float64List(hh);
      final hBaru = Float64List(hh);
      for (var u = 0; u < hh; u++) {
        ig[u] = _sigmoid(pra(0, u));
        fg[u] = _sigmoid(pra(1, u));
        gg[u] = MathUtils.tanh(pra(2, u));
        og[u] = _sigmoid(pra(3, u));
        cBaru[u] = fg[u] * c[u] + ig[u] * gg[u];
        tc[u] = MathUtils.tanh(cBaru[u]);
        hBaru[u] = og[u] * tc[u];
      }

      jejak.z.add(z);
      jejak.i.add(ig);
      jejak.f.add(fg);
      jejak.g.add(gg);
      jejak.o.add(og);
      jejak.cPrev.add(c);
      jejak.tc.add(tc);
      jejak.h.add(hBaru);
      h = hBaru;
      c = cBaru;
    }

    var logit = _p[_offBy];
    for (var k = 0; k < hh; k++) {
      logit += _p[_offWy + k] * h[k];
    }
    jejak.y = _sigmoid(logit);
    return jejak;
  }

  /// Hitung gradien untuk satu sampel dan tambahkan ke [_g].
  void _mundur(_Jejak j, int target) {
    final hh = tersembunyi, nIn = _nIn;
    final dLogit = j.y - target;
    final hT = j.h.last;
    for (var k = 0; k < hh; k++) {
      _g[_offWy + k] += dLogit * hT[k];
    }
    _g[_offBy] += dLogit;

    final dh = Float64List(hh);
    for (var k = 0; k < hh; k++) {
      dh[k] = dLogit * _p[_offWy + k];
    }
    var dc = Float64List(hh);
    final da = Float64List(4 * hh);

    for (var t = panjangUrutan - 1; t >= 0; t--) {
      final z = j.z[t], i = j.i[t], f = j.f[t], g = j.g[t], o = j.o[t];
      final cp = j.cPrev[t], tc = j.tc[t];
      final dcPrev = Float64List(hh);

      for (var u = 0; u < hh; u++) {
        final dO = dh[u] * tc[u];
        dc[u] += dh[u] * o[u] * (1 - tc[u] * tc[u]);
        final dI = dc[u] * g[u];
        final dG = dc[u] * i[u];
        final dF = dc[u] * cp[u];
        dcPrev[u] = dc[u] * f[u];
        da[u] = dI * i[u] * (1 - i[u]);
        da[hh + u] = dF * f[u] * (1 - f[u]);
        da[2 * hh + u] = dG * (1 - g[u] * g[u]);
        da[3 * hh + u] = dO * o[u] * (1 - o[u]);
      }

      final dz = Float64List(nIn);
      for (var r = 0; r < 4 * hh; r++) {
        final dr = da[r];
        if (dr == 0) continue;
        _g[_offB + r] += dr;
        final base = _offW + r * nIn;
        for (var k = 0; k < nIn; k++) {
          _g[base + k] += dr * z[k];
          dz[k] += dr * _p[base + k];
        }
      }
      for (var u = 0; u < hh; u++) {
        dh[u] = dz[_d + u];
      }
      dc = dcPrev;
    }
  }

  void _langkahAdam(int ukuran, int langkah) {
    const b1 = 0.9, b2 = 0.999, eps = 1e-8;
    final koreksi1 = 1 - math.pow(b1, langkah).toDouble();
    final koreksi2 = 1 - math.pow(b2, langkah).toDouble();
    for (var k = 0; k < _p.length; k++) {
      final g = (_g[k] / ukuran).clamp(-5.0, 5.0).toDouble();
      _m[k] = b1 * _m[k] + (1 - b1) * g;
      _v[k] = b2 * _v[k] + (1 - b2) * g * g;
      final mh = _m[k] / koreksi1;
      final vh = _v[k] / koreksi2;
      _p[k] -= lajuBelajar * mh / (math.sqrt(vh) + eps);
      _g[k] = 0;
    }
  }

  @override
  void latih(List<List<double>> x, List<int> y) {
    if (x.isEmpty) throw ArgumentError('Data latih kosong');
    if (x.first.length % panjangUrutan != 0) {
      throw ArgumentError(
          'Panjang vektor (${x.first.length}) harus kelipatan panjangUrutan ($panjangUrutan)');
    }
    _d = x.first.length ~/ panjangUrutan;

    // Skala per fitur (di semua sampel dan semua langkah).
    _rata = List<double>.filled(_d, 0);
    _sd = List<double>.filled(_d, 1);
    final cacah = x.length * panjangUrutan;
    for (final baris in x) {
      for (var k = 0; k < baris.length; k++) {
        _rata[k % _d] += baris[k];
      }
    }
    for (var j = 0; j < _d; j++) {
      _rata[j] /= cacah;
    }
    final ragam = List<double>.filled(_d, 0);
    for (final baris in x) {
      for (var k = 0; k < baris.length; k++) {
        final s = baris[k] - _rata[k % _d];
        ragam[k % _d] += s * s;
      }
    }
    for (var j = 0; j < _d; j++) {
      final sd = math.sqrt(ragam[j] / cacah);
      _sd[j] = sd == 0 ? 1 : sd;
    }
    final xs = x.map(_skalakan).toList();

    // Inisialisasi parameter.
    final rnd = math.Random(benih);
    final hh = tersembunyi;
    _p = Float64List(_jumlahParam);
    _g = Float64List(_jumlahParam);
    _m = Float64List(_jumlahParam);
    _v = Float64List(_jumlahParam);
    final batas = 1 / math.sqrt(hh);
    for (var k = 0; k < _offB; k++) {
      _p[k] = (rnd.nextDouble() * 2 - 1) * batas;
    }
    for (var u = 0; u < hh; u++) {
      _p[_offB + hh + u] = 1.0; // bias forget gate = 1
    }
    for (var k = 0; k < hh; k++) {
      _p[_offWy + k] = (rnd.nextDouble() * 2 - 1) * batas;
    }

    // Latihan mini-batch.
    final urutan = List<int>.generate(xs.length, (i) => i);
    var langkah = 0;
    for (var e = 0; e < epoch; e++) {
      urutan.shuffle(rnd);
      for (var awal = 0; awal < urutan.length; awal += ukuranBatch) {
        final akhir = math.min(awal + ukuranBatch, urutan.length);
        for (var b = awal; b < akhir; b++) {
          final idx = urutan[b];
          _mundur(_maju(xs[idx]), y[idx]);
        }
        langkah++;
        _langkahAdam(akhir - awal, langkah);
      }
    }
  }

  @override
  double peluang(List<double> x) {
    if (_p.isEmpty || x.length != panjangUrutan * _d) return 0.5;
    return _maju(_skalakan(x)).y;
  }
}
