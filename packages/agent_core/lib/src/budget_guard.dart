import 'models.dart';

/// Tracks iteration / token / wall-clock / tool-call budgets (ALG-10).
class BudgetGuard {
  int _iterations = 0;
  int _toolCalls = 0;
  int _tokens = 0;
  late DateTime _start;
  late int _maxIterations;
  late int _maxTokens;
  late int _maxWallClockSec;
  late int _maxToolCalls;
  String? reason;

  void reset({
    required int maxIterations,
    required int maxTokens,
    required int maxWallClockSec,
    required int maxToolCalls,
  }) {
    _iterations = 0;
    _toolCalls = 0;
    _tokens = 0;
    _promptTokens = 0;
    _completionTokens = 0;
    _start = DateTime.now().toUtc();
    _maxIterations = maxIterations;
    _maxTokens = maxTokens;
    _maxWallClockSec = maxWallClockSec;
    _maxToolCalls = maxToolCalls;
    reason = null;
  }

  void tickIteration() => _iterations++;
  void tickToolCall() => _toolCalls++;
  int get tokensUsed => _tokens;

  /// Aksesori S20-C: rincian prompt/completion terakumulasi dari
  /// [TokenUsage] yang dilaporkan provider (0 bila tidak dilaporkan).
  int get promptTokens => _promptTokens;
  int get completionTokens => _completionTokens;
  int _promptTokens = 0;
  int _completionTokens = 0;

  void addTokens(TokenUsage u) {
    _promptTokens += u.prompt;
    _completionTokens += u.completion;
    _tokens += u.total > 0 ? u.total : (u.prompt + u.completion);
  }

  bool get exceeded {
    if (_iterations >= _maxIterations) {
      reason = 'maxIterations';
      return true;
    }
    if (_tokens >= _maxTokens) {
      reason = 'maxTokens';
      return true;
    }
    final elapsed = DateTime.now().toUtc().difference(_start).inSeconds;
    if (elapsed >= _maxWallClockSec) {
      reason = 'maxWallClock';
      return true;
    }
    return false;
  }

  bool get toolCallsExceeded {
    if (_toolCalls >= _maxToolCalls) {
      reason = 'maxToolCalls';
      return true;
    }
    return false;
  }
}
