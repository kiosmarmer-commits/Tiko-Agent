/// Tool wrapper untuk paket `prediksi` agar bisa dipanggil dari Tiko-Agent.
///
/// Salin file ini ke:
///   packages/agent_tools/lib/src/prediksi_tool.dart
///
/// Lalu daftarkan lewat createPrediksiTools() di createBuiltinTools / registry.
library;

import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:prediksi/prediksi.dart';

/// Helper: parse list candle dari argumen tool (JSON-friendly).
List<Candle> _parseCandles(dynamic raw) {
  if (raw is! List) {
    throw ArgumentError('candles harus berupa List');
  }
  return [
    for (final item in raw)
      if (item is Map)
        Candle(
          waktu: DateTime.tryParse('${item['waktu'] ?? item['time'] ?? ''}') ??
              DateTime.fromMillisecondsSinceEpoch(
                (item['ts'] as num?)?.toInt() ?? 0,
                isUtc: true,
              ),
          open: (item['open'] as num).toDouble(),
          high: (item['high'] as num).toDouble(),
          low: (item['low'] as num).toDouble(),
          close: (item['close'] as num).toDouble(),
          volume: (item['volume'] as num?)?.toDouble() ?? 0,
        ),
  ];
}

Map<String, dynamic> _sinyalToMap(Sinyal s) => {
      'metode': s.metode,
      'arah': s.arah.name,
      'skor': s.skor,
      'catatan': s.catatan,
    };

ToolResult _ok(String callId, Object body) => ToolResult(
      callId: callId,
      content: body is String ? body : jsonEncode(body),
    );

ToolResult _err(String callId, Object e) => ToolResult(
      callId: callId,
      content: e.toString(),
      isError: true,
    );

/// Tool: analisis teknikal (RSI + MACD + Bollinger + SMA).
class PrediksiTeknikalTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'prediksi_teknikal',
        description:
            'Analisis teknikal harga (RSI, MACD, Bollinger, SMA cross). '
            'Input: daftar candle OHLCV. Output: sinyal beli/jual/tahan + skor. '
            'Alat edukasi, bukan saran keuangan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'candles': {
              'type': 'array',
              'description':
                  'Daftar candle. Setiap item: {waktu|time|ts, open, high, low, close, volume?}',
            },
            'rsi_periode': {'type': 'integer', 'description': 'Default 14'},
            'sma_cepat': {'type': 'integer', 'description': 'Default 20'},
            'sma_lambat': {'type': 'integer', 'description': 'Default 50'},
          },
          'required': ['candles'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = 'prediksi_teknikal';
    try {
      final data = _parseCandles(args['candles']);
      final metode = AnalisisTeknikal(
        rsiPeriode: (args['rsi_periode'] as num?)?.toInt() ?? 14,
        smaCepat: (args['sma_cepat'] as num?)?.toInt() ?? 20,
        smaLambat: (args['sma_lambat'] as num?)?.toInt() ?? 50,
      );
      final s = metode.analisis(data);
      return _ok(callId, _sinyalToMap(s));
    } catch (e) {
      return _err(callId, 'prediksi_teknikal gagal: $e');
    }
  }
}

