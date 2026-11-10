import '../core/errors.dart';

/// Jenis token (CALC-MAT-03).
enum TokenKind {
  number,
  ident,
  plus,
  minus,
  star,
  slash,
  caret,
  percent,
  bang,
  lparen,
  rparen,
  comma,
  eof,
}

/// Token dengan posisi karakter untuk pesan galat berposisi.
final class Token {
  const Token(this.kind, this.text, this.position);

  final TokenKind kind;

  /// Teks asli token, mis. `12.50`, `sqrt`, `mod`.
  final String text;

  /// Indeks karakter awal (0-based) di ekspresi ternormalisasi.
  final int position;

  bool get isIdent => kind == TokenKind.ident;
}

/// Tokenizer tanpa eval: daftar putih karakter, tolak sisanya dengan
/// galat berkode dan berposisi (CWE-95: anggap semua input berbahaya).
final class Tokenizer {
  const Tokenizer();

  List<Token> tokenize(String input) {
    final tokens = <Token>[];
    var i = 0;
    while (i < input.length) {
      final start = i;
      final c = input[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }
      final code = input.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        var j = i;
        while (j < input.length && _isDigit(input.codeUnitAt(j))) {
          j++;
        }
        if (j < input.length && input[j] == '.') {
          j++;
          if (j >= input.length || !_isDigit(input.codeUnitAt(j))) {
            throw CalcException(
              CalcErrorCodes.syntax,
              'Angka diharapkan setelah titik',
              position: j,
              hint: 'tulis desimal penuh, mis. 1.5',
            );
          }
          while (j < input.length && _isDigit(input.codeUnitAt(j))) {
            j++;
          }
        }
        if (j < input.length && (input[j] == 'e' || input[j] == 'E')) {
          var k = j + 1;
          if (k < input.length && (input[k] == '+' || input[k] == '-')) {
            k++;
          }
          if (k < input.length && _isDigit(input.codeUnitAt(k))) {
            while (k < input.length && _isDigit(input.codeUnitAt(k))) {
              k++;
            }
            j = k;
          }
        }
        tokens.add(Token(TokenKind.number, input.substring(i, j), i));
        i = j;
        continue;
      }
      if (_isIdentStart(code)) {
        var j = i;
        while (j < input.length && _isIdentPart(input.codeUnitAt(j))) {
          j++;
        }
        tokens.add(Token(TokenKind.ident, input.substring(i, j), i));
        i = j;
        continue;
      }
      final kind = switch (c) {
        '+' => TokenKind.plus,
        '-' => TokenKind.minus,
        '*' => TokenKind.star,
        '/' => TokenKind.slash,
        '^' => TokenKind.caret,
        '%' => TokenKind.percent,
        '!' => TokenKind.bang,
        '(' => TokenKind.lparen,
        ')' => TokenKind.rparen,
        ',' => TokenKind.comma,
        _ => throw CalcException(
            CalcErrorCodes.syntax,
            "Karakter tidak dikenal '$c'",
            position: start,
            hint: 'gunakan karakter ASCII (angka lebar penuh tidak didukung)',
          ),
      };
      tokens.add(Token(kind, c, start));
      i++;
    }
    tokens.add(Token(TokenKind.eof, '', input.length));
    return tokens;
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;

  static bool _isIdentStart(int c) =>
      (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95;

  static bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 48 && c <= 57);
}
