import 'models.dart';

/// Detects identical tool calls repeated ≥3 times in a row (ALG-11).
class LoopDetector {
  bool isLooping(List<ToolCall> recent) {
    if (recent.length < 3) return false;
    final last3 = recent.sublist(recent.length - 3);
    final keys = last3.map((c) => '${c.name}:${c.argsHash}').toSet();
    return keys.length == 1;
  }
}