/// Tool: ensemble multi-metode.
class PrediksiEnsembleTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'prediksi_ensemble',
        description:
            'Gabungkan beberapa metode prediksi (teknikal, regresi tren, random forest) '
            'plus sinyal siklus opsional. Mengembalikan sinyal akhir + tingkat kesepakatan. '
            'Alat edukasi, bukan saran keuangan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'candles': {
              'type': 'array',
              'description': 'Daftar candle OHLCV',
            },
            'pakai_siklus': {
              'type': 'boolean',
              'description': 'Sertakan Benner + Halving + Kondratiev (default true)',
            },
            'tanggal': {
              'type': 'string',
              'description': 'ISO date untuk siklus (default sekarang UTC)',
            },
          },
          'required': ['candles'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = 'prediksi_ensemble';
    try {
      final data = _parseCandles(args['candles']);
      final pakaiSiklus = args['pakai_siklus'] as bool? ?? true;
      final tanggal = DateTime.tryParse('${args['tanggal'] ?? ''}') ??
          DateTime.now().toUtc();

      final metode = <MetodePrediksi>[
        const AnalisisTeknikal(),
        const RegresiTren(),
        MetodeML.hutan(jumlahPohon: 30),
      ];

      final tambahan = <Sinyal>[];
      if (pakaiSiklus) {
        tambahan.addAll([
          SiklusBenner().pada(tanggal),
          HalvingBitcoin().pada(tanggal),
          const SiklusPeriodik.kondratiev().pada(tanggal),
        ]);
      }

      final ens = Ensemble(metode, nama: 'Ensemble Tiko');
      final hasil = ens.hitung(data, tambahan: tambahan);

      return _ok(callId, {
        'sinyal': _sinyalToMap(hasil.sinyal),
        'kesepakatan': hasil.kesepakatan,
        'rincian': [for (final s in hasil.rincian) _sinyalToMap(s)],
        'peringatan': 'Alat edukasi, bukan saran keuangan.',
      });
    } catch (e) {
      return _err(callId, 'prediksi_ensemble gagal: $e');
    }
  }
}

/// Tool: siklus waktu.
class PrediksiSiklusTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'prediksi_siklus',
        description:
            'Sinyal berbasis siklus waktu: Benner, Bitcoin Halving, Kondratiev, Juglar. '
            'Tidak membutuhkan data harga, cukup tanggal.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'tanggal': {
              'type': 'string',
              'description': 'ISO-8601 date (default sekarang UTC)',
            },
            'jenis': {
              'type': 'string',
              'description':
                  'benner | halving | kondratiev | juglar | semua (default semua)',
            },
          },
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = 'prediksi_siklus';
    try {
      final tanggal = DateTime.tryParse('${args['tanggal'] ?? ''}') ??
          DateTime.now().toUtc();
      final jenis = (args['jenis'] as String?)?.toLowerCase() ?? 'semua';

      final out = <Map<String, dynamic>>[];
      void add(MetodeSiklus m) => out.add(_sinyalToMap(m.pada(tanggal)));

      switch (jenis) {
        case 'benner':
          add(SiklusBenner());
        case 'halving':
          add(HalvingBitcoin());
        case 'kondratiev':
          add(const SiklusPeriodik.kondratiev());
        case 'juglar':
          add(const SiklusPeriodik.juglar());
        default:
          add(SiklusBenner());
          add(HalvingBitcoin());
          add(const SiklusPeriodik.kondratiev());
          add(const SiklusPeriodik.juglar());
      }

      return _ok(callId, {
        'tanggal': tanggal.toIso8601String(),
        'sinyal': out,
      });
    } catch (e) {
      return _err(callId, 'prediksi_siklus gagal: $e');
    }
  }
}

/// Tool: backtest walk-forward.
class PrediksiBacktestTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'prediksi_backtest',
        description:
            'Backtest walk-forward metode AnalisisTeknikal dengan biaya transaksi. '
            'Mengembalikan total return, max drawdown, jumlah trade. '
            'Hasil historis tidak menjamin hasil masa depan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'candles': {'type': 'array'},
            'mulai': {
              'type': 'integer',
              'description': 'Index candle mulai backtest (default 120)',
            },
            'interval': {
              'type': 'integer',
              'description': 'Jarak evaluasi sinyal (default 5)',
            },
            'biaya': {
              'type': 'number',
              'description': 'Biaya per transaksi proporsi (default 0.001 = 0.1%)',
            },
          },
          'required': ['candles'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = 'prediksi_backtest';
    try {
      final data = _parseCandles(args['candles']);
      final bt = Backtest(
        mulai: (args['mulai'] as num?)?.toInt() ?? 120,
        interval: (args['interval'] as num?)?.toInt() ?? 5,
        biayaPerTransaksi: (args['biaya'] as num?)?.toDouble() ?? 0.001,
      );
      final hasil = bt.jalankan(const AnalisisTeknikal(), data);

      return _ok(callId, {
        'total_return': hasil.totalReturn,
        'return_beli_tahan': hasil.returnBeliTahan,
        'jumlah_perubahan_posisi': hasil.jumlahPerubahanPosisi,
        'max_drawdown': ManajemenRisiko.maxDrawdown(hasil.ekuitas),
        'jumlah_transaksi': hasil.transaksi.length,
        'catatan':
            'Backtest edukasi. Eksekusi pada close sinyal, ada biaya tetap, tanpa slippage ekstra. Bukan jaminan hasil masa depan.',
      });
    } catch (e) {
      return _err(callId, 'prediksi_backtest gagal: $e');
    }
  }
}

