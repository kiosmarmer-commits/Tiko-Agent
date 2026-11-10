import '../core/errors.dart';
import '../core/limits.dart';
import '../core/numeric.dart';
import 'ast.dart';
import 'tokenizer.dart';

/// Parser recursive descent dengan galat berposisi (CALC-MAT-04/05).
/// Perkalian implisit (2pi, 3(4)) sengaja dimatikan karena ambigu.
final class Parser {
  Parser(this.tokens, {this.limits = CalcLimits.defaults});

  final List<Token> tokens;
  final CalcLimits limits;

  int _index = 0;
  int _depth = 0;

  Node parse() {
    final node = _expr();
    final t = _peek();
    if (t.kind != TokenKind.eof) {
      final adj = t.kind == TokenKind.number || t.kind == TokenKind.lparen;
      throw CalcException(
        CalcErrorCodes.syntax,
        "Token tak terduga '${t.text}'",
        position: t.position,
        hint: adj ? 'tulis 2*3 atau 2*(3), tanpa perkalian implisit' : null,
      );
    }
    return node;
  }

  Token _peek() => tokens[_index];

  Token _next() => tokens[_index++];

  void _enter() {
    _depth++;
    if (_depth > limits.maxAstDepth) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Ekspresi terlalu dalam (melebihi kedalaman maksimum)',
      );
    }
  }

  void _leave() => _depth--;

  Node _expr() {
    var left = _term();
    while (_peek().kind == TokenKind.plus ||
        _peek().kind == TokenKind.minus) {
      final t = _next();
      final right = _term();
      left = BinaryNode(
        t.kind == TokenKind.plus ? '+' : '-',
        left,
        right,
        t.position,
      );
    }
    return left;
  }

  Node _term() {
    var left = _unary();
    while (true) {
      final t = _peek();
      final String? op;
      if (t.kind == TokenKind.star) {
        op = '*';
      } else if (t.kind == TokenKind.slash) {
        op = '/';
      } else if (t.kind == TokenKind.ident && t.text == 'mod') {
        op = 'mod';
      } else {
        op = null;
      }
      if (op == null) return left;
      _next();
      left = BinaryNode(op, left, _unary(), t.position);
    }
  }

  Node _unary() {
    _enter();
    try {
      final t = _peek();
      if (t.kind == TokenKind.minus) {
        _next();
        return UnaryNode('-', _unary(), t.position);
      }
      if (t.kind == TokenKind.plus) {
        _next();
        return _unary();
      }
      return _power();
    } finally {
      _leave();
    }
  }

  Node _power() {
    final base = _postfix();
    final t = _peek();
    if (t.kind == TokenKind.caret) {
      _next();
      // Asosiatif kanan: 2^3^2 = 2^(3^2) = 512.
      return BinaryNode('^', base, _unary(), t.position);
    }
    return base;
  }

  Node _postfix() {
    var node = _primary();
    while (true) {
      final t = _peek();
      if (t.kind == TokenKind.percent) {
        _next();
        node = PercentNode(node, t.position);
      } else if (t.kind == TokenKind.bang) {
        _next();
        node = FactorialNode(node, t.position);
      } else {
        return node;
      }
    }
  }

  Node _primary() {
    final t = _peek();
    if (t.kind == TokenKind.number) {
      _next();
      return NumNode(_parseNumber(t.text), t.position);
    }
    if (t.kind == TokenKind.lparen) {
      _next();
      final node = _expr();
      final close = _peek();
      if (close.kind != TokenKind.rparen) {
        throw CalcException(
          CalcErrorCodes.syntax,
          'Kurung tidak seimbang',
          position: t.position,
          hint: "Tambahkan ')' sebelum akhir ekspresi",
        );
      }
      _next();
      return node;
    }
    if (t.kind == TokenKind.ident) {
      _next();
      if (_peek().kind == TokenKind.lparen) {
        _next();
        final args = <Node>[];
        if (_peek().kind != TokenKind.rparen) {
          args.add(_expr());
          while (_peek().kind == TokenKind.comma) {
            _next();
            args.add(_expr());
          }
        }
        final close = _peek();
        if (close.kind != TokenKind.rparen) {
          throw CalcException(
            CalcErrorCodes.syntax,
            "Kurung penutup tidak ditemukan untuk '${t.text}'",
            position: close.position,
          );
        }
        _next();
        return CallNode(t.text, args, t.position);
      }
      return IdentNode(t.text, t.position);
    }
    if (t.kind == TokenKind.rparen) {
      throw CalcException(
        CalcErrorCodes.syntax,
        'Kurung tutup tanpa kurung buka',
        position: t.position,
      );
    }
    throw CalcException(
      CalcErrorCodes.syntax,
      t.kind == TokenKind.eof
          ? 'Ekspresi tidak lengkap'
          : "Angka atau '(' diharapkan, ditemukan '${t.text}'",
      position: t.position,
    );
  }

  static Dec _parseNumber(String text) {
    final m = RegExp(r'^(\d+(?:\.\d+)?)(?:[eE]([+-]?\d+))?$')
        .firstMatch(text);
    if (m == null) {
      throw CalcException(CalcErrorCodes.syntax, "Angka tidak valid '$text'");
    }
    final base = Dec.parse(m.group(1)!);
    final exp = m.group(2);
    if (exp == null) return base;
    final n = int.parse(exp);
    if (n.abs() > 10000) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Eksponen terlalu besar',
      );
    }
    return base.shift10(n).normalized;
  }
}
