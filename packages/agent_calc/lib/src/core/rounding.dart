/// Mode pembulatan eksplisit (CALC-MAT-02). Pembagian dan rescale
/// wajib menyebutkan mode; tidak ada default tersembunyi.
enum RoundingMode {
  /// Pembulatan bankir: .5 ke genap terdekat (default tool).
  halfEven,

  /// .5 menjauhi nol (kebiasaan sekolah).
  halfUp,

  /// Memotong menuju nol.
  down,

  /// Menjauhi nol bila ada sisa.
  up,

  /// Menuju negatif tak hingga.
  floor,

  /// Menuju positif tak hingga.
  ceiling;

  /// Nama kanonik untuk skema tool, mis. `half_even`.
  String get wireName => switch (this) {
        RoundingMode.halfEven => 'half_even',
        RoundingMode.halfUp => 'half_up',
        RoundingMode.down => 'down',
        RoundingMode.up => 'up',
        RoundingMode.floor => 'floor',
        RoundingMode.ceiling => 'ceiling',
      };

  /// Mengurai nama kanonik; galat bila tidak dikenal.
  static RoundingMode fromName(String name) => switch (name) {
        'half_even' => RoundingMode.halfEven,
        'half_up' => RoundingMode.halfUp,
        'down' => RoundingMode.down,
        'up' => RoundingMode.up,
        'floor' => RoundingMode.floor,
        'ceiling' => RoundingMode.ceiling,
        _ => throw FormatException("mode pembulatan tidak dikenal '$name'"),
      };
}