/// Tool: manajemen risiko.
class PrediksiRisikoTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'prediksi_risiko',
        description:
            'Hitung stop-loss ATR, ukuran posisi berbasis risiko, Kelly criterion, '
            'dan rasio risiko:imbalan. Membutuhkan candle untuk ATR.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'candles': {'type': 'array'},
            'modal': {'type': 'number', 'description': 'Modal tersedia'},
            'risiko_persen': {
              'type': 'number',
              'description': 'Risiko per trade dalam persen modal (default 1)',
            },
            'kelipatan_atr': {
              'type': 'number',
              'description': 'Kelipatan ATR untuk stop (default 2)',
            },
            'posisi_long': {
              'type': 'boolean',
              'description': 'true = long (default), false = short',
            },
            'harga_target': {
              'type': 'number',
              'description': 'Opsional untuk hitung R:R',
            },
            'peluang_menang': {
              'type': 'number',
              'description': 'Opsional 0..1 untuk Kelly',
            },
            'rasio_menang_kalah': {
              'type': 'number',
              'description': 'Opsional avg win / avg loss untuk Kelly',
            },
          },
          'required': ['candles', 'modal'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = 'prediksi_risiko';
    try {
      final data = _parseCandles(args['candles']);
      if (data.isEmpty) {
        return _err(callId, 'candles kosong');
      }
      final atrList = Indikator.atr(data);
      final atr = atrList.last;
      final masuk = data.last.close;
      final long = args['posisi_long'] as bool? ?? true;
      final kelipatan = (args['kelipatan_atr'] as num?)?.toDouble() ?? 2.0;
      final modal = (args['modal'] as num).toDouble();
      final risikoPersen = (args['risiko_persen'] as num?)?.toDouble() ?? 1.0;

      final stop = ManajemenRisiko.stopLossAtr(
        hargaMasuk: masuk,
        atr: atr,
        kelipatan: kelipatan,
        posisiLong: long,
      );
      final unit = ManajemenRisiko.ukuranPosisi(
        modal: modal,
        risikoPersen: risikoPersen,
        hargaMasuk: masuk,
        hargaStop: stop,
      );

      final out = <String, dynamic>{
        'harga_masuk': masuk,
        'atr': atr,
        'stop_loss': stop,
        'ukuran_unit': unit,
        'risiko_nominal': modal * (risikoPersen / 100),
      };

      final target = (args['harga_target'] as num?)?.toDouble();
      if (target != null) {
        out['rasio_risiko_imbalan'] = ManajemenRisiko.rasioRisikoImbalan(
          hargaMasuk: masuk,
          hargaStop: stop,
          hargaTarget: target,
        );
      }

      final p = (args['peluang_menang'] as num?)?.toDouble();
      final b = (args['rasio_menang_kalah'] as num?)?.toDouble();
      if (p != null && b != null) {
        out['kelly_penuh'] = ManajemenRisiko.kelly(
          peluangMenang: p,
          rasioMenangKalah: b,
        );
        out['kelly_setengah'] = ManajemenRisiko.kellyFraksi(
          peluangMenang: p,
          rasioMenangKalah: b,
          fraksi: 0.5,
        );
      }

      return _ok(callId, out);
    } catch (e) {
      return _err(callId, 'prediksi_risiko gagal: $e');
    }
  }
}

/// Daftar tool prediksi siap didaftarkan ke ToolRegistry.
List<Tool> createPrediksiTools() => [
      PrediksiTeknikalTool(),
      PrediksiEnsembleTool(),
      PrediksiSiklusTool(),
      PrediksiBacktestTool(),
      PrediksiRisikoTool(),
    ];
