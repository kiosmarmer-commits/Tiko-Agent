/// Penulisan ulang frasa matematika bahasa Indonesia menjadi ekspresi
/// (CALC-MAT-07). Tabel aturan berjangkar penuh - tidak pernah menebak;
/// bila tidak ada yang cocok, kembalikan null dan teruskan apa adanya.
final class RewriteId {
  RewriteId._();

  static final List<RegExp> _patterns = [
    RegExp(
      r'^\\s*diskon\\s+(.+?)\\s*%\\s+dari\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*(.+?)\\s+naik\\s+(.+?)\\s*%\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*naik\\s+(.+?)\\s*%\\s+dari\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*(.+?)\\s+turun\\s+(.+?)\\s*%\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*(.+?)\\s*%\\s+dari\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*(.+?)\\s+(?:adalah|itu)\\s+berapa\\s+persen\\s+dari\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*akar\\s+dari\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\\s*(.+?)\\s+(?:kali|dibagi|tambah|kurang|pangkat)\\s+(.+?)\\s*$',
      caseSensitive: false,
    ),
  ];

  /// Coba tulis ulang; ulangi hingga stabil (frasa berjangkar).
  /// Return null bila input bukan frasa yang dikenal.
  static String? rewrite(String input) {
    var current = input.trim();
    for (var i = 0; i < 8; i++) {
      final next = _applyOnce(current);
      if (next == null || next == current) {
        return i == 0 && next == null ? null : current;
      }
      current = next;
    }
    return current;
  }

  static String? _applyOnce(String input) {
    for (final p in _patterns) {
      final m = p.firstMatch(input);
      if (m == null) continue;
      final g1 = m.group(1)!.trim();
      final g2 = m.group(2)!.trim();
      if (p.pattern.contains('diskon')) {
        return '($g2)*(1-($g1)/100)';
      }
      if (p.pattern.contains('naik') && p.pattern.contains('dari')) {
        return '($g2)*(1+($g1)/100)';
      }
      if (p.pattern.contains('naik')) {
        return '($g1)*(1+($g2)/100)';
      }
      if (p.pattern.contains('turun')) {
        return '($g1)*(1-($g2)/100)';
      }
      if (p.pattern.contains('%')) {
        return '(($g1)/100)*($g2)';
      }
      if (p.pattern.contains('persen')) {
        return '(($g1)/($g2))*100';
      }
      if (p.pattern.contains('akar')) {
        return 'sqrt($g1)';
      }
      // kata operator: kali/dibagi/tambah/kurang/pangkat
      final opWord = RegExp(
        r'(kali|dibagi|tambah|kurang|pangkat)',
        caseSensitive: false,
      ).firstMatch(input)!.group(1)!.toLowerCase();
      final op = switch (opWord) {
        'kali' => '*',
        'dibagi' => '/',
        'tambah' => '+',
        'kurang' => '-',
        _ => '^',
      };
      return '($g1)$op($g2)';
    }
    return null;
  }
}
