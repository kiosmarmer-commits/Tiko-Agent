import '../core/numeric.dart';

/// AST ekspresi (CALC-MAT-04). Setiap node menyimpan posisi untuk
/// galat evaluasi berposisi.
sealed class Node {
  const Node(this.position);

  /// Indeks karakter awal token pembentuk node.
  final int position;
}

final class NumNode extends Node {
  const NumNode(this.value, int position) : super(position);
  final Dec value;
}

final class UnaryNode extends Node {
  const UnaryNode(this.op, this.child, int position) : super(position);
  final String op; // '+' | '-'
  final Node child;
}

final class BinaryNode extends Node {
  const BinaryNode(
    this.op,
    this.left,
    this.right,
    int position,
  ) : super(position);
  final String op; // '+' | '-' | '*' | '/' | '^' | 'mod'
  final Node left;
  final Node right;
}

/// Postfix `%`: berdiri sendiri berarti nilai/100; sebagai operand kanan
/// `+`/`-` memakai basis operand kiri (CALC-MAT-04b).
final class PercentNode extends Node {
  const PercentNode(this.child, int position) : super(position);
  final Node child;
}

/// Postfix `!`: faktorial.
final class FactorialNode extends Node {
  const FactorialNode(this.child, int position) : super(position);
  final Node child;
}

final class CallNode extends Node {
  const CallNode(this.name, this.args, int position) : super(position);
  final String name;
  final List<Node> args;
}

final class IdentNode extends Node {
  const IdentNode(this.name, int position) : super(position);
  final String name;
}
